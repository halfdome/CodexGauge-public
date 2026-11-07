import Cocoa

struct UsageHistoryPoint: Codable {
    let date: Date
    let used: Double
    let accountID: String?
}

final class UsageHistory {
    static let retention: TimeInterval = 30 * 24 * 3600
    private let url: URL
    private(set) var points: [UsageHistoryPoint]
    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CodexGauge/usage-history.json")) {
        self.url = url
        points = (try? JSONDecoder().decode([UsageHistoryPoint].self, from: Data(contentsOf: url))) ?? []
    }
    @discardableResult
    func record(_ snapshot: UsageSnapshot, now: Date = Date()) -> Bool {
        guard let weekly = snapshot.windows.first(where: { $0.0 == "Codex" && $0.1.minutes == 10080 })?.1,
              weekly.used.isFinite, (0...100).contains(weekly.used) else { return false }
        points.removeAll { $0.date < now.addingTimeInterval(-Self.retention) || $0.date > now.addingTimeInterval(300) }
        points.append(UsageHistoryPoint(date: now, used: weekly.used, accountID: snapshot.accountID))
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(points)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch { NSLog("CodexGauge: unable to save usage history: %@", error.localizedDescription); return false }
    }
    func visible(accountID: String?, now: Date = Date()) -> [UsageHistoryPoint] {
        points.filter { $0.accountID == accountID && $0.date >= now.addingTimeInterval(-Self.retention) && $0.date <= now.addingTimeInterval(300) }.sorted { $0.date < $1.date }
    }
}

// A connector across a missed refresh is visual continuity, never a measurement.
enum UsageChartData {
    static let gapThreshold: TimeInterval = 450
    static func reading(at date: Date, points: [UsageHistoryPoint]) -> UsageHistoryPoint? {
        guard let first = points.first, let last = points.last,
              date >= first.date, date <= last.date else { return nil }
        if let exact = points.first(where: { $0.date == date }) { return exact }
        guard let right = points.firstIndex(where: { $0.date > date }), right > 0 else { return last }
        let a = points[right - 1], b = points[right]
        guard b.date.timeIntervalSince(a.date) <= gapThreshold else { return nil }
        return date.timeIntervalSince(a.date) <= b.date.timeIntervalSince(date) ? a : b
    }
}

final class UsageChartView: NSView {
    private let mint = NSColor(calibratedRed: 0.18, green: 0.80, blue: 0.46, alpha: 1)
    private let muted = NSColor(calibratedWhite: 0.65, alpha: 1)
    private let ranges: [TimeInterval] = [86400, 7 * 86400, 30 * 86400]
    private var selectedRange = 1
    private var hover: NSPoint?
    private var tracking: NSTrackingArea?
    private var clock = Date()
    private var tick: Timer?
    private lazy var rangeControl: NSSegmentedControl = {
        let control = NSSegmentedControl(labels: ["24H", "7D", "30D"], trackingMode: .selectOne, target: self, action: #selector(changeRange(_:)))
        control.selectedSegment = selectedRange
        control.segmentStyle = .rounded
        control.setAccessibilityLabel("History time range")
        return control
    }()
    var events: [UsageEvent] = [] { didSet { needsDisplay = true } }
    var points: [UsageHistoryPoint] = [] {
        didSet {
            clock = Date(); hover = nil; needsDisplay = true
            setAccessibilityValue(points.last.map { "Latest reading: \(Int($0.used.rounded())) percent used" } ?? "No recorded usage")
        }
    }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)
        addSubview(rangeControl)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Weekly Codex usage history")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tick?.invalidate()
        if window != nil {
            tick = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                self?.clock = Date(); self?.needsDisplay = true
            }
        }
    }
    deinit { tick?.invalidate() }
    override func layout() {
        super.layout()
        rangeControl.frame = NSRect(x: bounds.width - 226, y: 31, width: 194, height: 29)
    }
    @objc private func changeRange(_ sender: NSSegmentedControl) {
        selectedRange = sender.selectedSegment; clock = Date(); hover = nil; needsDisplay = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseMoved(with event: NSEvent) { hover = convert(event.locationInWindow, from: nil); needsDisplay = true }
    override func mouseDown(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { hover = nil; needsDisplay = true }
    private func text(_ string: String, at point: NSPoint, size: CGFloat = 12, color: NSColor? = nil, weight: NSFont.Weight = .regular) {
        (string as NSString).draw(at: point, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color ?? muted])
    }
    private func stroke(_ a: NSPoint, _ b: NSPoint, color: NSColor, width: CGFloat = 1, dashed: Bool = false) {
        let path = NSBezierPath(); path.move(to: a); path.line(to: b); path.lineWidth = width; path.lineCapStyle = .round
        if dashed { path.setLineDash([5, 5], count: 2, phase: 0) }
        color.setStroke(); path.stroke()
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.115, alpha: 1).setFill(); bounds.fill()
        text("Usage History", at: NSPoint(x: 32, y: 25), size: 24, color: .white, weight: .semibold)
        text("Weekly Codex usage · % used", at: NSPoint(x: 33, y: 59), size: 13)
        let plot = NSRect(x: 66, y: 112, width: bounds.width - 100, height: bounds.height - 248)
        let end = clock, start = end.addingTimeInterval(-ranges[selectedRange])
        var samples: [UsageHistoryPoint] = points.filter { point in point.used.isFinite && point.used >= 0 && point.used <= 100 && point.date <= end }
        samples.sort { $0.date < $1.date }
        func position(_ point: UsageHistoryPoint) -> NSPoint {
            NSPoint(x: plot.minX + CGFloat(point.date.timeIntervalSince(start) / ranges[selectedRange]) * plot.width,
                    y: plot.maxY - CGFloat(point.used / 100) * plot.height)
        }
        for value in stride(from: 0, through: 100, by: 25) {
            let y = plot.maxY - CGFloat(value) / 100 * plot.height
            stroke(NSPoint(x: plot.minX, y: y), NSPoint(x: plot.maxX, y: y), color: NSColor(white: 1, alpha: 0.09))
            text("\(value)%", at: NSPoint(x: 22, y: y - 7), size: 11)
        }
        let axis = DateFormatter(); axis.dateFormat = selectedRange == 0 ? "HH:mm" : "MMM d"
        for i in 0...5 {
            let x = plot.minX + CGFloat(i) / 5 * plot.width
            let date = start.addingTimeInterval(ranges[selectedRange] * Double(i) / 5)
            let label = axis.string(from: date)
            let width = (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width
            text(label, at: NSPoint(x: x - width / 2, y: plot.maxY + 12), size: 11)
        }
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: plot.insetBy(dx: -2, dy: -3)).addClip()
        var hasGap = false
        for index in samples.indices where index > 0 {
            let a = samples[index - 1], b = samples[index]
            guard b.date >= start else { continue }
            let missing = b.date.timeIntervalSince(a.date) > UsageChartData.gapThreshold
            hasGap = hasGap || missing
            stroke(position(a), position(b), color: missing ? NSColor(white: 0.76, alpha: 1) : mint, width: missing ? 1.0 : 1.3, dashed: missing)
        }
        NSGraphicsContext.restoreGraphicsState()
        let visible = samples.filter { $0.date >= start }
        if visible.isEmpty {
            text("No readings in this time range", at: NSPoint(x: plot.midX - 100, y: plot.midY), size: 13)
        } else if visible.count == 1 {
            text("One reading saved. More points appear after refresh.", at: NSPoint(x: 33, y: plot.maxY + 43), size: 11)
        } else if hasGap {
            stroke(NSPoint(x: 33, y: plot.maxY + 50), NSPoint(x: 59, y: plot.maxY + 50), color: NSColor(white: 0.76, alpha: 1), dashed: true)
            text("No recorded data", at: NSPoint(x: 67, y: plot.maxY + 43), size: 11)
        }
        stroke(NSPoint(x: 32, y: bounds.height - 76), NSPoint(x: bounds.width - 32, y: bounds.height - 76), color: NSColor(white: 1, alpha: 0.13))
        text("Latest reading", at: NSPoint(x: 33, y: bounds.height - 63), size: 11)
        if let last = samples.last {
            text("\(Int(last.used.rounded()))% used", at: NSPoint(x: 33, y: bounds.height - 43), size: 23, color: .white, weight: .semibold)
            text("\(Int((100 - last.used).rounded()))% remaining", at: NSPoint(x: 205, y: bounds.height - 34), size: 12)
            let formatter = DateFormatter(); formatter.dateFormat = "MMM d, HH:mm z"
            text(formatter.string(from: last.date), at: NSPoint(x: bounds.width - 200, y: bounds.height - 34), size: 11)
        } else { text("—", at: NSPoint(x: 33, y: bounds.height - 43), size: 23) }
        guard let hover, plot.contains(hover) else { return }
        let target = start.addingTimeInterval(Double((hover.x - plot.minX) / plot.width) * ranges[selectedRange])
        // Classify by time before selecting a reading; never snap across a gap.
        let reading = UsageChartData.reading(at: target, points: samples)
        let x = reading.map { position($0).x } ?? hover.x
        stroke(NSPoint(x: x, y: plot.minY), NSPoint(x: x, y: plot.maxY), color: NSColor(white: 0.7, alpha: 0.6))
        if let reading {
            let p = position(reading); mint.setFill(); NSBezierPath(ovalIn: NSRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)).fill()
        }
        let formatter = DateFormatter(); formatter.dateFormat = "MMM d, HH:mm:ss z"
        let dateLabel = formatter.string(from: reading?.date ?? target)
        let valueLabel = reading.map { "\(Int($0.used.rounded()))% used · \(Int((100 - $0.used).rounded()))% remaining" } ?? "No recorded data"
        let details = reading == nil ? UsageEvents.details(at: target, points: samples, events: events) : []
        let boxWidth: CGFloat = details.isEmpty ? 242 : 370
        let boxHeight = CGFloat(62 + details.count * 19)
        let box = NSRect(x: min(max(16, x - boxWidth / 2), bounds.width - boxWidth - 16), y: max(80, min(hover.y - boxHeight - 12, bounds.height - boxHeight - 16)), width: boxWidth, height: boxHeight)
        let bubble = NSBezierPath(roundedRect: box, xRadius: 9, yRadius: 9)
        NSColor(calibratedWhite: 0.19, alpha: 0.98).setFill(); bubble.fill()
        NSColor(white: 1, alpha: 0.2).setStroke(); bubble.lineWidth = 0.7; bubble.stroke()
        text(dateLabel, at: NSPoint(x: box.minX + 13, y: box.minY + 10), size: 12, color: .white, weight: .medium)
        text(valueLabel, at: NSPoint(x: box.minX + 13, y: box.minY + 34), size: 12)
        for (index, detail) in details.enumerated() {
            text(detail, at: NSPoint(x: box.minX + 13, y: box.minY + 57 + CGFloat(index * 19)), size: 11)
        }
    }
}
