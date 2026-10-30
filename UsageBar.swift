import Cocoa

struct UsageWindow {
    let used: Double
    let minutes: Int?
    let reset: Date?
    var remaining: Int { max(0, min(100, Int((100 - used).rounded()))) }
    var label: String {
        guard let minutes else { return "Usage window" }
        if minutes == 10080 { return "Weekly" }
        if minutes % 1440 == 0 { return "\(minutes / 1440)-day" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour" }
        return "\(minutes)-minute"
    }
}
struct UsageSnapshot {
    let windows: [(String, UsageWindow)]
    let plan: String?
    var credits: CreditsBalance? = nil
    var accountID: String? = nil
    let fetched = Date()
    static func parse(_ result: [String: Any]) -> UsageSnapshot {
        var buckets = result["rateLimitsByLimitId"] as? [String: [String: Any]] ?? [:]
        if buckets.isEmpty, let legacy = result["rateLimits"] as? [String: Any] {
            buckets[legacy["limitId"] as? String ?? "codex"] = legacy
        }
        var windows: [(String, UsageWindow)] = []
        var plan: String?
        for key in buckets.keys.sorted(by: { a, b in a == "codex" ? b != "codex" : b == "codex" ? false : a < b }) {
            guard let bucket = buckets[key] else { continue }
            plan = plan ?? bucket["planType"] as? String
            let name = key == "codex" ? "Codex" : (bucket["limitName"] as? String ?? key)
            for slot in ["primary", "secondary"] {
                guard let raw = bucket[slot] as? [String: Any], let used = raw["usedPercent"] as? Double, used.isFinite else { continue }
                let reset = (raw["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
                windows.append((name, UsageWindow(used: used, minutes: raw["windowDurationMins"] as? Int, reset: reset)))
            }
        }
        let codex = buckets["codex"] ?? (result["rateLimits"] as? [String: Any])
        let credits = (codex?["credits"] as? [String: Any]).map(CreditsBalance.init)
        return UsageSnapshot(windows: windows, plan: plan, credits: credits, accountID: result["accountId"] as? String)
    }
}
// The service does not report reset history. Record only changes observed between reads.
enum LastResetDetection {
    static func observed(previous: UsageSnapshot, current: UsageSnapshot, now: Date = Date()) -> Date? {
        if let oldID = previous.accountID, let newID = current.accountID, oldID != newID { return nil }
        guard previous.plan == current.plan else { return nil }
        var detected: [Date] = []
        for (name, old) in previous.windows where name == "Codex" {
            guard let next = current.windows.first(where: { $0.0 == name && $0.1.minutes == old.minutes })?.1 else { continue }
            if old.minutes == 10080 {
                if next.used < old.used && next.used < 10 { detected.append(now) }
                continue
            }
            guard let oldReset = old.reset, let newReset = next.reset, newReset.timeIntervalSince(oldReset) > 60 else { continue }
            if oldReset <= now && oldReset > previous.fetched { detected.append(oldReset) }
            else if oldReset > now && old.used - next.used >= 5 { detected.append(now) }
        }
        return detected.max()
    }
}
struct CreditsBalance {
    let text: String
    init(_ raw: [String: Any]) {
        if raw["unlimited"] as? Bool == true { text = "∞"; return }
        if let amount = raw["balance"] as? String, amount.count <= 24,
           let value = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")), value >= 0 {
            let format = NumberFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.numberStyle = .decimal
            format.maximumFractionDigits = 0; format.minimumFractionDigits = 0
            text = format.string(from: NSDecimalNumber(decimal: value)) ?? amount
        } else if raw["hasCredits"] as? Bool == false { text = "0" }
        else { text = "—" }
    }
}
struct ExtraResetEvent: Codable {
    let id: String
    let kind: String
    let status: String
    let resetAt: String?
    let timeBasis: String
    let sourceURL: String
    let verifiedAt: String
    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let result = formatter.date(from: value) { return result }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
    func upcomingDate(now: Date) -> Date? {
        guard kind == "global_reset", status == "scheduled", ["exact", "by"].contains(timeBasis),
              let raw = resetAt, let reset = Self.date(raw), reset > now,
              let verified = Self.date(verifiedAt), verified <= now.addingTimeInterval(300),
              now.timeIntervalSince(verified) <= 48 * 3600,
              let source = URL(string: sourceURL), source.scheme == "https", source.host != nil else { return nil }
        return reset
    }
}
struct ExtraResetFeed: Codable {
    let schemaVersion: Int
    let updatedAt: String
    let events: [ExtraResetEvent]
    func next(now: Date = Date()) -> ExtraResetEvent? {
        guard schemaVersion == 1, let updated = ExtraResetEvent.date(updatedAt), updated <= now.addingTimeInterval(300), now.timeIntervalSince(updated) <= 48 * 3600 else { return nil }
        return events.filter { $0.upcomingDate(now: now) != nil }.min { $0.upcomingDate(now: now)! < $1.upcomingDate(now: now)! }
    }
}
struct NextReset {
    let date: Date?
    let extra: ExtraResetEvent?
    static func choose(normal: Date?, extra: ExtraResetEvent?, now: Date = Date()) -> NextReset {
        if let extra, let date = extra.upcomingDate(now: now), normal == nil || normal! <= now || date < normal! {
            return NextReset(date: date, extra: extra)
        }
        return NextReset(date: normal, extra: nil)
    }
    var label: String { extra == nil ? "Normal allowance reset" : (extra?.timeBasis == "by" ? "Extra reset expected by" : "Announced extra reset") }
    func countdown(now: Date = Date()) -> String {
        (extra?.timeBasis == "by" ? "≤" : "") + StatusDisplay.countdown(to: date, now: now)
    }
}
enum DisplayField: String, CaseIterable {
    case remaining, reset, credits
    var label: String {
        switch self { case .remaining: return "Percentage Remaining"; case .reset: return "Time Until Next Reset"; case .credits: return "Credits" }
    }
}
struct StatusDisplay {
    static func countdown(to reset: Date?, now: Date = Date()) -> String {
        guard let reset else { return "Reset —" }
        let seconds = reset.timeIntervalSince(now)
        if seconds <= 0 { return "Reset due" }
        if seconds < 60 { return "<1m" }
        let minutes = Int(seconds / 60)
        if minutes >= 1440 { return "\(minutes / 1440)d \((minutes % 1440) / 60)h" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
    static func values(snapshot: UsageSnapshot, fields: [DisplayField], stale: Bool, extraReset: ExtraResetEvent? = nil, now: Date = Date()) -> [String] {
        let available = snapshot.windows.map { $0.1.remaining }.min()
        let nextReset = NextReset.choose(normal: snapshot.windows.compactMap { $0.1.reset }.min(), extra: extraReset, now: now)
        return fields.map { field in
            let value: String
            switch field {
            case .remaining: value = available.map { "\($0)%" } ?? "—%"
            case .reset: value = nextReset.countdown(now: now)
            case .credits: value = snapshot.credits?.text ?? "—"
            }
            return value + (stale ? "*" : "")
        }
    }
    static func selectedValue(_ values: [String], index: Int) -> String {
        values.isEmpty ? "" : values[index % values.count]
    }
}
enum FetchError: Error { case unavailable, connection, timedOut, rejected }

// Read only: no model turns, credit purchases, or limit resets are requested.
func fetchUsage() throws -> UsageSnapshot {
    let locations = [
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
        "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
    ]
    guard let executable = locations.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw FetchError.unavailable }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["app-server"]
    process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
    let input = Pipe(), output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    var environment = ProcessInfo.processInfo.environment
    // Do not inherit a calling agent's session identity or tracing context.
    for key in environment.keys where key.hasPrefix("CODEX_THREAD") || key.hasPrefix("CODEX_TURN") || key.hasPrefix("OTEL_") { environment.removeValue(forKey: key) }
    process.environment = environment
    let done = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var buffer = Data()
    var completed = false
    var response: [String: Any]?
    func send(_ object: [String: Any]) {
        guard let bytes = try? JSONSerialization.data(withJSONObject: object) else { return }
        try? input.fileHandleForWriting.write(contentsOf: bytes + Data([10]))
    }
    output.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        lock.lock()
        defer { lock.unlock() }
        if completed { return }
        if data.isEmpty { completed = true; done.signal(); return }
        buffer.append(data)
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer[..<end]
            buffer.removeSubrange(...end)
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let id = object["id"] as? Int else { continue }
            if id == 1 {
                if object["error"] != nil { completed = true; done.signal(); return }
                send(["method": "initialized", "params": [:]])
                send(["id": 2, "method": "account/rateLimits/read"])
            } else if id == 2 {
                response = object["result"] as? [String: Any]
                completed = true; done.signal(); return
            }
        }
    }
    try process.run()
    defer {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
    send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "codex_usage_menu_bar", "title": "CodexGauge", "version": "1.0.0"]]])
    let status = done.wait(timeout: .now() + 25)
    lock.lock()
    let result = response
    completed = true
    lock.unlock()
    if status == .timedOut { throw FetchError.timedOut }
    guard let result else { throw FetchError.connection }
    return UsageSnapshot.parse(result)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    var snapshot: UsageSnapshot?
    var lastResetDetected: Date?
    var lastExtraNews: (date: Date, url: String)?
    var failure: String?
    var fetching = false
    var timer: Timer?
    var displayTimer: Timer?
    var displayIndex = 0
    var displayedText = ""
    var rotationSeconds: Int {
        let value = UserDefaults.standard.integer(forKey: "rotationSeconds")
        return [1, 2, 4, 6, 10, 15, 30].contains(value) ? value : 4
    }
    var planName: String {
        guard let plan = snapshot?.plan else { return "ChatGPT Plan" }
        return UsagePlanLabels.name(for: plan.lowercased()) ?? "ChatGPT " + plan.capitalized
    }
    var extraFeed: ExtraResetFeed?
    var announcementCache = AnnouncementCache.load()
    var announcementTimer: Timer?
    var checkingAnnouncements = false
    var announcementGeneration = 0
    var lastAnnouncementAttempt: Date?
    var announcementEnabled: Bool { UserDefaults.standard.object(forKey: "announcementEnabled") as? Bool ?? true }
    var announcementMinutes: Int {
        let value = UserDefaults.standard.integer(forKey: "announcementMinutes")
        return [5, 15, 60, 120, 360, 1440].contains(value) ? value : 60
    }
    var announcementSources: [AnnouncementSource] {
        guard let data = UserDefaults.standard.data(forKey: "announcementSources"),
              let values = try? JSONDecoder().decode([AnnouncementSource].self, from: data) else { return AnnouncementSource.defaults }
        var sources = values.filter { URL(string: $0.url).map(AnnouncementSource.allowed) == true }
        if !UserDefaults.standard.bool(forKey: "addedXMirrorSource") {
            if !sources.contains(where: { $0.url == AnnouncementSource.mirrorURL }) { sources.append(AnnouncementSource.mirror) }
            if let data = try? JSONEncoder().encode(sources) { UserDefaults.standard.set(data, forKey: "announcementSources"); UserDefaults.standard.set(true, forKey: "addedXMirrorSource") }
        }
        return Array(sources.prefix(10))
    }
    func archivePastExtraNews(now: Date = Date()) {
        guard announcementEnabled, let plan = snapshot?.plan, announcementCache.plan == plan else { return }
        let active = Set(announcementSources.filter { $0.enabled }.map { $0.url })
        for event in announcementCache.records.filter({ active.contains($0.source) }).flatMap({ $0.events }) {
            guard event.kind == "global_reset", event.status == "scheduled", event.timeBasis == "exact",
                  let raw = event.resetAt, let date = ExtraResetEvent.date(raw), date <= now,
                  let verified = ExtraResetEvent.date(event.verifiedAt), verified <= date, date.timeIntervalSince(verified) <= 48 * 3600,
                  let url = URL(string: event.sourceURL), AnnouncementSource.allowedLink(url),
                  lastExtraNews == nil || date > lastExtraNews!.date else { continue }
            lastExtraNews = (date, event.sourceURL)
            if let account = snapshot?.accountID {
                UserDefaults.standard.set(["account": account, "date": date, "url": event.sourceURL], forKey: "lastExtraResetNews")
            }
        }
    }
    func readExtraFeed() {
        archivePastExtraNews()
        extraFeed = announcementEnabled ? announcementCache.feed(sources: announcementSources, plan: snapshot?.plan) : nil
    }
    var nextReset: NextReset {
        NextReset.choose(normal: snapshot?.windows.compactMap { $0.1.reset }.min(), extra: extraFeed?.next())
    }
    var selectedFields: [DisplayField] {
        var saved = UserDefaults.standard.stringArray(forKey: "displayFields") ?? DisplayField.allCases.map { $0.rawValue }
        if !UserDefaults.standard.bool(forKey: "creditsDisplayAdded") {
            if !saved.contains(DisplayField.credits.rawValue) { saved.append(DisplayField.credits.rawValue) }
            UserDefaults.standard.set(saved, forKey: "displayFields")
            UserDefaults.standard.set(true, forKey: "creditsDisplayAdded")
        }
        return DisplayField.allCases.filter { saved.contains($0.rawValue) }
    }
    var launchButton: NSMenuItem?
    var welcome: NSWindow?
    var summaryLabel: NSTextField?
    func writeState(_ phase: String) {
        let state: [String: Any] = ["phase": phase, "pid": ProcessInfo.processInfo.processIdentifier, "iconVisible": item?.isVisible ?? false, "menuBarText": displayedText, "displayFields": selectedFields.map { $0.rawValue }, "displayIndex": displayIndex, "resetSource": nextReset.label, "extraEventID": nextReset.extra?.id ?? "", "iconWidth": item?.button?.frame.width ?? 0, "updated": Date().timeIntervalSince1970, "announcementMode": "direct", "announcementEnabled": announcementEnabled, "announcementMinutes": announcementMinutes, "rotationSeconds": rotationSeconds, "planName": planName, "logoLoaded": chatGPTLogo != nil, "canvasWidth": item?.button?.image?.size.width ?? 0, "renderedImageWidth": item?.button.map { $0.cell?.imageRect(forBounds: $0.bounds).width ?? 0 } ?? 0, "announcementChecks": announcementCache.records.map { ["source": $0.source, "error": $0.error ?? "", "events": $0.events.count] as [String: Any] }]
        if let bytes = try? JSONSerialization.data(withJSONObject: state) {
            try? bytes.write(to: URL(fileURLWithPath: "/private/tmp/codex-usagebar-state.json"), options: .atomic)
        }
    }
    func showWelcome() {
        if welcome == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 185), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "CodexGauge"; window.isReleasedWhenClosed = false
            let icon = NSImageView(frame: NSRect(x: 24, y: 99, width: 52, height: 40)); icon.image = usageIcon(used: 44, stale: false)
            window.contentView?.addSubview(icon)
            let heading = NSTextField(labelWithString: "Your usage, at a glance")
            heading.font = .boldSystemFont(ofSize: 17); heading.frame = NSRect(x: 90, y: 116, width: 250, height: 26)
            window.contentView?.addSubview(heading)
            let summary = NSTextField(wrappingLabelWithString: "Connecting to your ChatGPT plan…")
            summary.frame = NSRect(x: 24, y: 58, width: 312, height: 48); summaryLabel = summary
            window.contentView?.addSubview(summary)
            let button = NSButton(title: "Continue in Menu Bar", target: self, action: #selector(closeWelcome))
            button.bezelStyle = .rounded; button.frame = NSRect(x: 140, y: 16, width: 200, height: 32)
            window.contentView?.addSubview(button)
            window.center(); welcome = window
        }
        welcome?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func closeWelcome() { welcome?.orderOut(nil); UserDefaults.standard.set(true, forKey: "setupComplete") }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWelcome(); return true }
    let launchID = "local.codex.usagebar"
    var launchURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(launchID).plist") }

    func applicationDidFinishLaunching(_ notification: Notification) { writeState("launched") }
    func start() {
        NSApp.setActivationPolicy(.accessory)
        // Apply the requested new default once on upgrade; later choices remain persistent.
        if !UserDefaults.standard.bool(forKey: "hourlyAnnouncementDefaultApplied") {
            UserDefaults.standard.set(60, forKey: "announcementMinutes")
            UserDefaults.standard.set(true, forKey: "hourlyAnnouncementDefaultApplied")
        }
        UserDefaults.standard.set(0, forKey: "NSStatusItem Preferred Position PlanUsage")
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "PlanUsage"
        item.isVisible = true
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        item.button?.title = ""
        item.button?.image = usageIcon(used: nil, stale: false)
        item.button?.imagePosition = .imageOnly
        let menu = NSMenu(); menu.delegate = self; item.menu = menu
        writeState("status-created")
        if !UserDefaults.standard.bool(forKey: "setupComplete") { showWelcome() }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refresh() }
        restartAnnouncementTimer()
        checkAnnouncementsNow()
        restartDisplayTimer()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
    }
    func restartDisplayTimer() {
        displayTimer?.invalidate()
        displayIndex = 0
        updateTitle()
        let timer = Timer(timeInterval: Double(rotationSeconds), repeats: true) { [weak self] _ in
            guard let self else { return }
            self.displayIndex = self.selectedFields.count > 1 ? (self.displayIndex + 1) % self.selectedFields.count : 0
            self.updateTitle()
            if FileManager.default.fileExists(atPath: "/private/tmp/codex-usagebar-observe") { self.writeState("display-tick") }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }
    @objc func toggleDisplayField(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let field = DisplayField(rawValue: raw) else { return }
        var selected = selectedFields
        if selected.contains(field) { selected.removeAll { $0 == field } } else { selected.append(field) }
        UserDefaults.standard.set(selected.map { $0.rawValue }, forKey: "displayFields")
        restartDisplayTimer()
        rebuildMenu()
        writeState("display-selection")
    }
    @objc func setRotationInterval(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: "rotationSeconds")
        restartDisplayTimer(); rebuildMenu(); writeState("rotation-selection")
    }
    @objc func woke() { restartDisplayTimer(); refresh(); checkAnnouncementsNow() }
    @objc func refresh() {
        guard !fetching else { return }
        fetching = true
        rebuildMenu()
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try fetchUsage() }
            DispatchQueue.main.async {
                self.fetching = false
                switch result {
                case .success(let value):
                    let planChanged = self.snapshot?.plan != value.plan
                    if let previous = self.snapshot {
                        if previous.accountID != value.accountID || previous.plan != value.plan { self.lastResetDetected = nil; self.lastExtraNews = nil }
                        else if let detected = LastResetDetection.observed(previous: previous, current: value) {
                            self.lastResetDetected = detected
                            if let account = value.accountID { UserDefaults.standard.set(["account": account, "date": detected], forKey: "lastResetDetected") }
                        }
                    } else if let account = value.accountID, let saved = UserDefaults.standard.dictionary(forKey: "lastResetDetected"),
                              saved["account"] as? String == account, let date = saved["date"] as? Date, date <= Date() {
                        self.lastResetDetected = date
                    }
                    if self.snapshot == nil, let account = value.accountID, let saved = UserDefaults.standard.dictionary(forKey: "lastExtraResetNews"),
                       saved["account"] as? String == account, let date = saved["date"] as? Date, date <= Date(),
                       let raw = saved["url"] as? String, let url = URL(string: raw), AnnouncementSource.allowedLink(url) {
                        self.lastExtraNews = (date, raw)
                    }
                    self.snapshot = value; self.failure = nil
                    if planChanged || self.lastAnnouncementAttempt == nil { self.checkAnnouncementsNow() }
                case .failure(let error):
                    self.failure = (error as? FetchError) == .unavailable ? "Open the ChatGPT or Codex app to install its helper." : "Couldn’t refresh. Check your connection and ChatGPT sign-in."
                }
                self.updateTitle(); self.rebuildMenu()
                if let data = self.snapshot, let window = data.windows.first?.1 {
                    self.summaryLabel?.stringValue = "\(window.remaining)% remaining · \(Int(window.used))% used\nUpdates every five minutes. Click the fuel gauge for details."
                } else { self.summaryLabel?.stringValue = self.failure ?? "No usage limits reported." }
                self.writeState(self.failure == nil ? "live" : "refresh-failed")
            }
        }
    }
    lazy var chatGPTLogo: NSImage? = {
        guard let url = Bundle.main.url(forResource: "ChatGPTLogo@2x", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()
    func usageIcon(used: Double?, stale: Bool) -> NSImage {
        fuelGaugeIcon(used: used, stale: stale, logo: chatGPTLogo)
    }
    func updateTitle() {
        readExtraFeed()
        guard let data = snapshot, !data.windows.isEmpty else {
            displayedText = ""
            item.length = 34
            item.button?.title = ""
            item.button?.image = usageIcon(used: nil, stale: failure != nil)
            item.button?.toolTip = failure ?? "Usage figures unavailable"
            return
        }
        let expired = data.windows.contains { $0.1.reset.map { $0 <= Date() } ?? false }
        let stale = failure != nil || Date().timeIntervalSince(data.fetched) > 600 || expired
        let available = data.windows.map { $0.1.remaining }.min() ?? 0
        let values = StatusDisplay.values(snapshot: data, fields: selectedFields, stale: stale, extraReset: extraFeed?.next())
        let text = StatusDisplay.selectedValue(values, index: displayIndex)
        displayedText = text
        item.button?.title = ""
        // Render both slots into one fixed canvas. NSButton otherwise centers image + title
        // as a group, moving the icon even when the status item's total width stays fixed.
        let font = item.button?.font ?? NSFont.systemFont(ofSize: 12)
        let widest = values.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let composed = fixedStatusImage(icon: usageIcon(used: Double(100 - available), stale: stale), text: text, textWidth: ceil(widest), font: font)
        item.length = composed.size.width + 2
        item.button?.image = composed
        item.button?.setAccessibilityLabel("\(planName): \(text)")
        let resetText = nextReset.countdown()
        item.button?.toolTip = "\(available)% remaining · \(nextReset.label): \(resetText)" + (stale ? " · Last known data; refresh needed" : "")
    }
    func menuWillOpen(_ menu: NSMenu) { updateTitle(); rebuildMenu() }
    func add(_ title: String, action: Selector? = nil) {
        let row = NSMenuItem(title: title, action: action, keyEquivalent: "")
        row.target = self; row.isEnabled = action != nil; item.menu?.addItem(row)
    }
    func rebuildMenu() {
        readExtraFeed()
        guard let menu = item?.menu else { return }
        menu.removeAllItems()
        add(planName + " ↗", action: #selector(openPlanPage))
        menu.addItem(.separator())
        if let data = snapshot {
            if data.windows.isEmpty { add("No usage limits reported for this account") }
            let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .short
            for (bucket, window) in data.windows {
                add("\(bucket) · \(window.label): \(Int(window.used.rounded()))% used · \(window.remaining)% left")
                if let reset = window.reset { add("Resets \(formatter.string(from: reset))") }
            }
            add("Last reset detected: \(lastResetDetected.map { formatter.string(from: $0) } ?? "")")
            add("Credits: \(data.credits?.text ?? "—")")
            let clock = DateFormatter(); clock.timeStyle = .short
            add("Updated \(clock.string(from: data.fetched)) · every 5 minutes")
        } else if fetching { add("Reading your plan’s usage…") }
        if let reset = nextReset.date {
            let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .short
            menu.addItem(.separator())
            add("Next: \(nextReset.label)")
            add("\(formatter.string(from: reset)) · \(nextReset.countdown())")
        }
        if let failure { add(failure); if snapshot != nil { add("* Last known figures; refresh unavailable") } }
        menu.addItem(.separator())
        add(fetching ? "Refreshing…" : "Refresh Now", action: fetching ? nil : #selector(refresh))
        add("Open Usage Dashboard", action: #selector(dashboard))
        let upcoming = extraFeed?.next()
        let news = upcoming?.sourceURL ?? lastExtraNews?.url
        add(upcoming == nil && lastExtraNews != nil ? "Last Extra Reset News ↗" : "Next Extra Reset News ↗", action: news == nil ? nil : #selector(openExtraReset))
        menu.items.last?.toolTip = news == nil ? "No extra reset announcement available" : "Open the extra reset announcement"
        addAnnouncementMenu(to: menu)
        menu.addItem(.separator())
        let displayRow = NSMenuItem(title: "Display Fields", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        displayMenu.autoenablesItems = false
        for field in DisplayField.allCases {
            let row = NSMenuItem(title: field.label, action: #selector(toggleDisplayField(_:)), keyEquivalent: "")
            row.target = self; row.representedObject = field.rawValue
            row.state = selectedFields.contains(field) ? .on : .off
            displayMenu.addItem(row)
        }
        displayRow.submenu = displayMenu; menu.addItem(displayRow)
        let rotationRow = NSMenuItem(title: "Rotation Speed", action: nil, keyEquivalent: "")
        let rotationMenu = NSMenu()
        for seconds in [1, 2, 4, 6, 10, 15, 30] {
            let row = NSMenuItem(title: "Every \(seconds) \(seconds == 1 ? "second" : "seconds")", action: #selector(setRotationInterval(_:)), keyEquivalent: "")
            row.target = self; row.tag = seconds; row.state = rotationSeconds == seconds ? .on : .off
            rotationMenu.addItem(row)
        }
        rotationRow.submenu = rotationMenu; menu.addItem(rotationRow)
        add("Launch at Login", action: #selector(toggleLogin))
        menu.items.last?.state = FileManager.default.fileExists(atPath: launchURL.path) ? .on : .off
        add("Quit CodexGauge", action: #selector(quit))
    }
    @objc func openExtraReset() {
        readExtraFeed()
        guard let raw = extraFeed?.next()?.sourceURL ?? lastExtraNews?.url, let url = URL(string: raw), AnnouncementSource.allowedLink(url) else { return }
        NSWorkspace.shared.open(url)
    }
    func restartAnnouncementTimer() {
        announcementTimer?.invalidate()
        guard announcementEnabled else { updateTitle(); rebuildMenu(); return }
        let timer = Timer(timeInterval: Double(announcementMinutes * 60), repeats: true) { [weak self] _ in self?.checkAnnouncementsNow() }
        RunLoop.main.add(timer, forMode: .common); announcementTimer = timer
    }
    @objc func checkAnnouncementsNow() {
        guard announcementEnabled, !checkingAnnouncements else { return }
        checkingAnnouncements = true; lastAnnouncementAttempt = Date()
        let sources = announcementSources, previous = announcementCache, plan = snapshot?.plan, generation = announcementGeneration
        rebuildMenu()
        DispatchQueue.global(qos: .utility).async {
            let result = checkAnnouncements(sources: sources, previous: previous, plan: plan)
            DispatchQueue.main.async {
                self.checkingAnnouncements = false
                guard generation == self.announcementGeneration, self.snapshot?.plan == plan else { self.checkAnnouncementsNow(); return }
                self.archivePastExtraNews(); self.announcementCache = result; result.save()
                self.updateTitle(); self.rebuildMenu(); self.writeState("announcements-checked")
            }
        }
    }
    @objc func toggleAnnouncements() {
        UserDefaults.standard.set(!announcementEnabled, forKey: "announcementEnabled")
        announcementGeneration += 1
        restartAnnouncementTimer(); updateTitle(); rebuildMenu()
        if announcementEnabled { checkAnnouncementsNow() }
    }
    @objc func setAnnouncementInterval(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: "announcementMinutes")
        restartAnnouncementTimer(); rebuildMenu()
    }
    @objc func toggleAnnouncementSource(_ sender: NSMenuItem) {
        var sources = announcementSources
        guard sources.indices.contains(sender.tag) else { return }
        sources[sender.tag].enabled.toggle()
        saveAnnouncementSources(sources)
    }
    func saveAnnouncementSources(_ sources: [AnnouncementSource]) {
        if let data = try? JSONEncoder().encode(sources) { UserDefaults.standard.set(data, forKey: "announcementSources") }
        announcementGeneration += 1
        updateTitle(); rebuildMenu(); checkAnnouncementsNow()
    }
    @objc func addAnnouncementSource() {
        let alert = NSAlert(); alert.messageText = "Add an official announcement page"
        alert.informativeText = "Paste an HTTPS OpenAI news, help, or documentation URL. HTML pages and RSS feeds are supported. X pages require access this app doesn’t have."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24)); field.placeholderString = "https://…"
        alert.accessoryView = field; alert.addButton(withTitle: "Add"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), AnnouncementSource.allowed(url), announcementSources.count < 10 else {
            let error = NSAlert(); error.messageText = "Use an official OpenAI HTTPS URL"; error.informativeText = "Up to ten sources are supported. OpenAI News, Help Center, Learn, and Developers pages are accepted."; error.runModal(); return
        }
        guard !announcementSources.contains(where: { $0.url == raw }) else { return }
        let name = url.lastPathComponent.isEmpty ? (url.host ?? "Announcement") : String(url.lastPathComponent.prefix(48))
        saveAnnouncementSources(announcementSources + [AnnouncementSource(name: name, url: raw, enabled: true)])
    }
    @objc func openAnnouncementURL(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let url = URL(string: raw), AnnouncementSource.allowedLink(url) else { return }
        NSWorkspace.shared.open(url)
    }
    func addAnnouncementMenu(to menu: NSMenu) {
        let parent = NSMenuItem(title: "Reset Announcements", action: nil, keyEquivalent: ""), sub = NSMenu()
        sub.autoenablesItems = false
        func row(_ title: String, _ action: Selector? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; item.isEnabled = action != nil; sub.addItem(item); return item
        }
        row("Check Automatically", #selector(toggleAnnouncements)).state = announcementEnabled ? .on : .off
        let active = announcementSources.filter { $0.enabled }
        let relevant = announcementCache.records.filter { r in active.contains { $0.url == r.source } }
        let failures = relevant.filter { $0.error != nil }.count
        if !announcementEnabled { _ = row("Paused · showing normal reset") }
        else if checkingAnnouncements { _ = row("Checking announcements…") }
        else if active.isEmpty { _ = row("Choose at least one source below") }
        else if failures > 0 { _ = row("\(failures) of \(active.count) sources unavailable") }
        else if relevant.count == active.count {
            _ = row(extraFeed?.next() == nil ? "No confirmed upcoming reset found" : "Upcoming extra reset found")
        } else { _ = row("Waiting for first check") }
        if let checked = relevant.compactMap({ $0.checkedAt }).max() {
            let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short
            _ = row("Last successful check: \(f.string(from: checked))")
        }
        let now = row("Check Now", #selector(checkAnnouncementsNow)); now.isEnabled = announcementEnabled && !checkingAnnouncements
        sub.addItem(.separator())
        for (minutes, label) in [(5, "Every 5 minutes"), (15, "Every 15 minutes"), (60, "Every hour"), (120, "Every 2 hours"), (360, "Every 6 hours"), (1440, "Daily")] {
            let item = row(label, #selector(setAnnouncementInterval(_:))); item.tag = minutes
            item.state = announcementMinutes == minutes ? .on : .off
        }
        sub.addItem(.separator()); _ = row("Sources")
        for (index, source) in announcementSources.enumerated() {
            let item = row(source.name, #selector(toggleAnnouncementSource(_:))); item.tag = index; item.state = source.enabled ? .on : .off
            if let record = relevant.first(where: { $0.source == source.url }), let error = record.error { _ = row("  \(error)") }
        }
        _ = row("Add Official Source…", #selector(addAnnouncementSource))
        for url in Set(relevant.flatMap { $0.reviewURLs }).sorted().prefix(3) {
            let item = row("Review announcement — timing or eligibility unclear", #selector(openAnnouncementURL(_:))); item.representedObject = url
        }
        parent.submenu = sub; menu.addItem(parent)
    }
    @objc func dashboard() { NSWorkspace.shared.open(URL(string: "https://chatgpt.com/settings/usage")!) }
    @objc func openPlanPage() {
        NSWorkspace.shared.open(URL(string: "https://chatgpt.com/settings/billing?mweb_fallback=1")!)
    }

    @objc func toggleLogin() {
        do {
            if FileManager.default.fileExists(atPath: launchURL.path) {
                try FileManager.default.removeItem(at: launchURL)
            } else {
                guard let executable = Bundle.main.executableURL?.path else { return }
                let plist: [String: Any] = ["Label": launchID, "ProgramArguments": [executable], "RunAtLoad": true, "ProcessType": "Interactive"]
                try FileManager.default.createDirectory(at: launchURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: launchURL, options: .atomic)
            }
        } catch {
            let alert = NSAlert(); alert.messageText = "Couldn’t change Launch at Login"; alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }
    @objc func quit() { NSApp.terminate(nil) }
}

if CommandLine.arguments.contains("--test-announcements") {
    do { try testAnnouncements(); exit(0) } catch { print(error); exit(1) }
}
if CommandLine.arguments.contains("--check-announcements") {
    let result = checkAnnouncements(sources: AnnouncementSource.defaults, previous: AnnouncementCache(), plan: "pro")
    for r in result.records { print("\(r.source): \(r.error ?? "OK"), \(r.events.count) future resets, \(r.reviewURLs.count) to review") }
    exit(result.records.contains { $0.error != nil } ? 1 : 0)
}
if CommandLine.arguments.contains("--test-display") {
    let now = Date(timeIntervalSince1970: 100000)
    func date(_ seconds: Double) -> Date { now.addingTimeInterval(seconds) }
    assert(StatusDisplay.countdown(to: nil, now: now) == "Reset —")
    assert(StatusDisplay.countdown(to: date(-1), now: now) == "Reset due")
    assert(StatusDisplay.countdown(to: date(59), now: now) == "<1m")
    assert(StatusDisplay.countdown(to: date(60), now: now) == "1m")
    assert(StatusDisplay.countdown(to: date(3660), now: now) == "1h 1m")
    assert(StatusDisplay.countdown(to: date(90000), now: now) == "1d 1h")
    let sample = UsageSnapshot(windows: [("Codex", UsageWindow(used: 45, minutes: 10080, reset: date(90000))), ("Other", UsageWindow(used: 60, minutes: 300, reset: date(3660)))], plan: "pro")
    let values = StatusDisplay.values(snapshot: sample, fields: [.remaining, .reset], stale: false, now: now)
    assert(values == ["40%", "1h 1m"])
    assert(StatusDisplay.selectedValue(values, index: 0) == "40%")
    assert(StatusDisplay.selectedValue(values, index: 1) == "1h 1m")
    assert(StatusDisplay.selectedValue(values, index: 2) == "40%")
    assert(StatusDisplay.values(snapshot: sample, fields: [], stale: false, now: now).isEmpty)
    assert(StatusDisplay.selectedValue([], index: 3) == "")
    assert(StatusDisplay.values(snapshot: sample, fields: [.remaining], stale: true, now: now) == ["40%*"])
    assert(StatusDisplay.selectedValue(["40%"], index: 7) == "40%")
    let iso = ISO8601DateFormatter()
    func event(_ seconds: Double, status: String = "scheduled", kind: String = "global_reset", basis: String = "exact", verified: Date? = nil) -> ExtraResetEvent {
        ExtraResetEvent(id: "test-only", kind: kind, status: status, resetAt: iso.string(from: date(seconds)), timeBasis: basis, sourceURL: "https://openai.com/", verifiedAt: iso.string(from: verified ?? now))
    }
    assert(NextReset.choose(normal: date(1000), extra: event(500), now: now).extra != nil)
    assert(NextReset.choose(normal: date(1000), extra: event(1500), now: now).extra == nil)
    assert(NextReset.choose(normal: date(1000), extra: event(-1), now: now).extra == nil)
    assert(NextReset.choose(normal: date(1000), extra: event(500, status: "completed"), now: now).extra == nil)
    assert(NextReset.choose(normal: date(1000), extra: event(500, status: "cancelled"), now: now).extra == nil)
    assert(NextReset.choose(normal: date(1000), extra: event(500, kind: "banked_reset"), now: now).extra == nil)
    assert(NextReset.choose(normal: date(1000), extra: event(500, basis: "unknown"), now: now).extra == nil)
    assert(NextReset.choose(normal: date(1000), extra: event(500, verified: date(-49 * 3600)), now: now).extra == nil)
    assert(NextReset.choose(normal: date(1000), extra: event(500, basis: "by"), now: now).countdown(now: now) == "≤8m")
    assert(NextReset.choose(normal: nil, extra: event(500), now: now).extra != nil)
    let feed = ExtraResetFeed(schemaVersion: 1, updatedAt: iso.string(from: now), events: [event(700), event(500)])
    assert(feed.next(now: now)?.upcomingDate(now: now) == date(500))
    assert(ExtraResetFeed(schemaVersion: 1, updatedAt: iso.string(from: date(-49 * 3600)), events: [event(500)]).next(now: now) == nil)
    let detectionNow = Date()
    let previousReset = detectionNow.addingTimeInterval(120)
    let beforeReset = UsageSnapshot(windows: [("Codex", UsageWindow(used: 50, minutes: 10080, reset: previousReset))], plan: "pro", accountID: "account-a")
    let afterReset = UsageSnapshot(windows: [("Codex", UsageWindow(used: 0, minutes: 10080, reset: previousReset.addingTimeInterval(604800)))], plan: "pro", accountID: "account-a")
    assert(LastResetDetection.observed(previous: beforeReset, current: afterReset, now: previousReset.addingTimeInterval(60)) == previousReset.addingTimeInterval(60))
    let anotherAccount = UsageSnapshot(windows: afterReset.windows, plan: "pro", accountID: "account-b")
    assert(LastResetDetection.observed(previous: beforeReset, current: anotherAccount, now: previousReset.addingTimeInterval(60)) == nil)
    let extraBefore = UsageSnapshot(windows: [("Codex", UsageWindow(used: 70, minutes: 10080, reset: previousReset))], plan: "pro", accountID: "account-a")
    assert(LastResetDetection.observed(previous: extraBefore, current: afterReset, now: detectionNow) == detectionNow)
    assert(LastResetDetection.observed(previous: beforeReset, current: beforeReset, now: detectionNow) == nil)
    let weeklyDrop = UsageSnapshot(windows: [("Codex", UsageWindow(used: 9, minutes: 10080, reset: previousReset))], plan: "pro", accountID: "account-a")
    assert(LastResetDetection.observed(previous: beforeReset, current: weeklyDrop, now: detectionNow) == detectionNow)
    let atThreshold = UsageSnapshot(windows: [("Codex", UsageWindow(used: 10, minutes: 10080, reset: previousReset.addingTimeInterval(604800)))], plan: "pro", accountID: "account-a")
    assert(LastResetDetection.observed(previous: beforeReset, current: atThreshold, now: detectionNow) == nil)
    let noDrop = UsageSnapshot(windows: [("Codex", UsageWindow(used: 9, minutes: 10080, reset: previousReset))], plan: "pro", accountID: "account-a")
    assert(LastResetDetection.observed(previous: noDrop, current: noDrop, now: detectionNow) == nil)
    let otherDrop = UsageSnapshot(windows: [("Other", UsageWindow(used: 0, minutes: 10080, reset: previousReset))], plan: "pro", accountID: "account-a")
    assert(LastResetDetection.observed(previous: beforeReset, current: otherDrop, now: detectionNow) == nil)
    let withCredits = UsageSnapshot.parse(["rateLimits": ["limitId": "codex", "credits": ["balance": "12.50", "hasCredits": true, "unlimited": false]]])
    assert(withCredits.credits?.text == "12")
    assert(StatusDisplay.values(snapshot: withCredits, fields: [.credits], stale: false) == ["12"])
    assert(CreditsBalance(["balance": NSNull(), "hasCredits": false, "unlimited": false]).text == "0")
    assert(CreditsBalance(["hasCredits": true, "unlimited": false]).text == "—")
    assert(CreditsBalance(["hasCredits": true, "unlimited": true]).text == "∞")
    print("Passed: display rotation and earliest valid reset; completed, cancelled, past, vague, banked, and stale extra resets excluded.")
    exit(0)
}
if CommandLine.arguments.contains("--check") {
    do {
        let snapshot = try fetchUsage()
        print("Connected. Plan: \(snapshot.plan ?? "unavailable")")
        for (name, window) in snapshot.windows { print("\(name) \(window.label): \(Int(window.used))% used, \(window.remaining)% remaining") }
        exit(snapshot.windows.isEmpty ? 2 : 0)
    } catch { print("Usage connection failed: \(error)"); exit(1) }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
delegate.start()
withExtendedLifetime(delegate) { app.run() }
