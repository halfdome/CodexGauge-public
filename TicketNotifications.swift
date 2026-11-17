import UserNotifications

protocol TicketNotificationDelivery {
    func authorized(request: Bool) async -> Bool
    func pending() async -> [String: Date]
    func remove(_ ids: [String]) async
    func add(_ reminder: TicketReminder, now: Date) async throws
}
final class MacTicketNotificationDelivery: NSObject, TicketNotificationDelivery, UNUserNotificationCenterDelegate {
    let center = UNUserNotificationCenter.current()
    var onOpen: (() -> Void)?
    override init() { super.init(); center.delegate = self }
    func authorized(request: Bool) async -> Bool {
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined && request {
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
        return [.authorized, .provisional].contains(settings.authorizationStatus)
    }
    func pending() async -> [String: Date] {
        var result: [String: Date] = [:]
        for request in await center.pendingNotificationRequests() {
            // Older interval-based requests are replaced with exact calendar dates.
            result[request.identifier] = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() ?? .distantPast
        }
        return result
    }
    func remove(_ ids: [String]) async { center.removePendingNotificationRequests(withIdentifiers: ids) }
    func add(_ reminder: TicketReminder, now: Date) async throws {
        let content = UNMutableNotificationContent()
        content.title = reminder.title; content.body = reminder.body; content.sound = .default
        let trigger = Self.trigger(at: max(reminder.fireAt, Date().addingTimeInterval(1)))
        try await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
    }
    static func trigger(at date: Date) -> UNCalendarNotificationTrigger {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        components.timeZone = calendar.timeZone
        return UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { self.onOpen?(); completionHandler() }
    }
}

// One serialized reconciler handles refreshes, permission changes and account switches.
// Receipts record accepted requests, not a claim that macOS displayed a banner.
final class TicketReminderService {
    let delivery: TicketNotificationDelivery
    let defaults: UserDefaults
    private(set) var receipts: [String: TicketReminderReceipt]
    private(set) var status = "Checking notification permission…"
    private(set) var scheduledCount = 0
    var didChange: (() -> Void)?
    private var processing = false
    private var queued: (ResetTicketSummary, String?, Set<Int>)?
    init(delivery: TicketNotificationDelivery, defaults: UserDefaults = .standard) {
        self.delivery = delivery; self.defaults = defaults
        receipts = defaults.data(forKey: "ticketReminderReceipts").flatMap {
            try? JSONDecoder().decode([String: TicketReminderReceipt].self, from: $0)
        } ?? [:]
    }
    func submit(summary: ResetTicketSummary, account: String?, days: Set<Int>) {
        dispatchPrecondition(condition: .onQueue(.main))
        queued = (summary, account, days)
        guard !processing else { return }
        processing = true
        Task { @MainActor in
            while let request = self.queued {
                self.queued = nil
                await self.reconcile(summary: request.0, account: request.1, days: request.2)
            }
            self.processing = false; self.didChange?()
        }
    }
    @MainActor func reconcile(summary: ResetTicketSummary, account: String?, days: Set<Int>, now: Date = Date()) async {
        let allowed = !days.isEmpty ? await delivery.authorized(request: true) : false
        let pending = await delivery.pending().filter { $0.key.hasPrefix(TicketReminderPlan.prefix) }
        let planned = allowed ? TicketReminderPlan.make(summary: summary, account: account, now: now, receipts: receipts, days: days) : []
        // Leave room for other notifications under the macOS pending-request limit.
        let desired = Array(planned.prefix(60))
        let wanted = Set(desired.map { $0.id })
        await delivery.remove(Array(Set(pending.keys).subtracting(wanted)))
        // A cancelled future request can be rescheduled if the ticket reappears.
        receipts = receipts.filter { key, value in
            value.expiresAt > now.addingTimeInterval(-30 * 86400) && (value.fireAt <= now || wanted.contains(key))
        }
        var failed = false
        scheduledCount = 0
        for reminder in desired {
            if let date = pending[reminder.id], abs(date.timeIntervalSince(reminder.fireAt)) < 1 {
                scheduledCount += 1; continue
            }
            do {
                try await delivery.add(reminder, now: now)
                receipts[reminder.id] = TicketReminderReceipt(fireAt: reminder.fireAt, expiresAt: reminder.expiresAt)
                scheduledCount += 1
                save()
            } catch { failed = true }
        }
        save()
        if days.isEmpty { status = "Expiry reminders off" }
        else if !allowed { status = "Notifications blocked — enable CodexGauge in System Settings" }
        else if failed { status = "Some reminders could not be scheduled; retrying on refresh" }
        else if account == nil { status = "Reminders paused: account identity unavailable" }
        else if summary.availableCount == nil { status = "Reminders paused: ticket metadata unavailable" }
        else if planned.count > 60 { status = "60 nearest reminders scheduled; more added as they fire" }
        else {
            let timing = days.sorted(by: >).map(String.init).joined(separator: ", ")
            status = "\(timing) \(days == [1] ? "day" : "days") before expiry · \(scheduledCount) scheduled"
        }
    }
    private func save() {
        if let data = try? JSONEncoder().encode(receipts) { defaults.set(data, forKey: "ticketReminderReceipts") }
    }
}
