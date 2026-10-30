import Foundation

// Read the installed Usage & billing page's display labels as data. Never execute its JavaScript.
enum UsagePlanLabels {
    private static var stamp: Date?
    private static var labels: [String: String] = [:]
    private static let archive = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/app.asar")
    static func name(for plan: String) -> String? {
        let modified = try? archive.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if modified != stamp {
            stamp = modified
            labels = (try? load()) ?? [:]
        }
        return labels[plan]
    }
    private static func load() throws -> [String: String] {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        guard let prefix = try handle.read(upToCount: 16), prefix.count == 16 else { return [:] }
        func number(_ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | (Int(prefix[offset + $1]) << (8 * $1)) }
        }
        let base = 8 + number(4), headerSize = number(12)
        guard headerSize > 0, headerSize < 16_000_000, base >= headerSize else { return [:] }
        guard let header = try handle.read(upToCount: headerSize),
              let root = try JSONSerialization.jsonObject(with: header) as? [String: Any],
              let files = root["files"] as? [String: Any],
              let web = files["webview"] as? [String: Any], let webFiles = web["files"] as? [String: Any],
              let assets = webFiles["assets"] as? [String: Any], let assetFiles = assets["files"] as? [String: Any],
              let entry = assetFiles.first(where: { $0.key.hasPrefix("_virtual_settings-search-documents-") && $0.key.hasSuffix(".js") })?.value as? [String: Any],
              let offsetString = entry["offset"] as? String, let offset = Int(offsetString), offset >= 0,
              let size = entry["size"] as? Int, size > 0, size < 12_000_000 else { return [:] }
        try handle.seek(toOffset: UInt64(base + offset))
        guard let data = try handle.read(upToCount: size), let source = String(data: data, encoding: .utf8) else { return [:] }
        let ns = source as NSString
        let regex = try NSRegularExpression(pattern: #"defaultMessage:`([^`]+)`,id:`settings\.usage\.plan\.([^`]+)`"#)
        var names: [String: String] = [:]
        for m in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            let value = ns.substring(with: m.range(at: 1)), key = ns.substring(with: m.range(at: 2))
            if key == "pro.numberedTiers" {
                guard let start = value.range(of: "{plan, select,") else { continue }
                let prefix = String(value[..<start.lowerBound])
                let options = try NSRegularExpression(pattern: #"\b([a-z][a-z0-9_]*)\s*\{([^{}]+)\}"#)
                for option in options.matches(in: value, range: NSRange(location: 0, length: (value as NSString).length)) {
                    let id = (value as NSString).substring(with: option.range(at: 1))
                    if id != "other" { names[id] = prefix + (value as NSString).substring(with: option.range(at: 2)) }
                }
            } else if value.hasPrefix("ChatGPT "), !value.contains("{"), value.count < 80 {
                names[key] = value
            }
        }
        return names
    }
}
