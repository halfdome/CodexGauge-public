import Foundation

struct UsageEvent: Codable {
    enum Kind: String, Codable {
        case started, stopped, sleep, wake, timeout, helperUnavailable, refreshFailed, recordingFailed, resumed
        var label: String {
            switch self {
            case .started: return "App started"
            case .stopped: return "App stopped"
            case .sleep: return "Mac entered sleep"
            case .wake: return "Mac woke up"
            case .timeout: return "Usage request timed out"
            case .helperUnavailable: return "Codex helper unavailable"
            case .refreshFailed: return "Usage request failed"
            case .recordingFailed: return "No weekly reading saved"
            case .resumed: return "Recording resumed"
            }
        }
    }
    let date: Date
    let kind: Kind
}

final class UsageEvents {
    private let url: URL
    private(set) var entries: [UsageEvent]
    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CodexGauge/usage-events.json")) {
        self.url = url
        entries = (try? JSONDecoder().decode([UsageEvent].self, from: Data(contentsOf: url))) ?? []
    }
    func record(_ kind: UsageEvent.Kind, now: Date = Date()) {
        entries.removeAll { $0.date < now.addingTimeInterval(-UsageHistory.retention) || $0.date > now.addingTimeInterval(300) }
        entries.append(UsageEvent(date: now, kind: kind))
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(entries).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { NSLog("CodexGauge: unable to save usage events: %@", error.localizedDescription) }
    }
    // These are events observed during the gap, not an inferred cause for every instant.
    static func details(at date: Date, points: [UsageHistoryPoint], events: [UsageEvent]) -> [String] {
        guard let left = points.last(where: { $0.date <= date }), date > left.date,
              UsageChartData.reading(at: date, points: points) == nil else { return ["Reason not recorded"] }
        let right = points.first(where: { $0.date > date })?.date ?? date
        let sorted = events.sorted { $0.date < $1.date }
        var found = sorted.filter { $0.date > left.date && $0.date <= right }
        let power = sorted.last { $0.date <= left.date && [.sleep, .wake, .started].contains($0.kind) }
        if let power, power.kind == .sleep { found.insert(power, at: 0) }
        guard !found.isEmpty else { return ["Reason not recorded"] }
        let formatter = DateFormatter(); formatter.dateFormat = "MMM d, HH:mm z"
        var seen = Set<UsageEvent.Kind>()
        let unique = found.filter { seen.insert($0.kind).inserted }
        let lines = unique.prefix(5).map { "\(formatter.string(from: $0.date)) · \($0.kind.label)" }
        return ["Recorded during this gap:"] + lines + (unique.count > 5 ? ["Additional events recorded locally"] : [])
    }
}
