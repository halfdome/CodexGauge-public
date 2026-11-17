import Foundation

// Explicit developer check: uses the real menu/controller and native notification store,
// restoring every reminder preference before returning. Never runs on normal launch.
@MainActor func verifyLiveMenu(_ delegate: AppDelegate) async throws {
    func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "CodexGaugeMenuCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    func settled() async throws {
        let deadline = Date().addingTimeInterval(90)
        while delegate.fetching || delegate.checkingAnnouncements || delegate.snapshot == nil {
            try require(Date() < deadline, "Refresh did not settle")
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
    try await settled()
    guard let snapshot = delegate.snapshot, delegate.failure == nil else {
        throw NSError(domain: "CodexGaugeMenuCheck", code: 2)
    }
    delegate.rebuildMenu()
    let menu = delegate.item.menu!
    func titles(_ menu: NSMenu) -> [String] { menu.items.flatMap { [$0.title] + ($0.submenu.map(titles) ?? []) } }
    let primary = menu.items.map { $0.title }
    let all = titles(menu)
    try require(primary.filter { $0.hasPrefix("Granted:") }.count == snapshot.resetTickets.tickets.count, "Tickets must be in the primary menu")
    try require(primary.filter { $0 == "Open Usage Dashboard" }.count == 1 && all.filter { $0.contains("Usage Dashboard") }.count == 1, "Exactly one dashboard action")
    try require(!all.contains(where: { $0.contains("Show Ticket") || $0 == "Check Now" || $0 == "Send Test Notification" || $0 == "Notification Settings…" }), "Removed actions returned")
    try require(!primary.contains(where: { $0.hasPrefix("Updated ") || $0.hasPrefix("Last reset detected:") || $0.hasPrefix("Credits:") || $0.contains("% used") }), "Primary information must stay compact")
    let settings = menu.items.first { $0.title == "Settings" }?.submenu
    try require(settings != nil && settings!.items.contains { $0.title == "Reset Announcements" }, "Existing preferences remain available")
    try require(!primary.contains("Expiry Reminders") && !primary.contains("Manual Reset Expiry Reminder"), "Reminder settings must stay under Settings")
    let reminderMenu = settings?.items.first { $0.title == "Manual Reset Expiry Reminder" }?.submenu
    try require(reminderMenu?.items.filter { TicketReminderPreferences.allDays.contains($0.tag) }.count == 3, "Three independent reminder choices")
    print("Primary menu:\n" + primary.filter { !$0.isEmpty }.joined(separator: "\n"))
    try require(!primary[0].contains("credits") && primary.filter { $0.hasPrefix("Credits · ") }.count == 1, "Credits must appear on a separate information line")
    let original = delegate.ticketReminderDays
    let originalCallback = delegate.ticketReminders.didChange
    func toggle(_ day: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            delegate.ticketReminders.didChange = {
                delegate.ticketReminders.didChange = originalCallback
                originalCallback?(); continuation.resume()
            }
            let row = delegate.item.menu!.items.first { $0.title == "Settings" }!.submenu!.items.first { $0.title == "Manual Reset Expiry Reminder" }!.submenu!.items.first { $0.tag == day }!
            delegate.toggleTicketReminder(row)
        }
    }
    do {
        for day in [7,3,1] {
            await toggle(day)
            try require(delegate.ticketReminderDays == original.symmetricDifference([day]), "Toggle affected another timing")
            let expected = TicketReminderPlan.make(summary: snapshot.resetTickets, account: snapshot.accountID,
                now: Date(), receipts: delegate.ticketReminders.receipts, days: delegate.ticketReminderDays)
            let pending = await delegate.ticketReminders.delivery.pending().keys.filter { $0.hasPrefix(TicketReminderPlan.prefix) }
            try require(Set(pending) == Set(expected.map { $0.id }), "Native notification schedule does not match selected timings")
            print("\(day)-day toggle: \(pending.count) pending requests; other choices preserved")
            await toggle(day)
        }
        let previousUsage = delegate.snapshot!.fetched
        let previousAnnouncement = delegate.lastAnnouncementAttempt ?? .distantPast
        delegate.refreshAll()
        try await settled()
        try require(delegate.failure == nil && delegate.snapshot!.fetched > previousUsage, "Refresh Now did not update usage and tickets")
        try require((delegate.lastAnnouncementAttempt ?? .distantPast) > previousAnnouncement, "Refresh Now did not check announcements")
        print("Refresh Now updated usage/tickets and checked reset announcements")
    } catch {
        TicketReminderPreferences.set(original)
        delegate.ticketReminders.didChange = originalCallback
        await delegate.ticketReminders.reconcile(summary: snapshot.resetTickets, account: snapshot.accountID, days: original)
        throw error
    }
    try require(delegate.ticketReminderDays == original, "Reminder preferences were not restored")
    print("Live menu/controller checks passed; original preferences restored")
}

final class FakeTicketDelivery: TicketNotificationDelivery {
    var allowed = true
    var failAdds = false
    var requests: [String: TicketReminder] = [:]
    var additions = 0
    func authorized(request: Bool) async -> Bool { allowed }
    func pending() async -> [String: Date] { requests.mapValues { $0.fireAt } }
    func remove(_ ids: [String]) async { ids.forEach { requests.removeValue(forKey: $0) } }
    func add(_ reminder: TicketReminder, now: Date) async throws {
        if failAdds { throw NSError(domain: "test", code: 1) }
        requests[reminder.id] = reminder; additions += 1
    }
}
@MainActor func testResetTickets() async {
    var checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { print("FAIL: \(message)"); exit(1) }
    }
    let now = Date(timeIntervalSince1970: 1800000000)
    func raw(_ id: String = "synthetic-ticket", days: Double = 10, status: String = "available") -> [String: Any] {
        ["id": id, "resetType": "codexRateLimits", "status": status, "grantedAt": now.addingTimeInterval(-86400).timeIntervalSince1970,
         "expiresAt": now.addingTimeInterval(days * 86400).timeIntervalSince1970, "title": "Test reset"]
    }
    func summary(_ rows: [[String: Any]], count: Int? = nil) -> ResetTicketSummary {
        .parse(["availableCount": count ?? rows.count, "credits": rows])
    }
    let full = summary([raw()])
    let parsed = UsageSnapshot.parse(["rateLimitResetCredits": ["availableCount": 1, "credits": [raw()]]])
    check(parsed.resetTickets.tickets.count == 1, "usage response integrates ticket metadata")
    check(ResetTicketSummary.parse(nil).availableCount == nil, "absent is unknown, not zero")
    check(ResetTicketSummary.parse(NSNull()).availableCount == nil, "null is unknown")
    check(ResetTicketSummary.parse(["availableCount": -1]).availableCount == nil, "negative counts rejected")
    check(ResetTicketSummary.parse(["availableCount": true]).availableCount == nil, "boolean counts rejected")
    let countOnly = ResetTicketSummary.parse(["availableCount": 4, "credits": NSNull()])
    check(countOnly.tickets.isEmpty && !countOnly.detailsProvided && countOnly.availableCount == 4, "count-only creates no fictional tickets")
    check(summary([], count: 4).coverageText.contains("0 of 4"), "empty detail list does not erase count")
    check(summary([raw()], count: 4).coverageText.contains("1 of 4"), "capped rows disclosed")
    check(summary([raw(), raw()]).tickets.count == 1, "duplicate IDs removed")
    var invalid = raw(); invalid["expiresAt"] = "tomorrow"
    check(summary([invalid]).tickets[0].expiresAt == nil, "invalid expiry not invented")
    invalid["expiresAt"] = true
    check(summary([invalid]).tickets[0].expiresAt == nil, "boolean expiry rejected")
    invalid["expiresAt"] = NSNull()
    check(summary([invalid]).tickets[0].expiryText(now: now) == "No expiration", "explicit null matches installed helper schema")
    invalid.removeValue(forKey: "expiresAt")
    check(summary([invalid]).tickets[0].expiryText(now: now) == "Expiration not provided", "missing expiration distinct from nonexpiring")
    check(TicketReminderPlan.make(summary: summary([invalid]), account: "A", now: now, receipts: [:]).isEmpty, "unknown expiry never scheduled")
    let plan = TicketReminderPlan.make(summary: full, account: "A", now: now, receipts: [:])
    check(plan.map { $0.days } == [7,3,1], "three thresholds")
    check(plan.map { $0.fireAt.timeIntervalSince(now) } == [3,7,9].map { Double($0) * 86400 }, "exact expiry-relative delivery dates")
    let trigger = MacTicketNotificationDelivery.trigger(at: plan[0].fireAt)
    check(trigger.nextTriggerDate() == plan[0].fireAt && !trigger.repeats, "native calendar request preserves exact deadline without polling latency")
    check(TicketReminderPlan.make(summary: full, account: nil, now: now, receipts: [:]).isEmpty, "identity required for safe deduplication")
    for status in ["redeeming", "redeemed", "unknown", "unexpected"] {
        check(TicketReminderPlan.make(summary: summary([raw(status: status)]), account: "A", now: now, receipts: [:]).isEmpty, "no reminders for \(status)")
    }
    check(TicketReminderPlan.make(summary: summary([raw(days: 0)]), account: "A", now: now, receipts: [:]).isEmpty, "expired tickets not scheduled")
    for (days, expected) in [(7.0, [7,3,1]), (3.0, [3,1]), (1.0, [1]), (0.5, [1]), (5.0, [7,3,1])] {
        let actual = TicketReminderPlan.make(summary: summary([raw(days: days)]), account: "A", now: now, receipts: [:])
        check(actual.map { $0.days } == expected, "catch-up at \(days) days sends only current threshold plus future ones")
    }
    let suite = "CodexGauge.ResetTicketTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let fake = FakeTicketDelivery()
    var service = TicketReminderService(delivery: fake, defaults: defaults)
    await service.reconcile(summary: full, account: "A", days: [7,3,1], now: now)
    check(fake.requests.count == 3 && fake.additions == 3, "initial scheduling")
    await service.reconcile(summary: full, account: "A", days: [7,3,1], now: now.addingTimeInterval(300))
    check(fake.additions == 3, "polling does not duplicate or replace pending reminders")
    service = TicketReminderService(delivery: fake, defaults: defaults)
    await service.reconcile(summary: full, account: "A", days: [7,3,1], now: now.addingTimeInterval(300))
    check(fake.additions == 3, "restart retains deduplication")
    fake.requests.removeValue(forKey: plan[0].id) // Simulate macOS delivery.
    await service.reconcile(summary: full, account: "A", days: [7,3,1], now: now.addingTimeInterval(3 * 86400 + 10))
    check(fake.requests.count == 2 && fake.additions == 3, "delivered threshold is not reissued")
    await service.reconcile(summary: full, account: "B", days: [7,3,1], now: now)
    check(fake.requests.count == 3 && Set(fake.requests.keys).isDisjoint(with: Set(plan.map { $0.id })), "switching accounts cancels old requests")
    await service.reconcile(summary: summary([raw(status: "redeemed")]), account: "B", days: [7,3,1], now: now)
    check(fake.requests.isEmpty, "redemption cancels all pending reminders")
    await service.reconcile(summary: full, account: "A", days: [7,3,1], now: now)
    let beforeChange = Set(fake.requests.keys)
    await service.reconcile(summary: summary([raw(days: 12)]), account: "A", days: [7,3,1], now: now)
    check(Set(fake.requests.keys).isDisjoint(with: beforeChange), "changed expiry cancels old schedule")
    await service.reconcile(summary: .unavailable, account: nil, days: [7,3,1], now: now)
    check(fake.requests.isEmpty, "unavailable metadata cancels stale reminders")
    await service.reconcile(summary: full, account: "A", days: [7,3,1], now: now)
    await service.reconcile(summary: full, account: "A", days: [], now: now)
    check(fake.requests.isEmpty, "turning off reminders cancels pending requests")
    fake.allowed = false
    await service.reconcile(summary: full, account: "A", days: [7,3,1], now: now)
    check(fake.requests.isEmpty && service.status.contains("blocked"), "denied permission reported")
    fake.allowed = true; fake.failAdds = true
    await service.reconcile(summary: full, account: "A", days: [7,3,1], now: now)
    check(fake.requests.isEmpty && service.status.contains("could not"), "delivery failure reported")
    fake.failAdds = false
    await service.reconcile(summary: full, account: "A", days: [7,3,1], now: now)
    check(fake.requests.count == 3, "delivery failure retried without false receipts")
    await service.reconcile(summary: countOnly, account: "A", days: [7,3,1], now: now)
    check(fake.requests.isEmpty, "count-only cancels unverified ticket reminders")
    check(TicketReminderPreferences.days(in: defaults) == [7,3,1], "all three options enabled by default")
    defaults.set(false, forKey: "ticketRemindersEnabled")
    check(TicketReminderPreferences.days(in: defaults).isEmpty, "legacy off stays off")
    defaults.set(true, forKey: "ticketRemindersEnabled")
    check(TicketReminderPreferences.days(in: defaults) == [7,3,1], "legacy on enables all three options")
    for selection: Set<Int> in [[], [7], [3], [1], [7,3], [7,1], [3,1], [7,3,1]] {
        TicketReminderPreferences.set(selection, in: defaults)
        check(TicketReminderPreferences.days(in: UserDefaults(suiteName: suite)!) == selection, "selection persists: \(selection)")
        await service.reconcile(summary: full, account: "A", days: selection, now: now)
        check(Set(fake.requests.values.map { $0.days }) == selection, "only selected thresholds scheduled: \(selection)")
    }
    let beforeToggle = fake.requests
    let additionsBeforeToggle = fake.additions
    await service.reconcile(summary: full, account: "A", days: [3,1], now: now)
    check(fake.additions == additionsBeforeToggle && fake.requests.values.allSatisfy { beforeToggle[$0.id] == $0 }, "disabling seven days preserves other requests unchanged")
    await service.reconcile(summary: full, account: "A", days: [7,3,1], now: now)
    check(fake.requests.count == 3 && fake.additions == additionsBeforeToggle + 1, "reenabling schedules only the missing threshold")
    let late = summary([raw(days: 0.5)])
    check(TicketReminderPlan.make(summary: late, account: "A", now: now, receipts: [:], days: [7]).map { $0.days } == [7], "catch-up uses enabled timing")
    check(TicketReminderPlan.make(summary: late, account: "A", now: now, receipts: [:], days: [7,3]).map { $0.days } == [3], "catch-up chooses most urgent enabled timing")
    check(full.tickets[0].menuText.hasPrefix("Granted: ") && full.tickets[0].menuText.contains(", Expire: ") && !full.tickets[0].menuText.contains("left"), "compact ticket row contains only grant and expiry dates")
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        service.didChange = { continuation.resume() }
        service.submit(summary: full, account: "A", days: [7,3,1])
    }
    check(fake.requests.count == 3, "app submit path reconciles and notifies the UI")
    print("Reset ticket tests passed (\(checks) checks)")
}
