import Cocoa

extension AppDelegate {
    func addTicketSection(to menu: NSMenu) {
        let summary = snapshot?.resetTickets ?? .unavailable
        menu.addItem(.separator())
        func row(_ title: String, _ action: Selector? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; item.isEnabled = action != nil; menu.addItem(item); return item
        }
        _ = row(summary.availableCount.map { "Manual resets · \($0) available" } ?? "Manual resets · unavailable")
        for ticket in summary.tickets {
            let item = row(ticket.menuText)
            item.toolTip = "\(ticket.title) · \(ticket.statusText(now: Date()))\n\(ticket.expiryText(now: Date()))"
        }
        if summary.availableCount != nil && (!summary.detailsProvided || summary.tickets.filter({ $0.status == "available" }).count < summary.availableCount!) {
            _ = row(summary.coverageText)
        }
    }
    func addTicketReminderMenu(to menu: NSMenu) {
        let parent = NSMenuItem(title: "Manual Reset Expiry Reminder", action: nil, keyEquivalent: "")
        let options = NSMenu(); options.autoenablesItems = false
        for days in [7, 3, 1] {
            let option = NSMenuItem(title: "\(days) \(days == 1 ? "day" : "days") before expiry", action: #selector(toggleTicketReminder(_:)), keyEquivalent: "")
            option.target = self; option.tag = days
            option.state = ticketReminderDays.contains(days) ? .on : .off
            option.toolTip = ticketReminders.status
            options.addItem(option)
        }
        if ticketReminders.status.contains("blocked") {
            let status = NSMenuItem(title: "Notifications are off in macOS Settings", action: nil, keyEquivalent: "")
            status.isEnabled = false; options.addItem(status)
        }
        parent.submenu = options; menu.addItem(parent)
    }
    @objc func toggleTicketReminder(_ sender: NSMenuItem) {
        guard TicketReminderPreferences.allDays.contains(sender.tag) else { return }
        var selected = ticketReminderDays
        if selected.contains(sender.tag) { selected.remove(sender.tag) } else { selected.insert(sender.tag) }
        TicketReminderPreferences.set(selected)
        ticketReminders.submit(summary: failure == nil ? snapshot?.resetTickets ?? .unavailable : .unavailable,
                               account: failure == nil ? snapshot?.accountID : nil, days: ticketReminderDays)
        rebuildMenu()
    }
    @objc func showGaugeMenu() {
        item.button?.performClick(nil)
    }
}
