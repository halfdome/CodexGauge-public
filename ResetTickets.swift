import Foundation
import CryptoKit
import CoreFoundation

struct ResetTicket {
    let id: String
    let resetType: String
    let status: String
    let grantedAt: Date?
    let expiresAt: Date?
    let explicitlyNonExpiring: Bool
    let title: String
    let detail: String?

    init?(_ raw: [String: Any]) {
        guard let id = raw["id"] as? String, !id.isEmpty,
              let status = raw["status"] as? String, !status.isEmpty else { return nil }
        self.id = id; self.status = status
        resetType = raw["resetType"] as? String ?? "unknown"
        func date(_ key: String) -> Date? {
            guard let value = raw[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, value.doubleValue > 0,
                  value.doubleValue < 253402300800 else { return nil }
            return Date(timeIntervalSince1970: value.doubleValue)
        }
        grantedAt = date("grantedAt"); expiresAt = date("expiresAt")
        explicitlyNonExpiring = raw["expiresAt"] is NSNull
        title = (raw["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Reset ticket"
        detail = raw["description"] as? String
    }
    func statusText(now: Date) -> String {
        if status == "available", let expiresAt, expiresAt <= now { return "Expired" }
        return status.capitalized
    }
    func expiryText(now: Date) -> String {
        guard let expiresAt else { return explicitlyNonExpiring ? "No expiration" : "Expiration not provided" }
        let f = DateFormatter(); f.dateFormat = "MMM d, yyyy 'at' h:mm a z"
        let remaining = expiresAt.timeIntervalSince(now)
        let suffix = remaining <= 0 ? "expired" : remaining < 86400 ? "less than 1 day left" : "\(Int(ceil(remaining / 86400))) days left"
        return "\(f.string(from: expiresAt)) · \(suffix)"
    }
    var menuText: String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: Date())
        func shortDate(_ date: Date) -> String {
            formatter.dateFormat = calendar.component(.year, from: date) == currentYear ? "MMM d" : "MMM d, yyyy"
            return formatter.string(from: date)
        }
        let granted = grantedAt.map(shortDate) ?? "Not provided"
        let expiry = expiresAt.map(shortDate) ?? (explicitlyNonExpiring ? "None" : "Not provided")
        return "Granted: \(granted), Expire: \(expiry)"
    }
}

struct ResetTicketSummary {
    let availableCount: Int?
    let tickets: [ResetTicket]
    let detailsProvided: Bool
    static let unavailable = ResetTicketSummary(availableCount: nil, tickets: [], detailsProvided: false)
    static func parse(_ value: Any?) -> ResetTicketSummary {
        guard let raw = value as? [String: Any], let count = raw["availableCount"] as? NSNumber,
              CFGetTypeID(count) != CFBooleanGetTypeID(), count.doubleValue >= 0,
              count.doubleValue < Double(Int.max), count.doubleValue.rounded() == count.doubleValue else { return .unavailable }
        let rows = raw["credits"] as? [Any]
        var seen = Set<String>()
        let tickets = (rows ?? []).compactMap { ($0 as? [String: Any]).flatMap(ResetTicket.init) }
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.expiresAt ?? .distantFuture, $0.id) < ($1.expiresAt ?? .distantFuture, $1.id) }
        return ResetTicketSummary(availableCount: count.intValue, tickets: tickets, detailsProvided: rows != nil)
    }
    var summaryText: String {
        guard let availableCount else { return "Ticket details unavailable" }
        return "\(availableCount) available manual reset \(availableCount == 1 ? "ticket" : "tickets")"
    }
    var coverageText: String {
        guard let availableCount else { return "Refresh to check for manual reset tickets." }
        if !detailsProvided { return "Only the count is available; ticket details and expirations were not provided." }
        let availableRows = tickets.filter { $0.status == "available" }.count
        if availableRows < availableCount { return "Details reported for \(availableRows) of \(availableCount) available tickets. Reminders cover reported expirations only." }
        return availableCount == 0 && tickets.isEmpty ? "No available tickets reported." : "Checked every 5 minutes"
    }
}

struct TicketReminder: Equatable {
    let id: String
    let title: String
    let body: String
    let fireAt: Date
    let expiresAt: Date
    let days: Int
}
struct TicketReminderReceipt: Codable {
    let fireAt: Date
    let expiresAt: Date
}
enum TicketReminderPreferences {
    static let allDays: Set<Int> = [7, 3, 1]
    static func days(in defaults: UserDefaults = .standard) -> Set<Int> {
        if let saved = defaults.array(forKey: "ticketReminderDays") as? [Int] {
            return Set(saved).intersection(allDays)
        }
        // Preserve the previous all-on/all-off choice on upgrade.
        return defaults.object(forKey: "ticketRemindersEnabled") as? Bool == false ? [] : allDays
    }
    static func set(_ days: Set<Int>, in defaults: UserDefaults = .standard) {
        defaults.set(days.intersection(allDays).sorted(by: >), forKey: "ticketReminderDays")
    }
}
enum TicketReminderPlan {
    static let prefix = "codexgauge.ticket."
    static func id(account: String, ticket: ResetTicket, days: Int) -> String {
        let bytes = try! JSONEncoder().encode([account, ticket.id, String(ticket.expiresAt!.timeIntervalSince1970), String(days)])
        return prefix + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    static func make(summary: ResetTicketSummary, account: String?, now: Date,
                     receipts: [String: TicketReminderReceipt], days: Set<Int> = TicketReminderPreferences.allDays) -> [TicketReminder] {
        guard let account, !account.isEmpty else { return [] }
        var result: [TicketReminder] = []
        for ticket in summary.tickets {
            guard ticket.status == "available", ticket.resetType == "codexRateLimits",
                  let expiry = ticket.expiresAt, expiry > now else { continue }
            let remaining = expiry.timeIntervalSince(now)
            // After downtime, send only the most urgent missed threshold, not a burst of three.
            let selectedDays = days.intersection(TicketReminderPreferences.allDays)
            let catchUp = selectedDays.sorted().first { remaining <= Double($0) * 86400 }
            for days in selectedDays.sorted(by: >) {
                let due = expiry.addingTimeInterval(-Double(days) * 86400)
                let key = id(account: account, ticket: ticket, days: days)
                if let receipt = receipts[key], receipt.fireAt <= now { continue }
                guard due > now || catchUp == days else { continue }
                let f = DateFormatter(); f.dateFormat = "MMM d, yyyy 'at' h:mm a z"
                result.append(TicketReminder(id: key, title: "Manual reset ticket expires within \(days) \(days == 1 ? "day" : "days")",
                    body: "\(ticket.title) expires \(f.string(from: expiry)). Open CodexGauge to review it.",
                    fireAt: due > now ? due : now.addingTimeInterval(2), expiresAt: expiry, days: days))
            }
        }
        return result.sorted { $0.fireAt < $1.fireAt }
    }
}
