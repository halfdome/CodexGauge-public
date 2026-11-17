import Foundation

// Read installed display labels as data. Never execute vendor JavaScript.
enum UsagePlanLabels {
    private static var stamp: Date?
    private static var labels: [String: String] = [:]
    private static let archive = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/app.asar")
    static func name(for plan: String) -> String? {
        let modified = try? archive.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if modified != stamp {
            stamp = modified
            labels = (try? load(from: archive)) ?? [:]
        }
        return labels[plan]
    }
    static func load(from archive: URL) throws -> [String: String] {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        guard let prefix = try handle.read(upToCount: 16), prefix.count == 16 else { return [:] }
        func number(_ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | (Int(prefix[offset + $1]) << (8 * $1)) }
        }
        let base = 8 + number(4), headerSize = number(12)
        guard headerSize > 0, headerSize < 16_000_000, base >= 16 + headerSize,
              let header = try handle.read(upToCount: headerSize),
              let root = try JSONSerialization.jsonObject(with: header) as? [String: Any],
              let files = root["files"] as? [String: Any],
              let web = files["webview"] as? [String: Any], let webFiles = web["files"] as? [String: Any],
              let assets = webFiles["assets"] as? [String: Any] else { return [:] }
        var entries: [(path: String, offset: Int, size: Int)] = []
        func collect(_ node: [String: Any], path: String, depth: Int) {
            guard depth < 8, let children = node["files"] as? [String: [String: Any]] else { return }
            for (name, value) in children {
                let childPath = path + "/" + name
                if value["files"] != nil { collect(value, path: childPath, depth: depth + 1); continue }
                guard name.hasSuffix(".js"), let offsetText = value["offset"] as? String,
                      let offset = Int(offsetText), offset >= 0, offset < Int.max - base,
                      let size = value["size"] as? Int, size > 0, size < 2_000_000 else { continue }
                entries.append((childPath, offset, size))
            }
        }
        collect(assets, path: "assets", depth: 0)
        // Old named bundles are cheap to try first; new builds use numeric chunks in async/.
        entries.sort {
            let first = $0.path.contains("settings-search-documents"), second = $1.path.contains("settings-search-documents")
            return first != second ? first : $0.offset < $1.offset
        }
        let marker = Data("settings.usage.plan.".utf8)
        var names: [String: String] = [:], remainingBytes = 128_000_000
        for entry in entries {
            guard entry.size <= remainingBytes else { break }
            remainingBytes -= entry.size
            try handle.seek(toOffset: UInt64(base + entry.offset))
            guard let data = try handle.read(upToCount: entry.size), data.count == entry.size,
                  data.range(of: marker) != nil, let source = String(data: data, encoding: .utf8) else { continue }
            names.merge(parse(source)) { old, new in new }
            if names["pro"] != nil && names["prolite"] != nil && names["promax"] != nil { break }
        }
        return names
    }
    static func parse(_ source: String) -> [String: String] {
        let literal = #"("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`)"#
        func decode(_ value: String) -> String? {
            if value.first == "\"" { return try? JSONDecoder().decode(String.self, from: Data(value.utf8)) }
            let text = String(value.dropFirst().dropLast())
            guard !text.contains("\\"), !text.contains("${") else { return nil }
            return text
        }
        let ns = source as NSString
        var messages: [(String, String)] = []
        for reversed in [false, true] {
            let first = reversed ? "id" : "defaultMessage", second = reversed ? "defaultMessage" : "id"
            let pattern = first + #"\s*:\s*"# + literal + #"\s*,\s*"# + second + #"\s*:\s*"# + literal
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
                guard let a = decode(ns.substring(with: match.range(at: 1))), let b = decode(ns.substring(with: match.range(at: 2))) else { continue }
                messages.append(reversed ? (a, b) : (b, a))
            }
        }
        var names: [String: String] = [:]
        for (id, value) in messages where id.hasPrefix("settings.usage.plan.") {
            let key = String(id.dropFirst("settings.usage.plan.".count))
            if key == "pro.numberedTiers" {
                guard let start = value.range(of: "{plan, select,"), value.hasPrefix("ChatGPT "), value.count < 1000 else { continue }
                let prefix = String(value[..<start.lowerBound])
                let options = try! NSRegularExpression(pattern: #"\b([a-z][a-z0-9_]*)\s*\{([^{}]+)\}"#)
                let message = value as NSString
                for option in options.matches(in: value, range: NSRange(location: 0, length: message.length)) {
                    let code = message.substring(with: option.range(at: 1))
                    let label = prefix + message.substring(with: option.range(at: 2))
                    if code != "other", label.count < 80 { names[code] = label }
                }
            } else if value.hasPrefix("ChatGPT "), !value.contains("{"), value.count < 80, names[key] == nil {
                names[key] = value
            }
        }
        return names
    }
}

func testPlanLabels() throws {
    let old = #"{defaultMessage:`ChatGPT {plan, select, prolite {Pro 100} pro {Pro 200} promax {Pro 500} other {Pro}}`,id:`settings.usage.plan.pro.numberedTiers`}"#
    let current = #"{id:"settings.usage.plan.pro.numberedTiers",defaultMessage:"ChatGPT {plan, select, prolite {Pro 100} pro {Pro 200} promax {Pro 500} other {Pro}}",description:"SKU names"}"#
    assert(UsagePlanLabels.parse(old)["pro"] == "ChatGPT Pro 200")
    assert(UsagePlanLabels.parse(current)["pro"] == "ChatGPT Pro 200")
    assert(UsagePlanLabels.parse(current)["prolite"] == "ChatGPT Pro 100")
    assert(UsagePlanLabels.parse(current)["promax"] == "ChatGPT Pro 500")
    assert(UsagePlanLabels.parse(current)["other"] == nil)
    assert(UsagePlanLabels.parse(#"{defaultMessage:"ChatGPT Plus",id:"settings.usage.plan.plus"}"#)["plus"] == "ChatGPT Plus")
    assert(UsagePlanLabels.parse(#"{id:"unrelated.pro",defaultMessage:"ChatGPT Pro 999"}"#)["pro"] == nil)
    assert(UsagePlanLabels.parse("no supported labels").isEmpty)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CodexGauge-plan-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = directory.appendingPathComponent("fixture.asar")
    func fixture(_ children: [String: Any], source: String) throws {
        let root: [String: Any] = ["files": ["webview": ["files": ["assets": ["files": children]]]]]
        let header = try JSONSerialization.data(withJSONObject: root)
        var data = Data()
        for number in [4, header.count + 8, header.count + 4, header.count] {
            var word = UInt32(number).littleEndian
            withUnsafeBytes(of: &word) { data.append(contentsOf: $0) }
        }
        data.append(header); data.append(Data(source.utf8)); try data.write(to: archive)
    }
    try fixture(["async": ["files": ["123.hash.js": ["offset": "0", "size": current.utf8.count]]]], source: current)
    let nestedLabels = try UsagePlanLabels.load(from: archive)
    assert(nestedLabels["pro"] == "ChatGPT Pro 200")
    try fixture(["_virtual_settings-search-documents-hash.js": ["offset": "0", "size": old.utf8.count]], source: old)
    let legacyLabels = try UsagePlanLabels.load(from: archive)
    assert(legacyLabels["pro"] == "ChatGPT Pro 200")
    try Data([0,1,2]).write(to: archive)
    let truncatedLabels = try UsagePlanLabels.load(from: archive)
    assert(truncatedLabels.isEmpty)
    print("Plan label tests passed: old/new syntax, numbered tiers, nested numeric bundles, unknown and truncated sources")
}
