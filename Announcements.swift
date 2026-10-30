import Foundation
import CryptoKit

struct AnnouncementSource: Codable, Equatable {
    let name: String
    let url: String
    var enabled: Bool
    static let mirrorURL = "https://x.noodl3.net/thsottiaux/rss"
    static let mirror = AnnouncementSource(name: "Tibo on X (public mirror)", url: mirrorURL, enabled: true)
    static let defaults = [
        AnnouncementSource(name: "OpenAI News", url: "https://openai.com/news/rss.xml", enabled: true),
        AnnouncementSource(name: "ChatGPT & Codex Changelog", url: "https://learn.chatgpt.com/codex/changelog/rss.xml", enabled: true),
        mirror
    ]
    static func trustedPost(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host?.lowercased() == "x.com", url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil else { return false }
        let parts = url.path.split(separator: "/")
        return parts.count == 3 && parts[0].lowercased() == "thsottiaux" && parts[1] == "status" && !parts[2].isEmpty && parts[2].allSatisfy { $0.isNumber && $0.isASCII }
    }
    static func allowedLink(_ url: URL) -> Bool { allowed(url) || trustedPost(url) }
    static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil else { return false }
        if url.absoluteString == mirrorURL { return true }
        return ["openai.com", "www.openai.com", "help.openai.com", "learn.chatgpt.com", "developers.openai.com"].contains(url.host?.lowercased() ?? "")
    }
}
struct AnnouncementRecord: Codable {
    let source: String
    var checkedAt: Date?
    var events: [ExtraResetEvent] = []
    var reviewURLs: [String] = []
    var error: String?
}
struct AnnouncementCache: Codable {
    var records: [AnnouncementRecord] = []
    var plan: String?
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CodexUsage", isDirectory: true)
    }
    static var url: URL { directory.appendingPathComponent("announcements.json") }
    static func load() -> AnnouncementCache {
        guard let data = try? Data(contentsOf: url), data.count < 512_000,
              let cache = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return cache
    }
    func save() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: Self.url, options: .atomic) }
    }
    func feed(sources: [AnnouncementSource], plan: String?) -> ExtraResetFeed {
        let active = Set(sources.filter { $0.enabled }.map { $0.url })
        let events = self.plan == plan ? records.filter { active.contains($0.source) }.flatMap { $0.events } : []
        return ExtraResetFeed(schemaVersion: 1, updatedAt: ISO8601DateFormatter().string(from: Date()), events: events)
    }
}

struct AnnouncementItem {
    var title = ""
    var link = ""
    var description = ""
    var content = ""
    var published = ""
}
final class AnnouncementRSS: NSObject, XMLParserDelegate {
    var items: [AnnouncementItem] = []
    var item: AnnouncementItem?
    var field = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if elementName == "item" { item = AnnouncementItem() }
        field = elementName
    }
    func append(_ text: String) {
        guard item != nil else { return }
        switch field {
        case "title": item?.title += text
        case "link": item?.link += text
        case "description": item?.description += text
        case "content:encoded": item?.content += text
        case "pubDate": item?.published += text
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { append(string) }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { append(String(decoding: CDATABlock, as: UTF8.self)) }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "item", let item { items.append(item); self.item = nil }
        field = ""
    }
}

enum AnnouncementParser {
    static func matches(_ pattern: String, _ value: String) -> Bool { value.range(of: pattern, options: .regularExpression) != nil }
    static func plain(_ html: String) -> String {
        var text = html
        for tag in ["script", "style", "nav", "header", "footer", "pre", "code"] {
            text = text.replacingOccurrences(of: "(?is)<\(tag)\\b[^>]*>.*?</\(tag)>", with: "\n", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "(?i)</(?:p|li|div|h[1-6]|section)>|<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (a,b) in [("&nbsp;", " "), ("&#160;", " "), ("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&#8217;", "'"), ("’", "'")] { text = text.replacingOccurrences(of: a, with: b) }
        return text.replacingOccurrences(of: "[\\t \\r]+", with: " ", options: .regularExpression)
    }
    // Accept a single fully specified timestamp; never infer a year, timezone, or relative day.
    static func explicitDate(_ text: String) -> Date? {
        let isoPattern = #"\b\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?(?:Z|[+-]\d{2}:\d{2})\b"#
        let englishPattern = #"(?i)\b(January|February|March|April|May|June|July|August|September|October|November|December)\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(AM|PM)?\s+(UTC|GMT|PST|PDT|PT)\b"#
        let ns = text as NSString
        let iso = try! NSRegularExpression(pattern: isoPattern)
        let english = try! NSRegularExpression(pattern: englishPattern)
        let a = iso.matches(in: text, range: NSRange(location: 0, length: ns.length))
        let b = english.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard a.count + b.count == 1 else { return nil }
        if let match = a.first {
            var value = ns.substring(with: match.range)
            if value.count == 17 || value.count == 22 { value.insert(contentsOf: ":00", at: value.index(value.startIndex, offsetBy: 16)) }
            return ExtraResetEvent.date(value)
        }
        let m = b[0]
        func group(_ i: Int) -> String { m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i)) }
        let zone = group(7).uppercased(), meridiem = group(6).uppercased()
        let hour = Int(group(4)) ?? -1, minute = Int(group(5)) ?? 0
        guard (meridiem.isEmpty ? (0...23).contains(hour) : (1...12).contains(hour)), (0...59).contains(minute) else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.isLenient = false
        f.timeZone = ["PT", "PST", "PDT"].contains(zone) ? TimeZone(identifier: "America/Los_Angeles")! : TimeZone(secondsFromGMT: 0)!
        f.dateFormat = "MMMM d yyyy " + (meridiem.isEmpty ? "H:mm" : "h:mm a")
        let input = "\(group(1)) \(group(2)) \(group(3)) \(hour):\(String(format: "%02d", minute))" + (meridiem.isEmpty ? "" : " \(meridiem)")
        guard let date = f.date(from: input) else { return nil }
        if zone == "PST" && f.timeZone.secondsFromGMT(for: date) != -28800 { return nil }
        if zone == "PDT" && f.timeZone.secondsFromGMT(for: date) != -25200 { return nil }
        return date
    }
    static func extract(_ html: String, url: String, plan: String?, now: Date) -> ([ExtraResetEvent], Bool) {
        guard let source = URL(string: url), AnnouncementSource.allowedLink(source) else { return ([], false) }
        let text = plain(html)
        if matches(#"(?is)(?:reset.{0,160}(?:cancelled|canceled|postponed|delayed)|(?:cancelled|canceled|postponed|delayed).{0,160}reset)"#, text) { return ([], true) }
        let paragraphs = text.components(separatedBy: .newlines).filter { $0.count < 1800 }
        var events: [ExtraResetEvent] = [], review = false
        for paragraph in paragraphs {
            let lower = paragraph.lowercased()
            guard lower.contains("codex"), matches(#"\breset(?:ting|s)?\b"#, lower), matches(#"\b(usage|allowance|limits|global|automatic)\b"#, lower) else { continue }
            // This is deliberately a small grammar, not general language understanding.
            guard matches(#"\b(will (?:automatically )?reset|we are resetting|we're resetting|(?:global|automatic) reset (?:will|is scheduled))\b"#, lower) else { continue }
            guard matches(#"\b(global|extra|one-time|we will|we are resetting|we're resetting)\b"#, lower) else { continue }
            if matches(#"\b(banked|redeem|claim|purchase|paid|example|hypothetical|cancelled|canceled|postponed|delayed|not|never|may|might|could|if|unless|selected|eligible|some|except|only|who|normal|regular|every)\b"#, lower) { continue }
            review = true
            let plans = ["free", "go", "plus", "pro", "business", "enterprise", "edu"]
            let named = plans.filter { matches("\\b\($0)\\b", lower) }
            let universal = matches(#"\ball (?:codex |chatgpt )?(?:users|accounts)\b"#, lower)
            let applicable = universal || (lower.contains("all ") && plan.map { named.contains($0.lowercased()) } == true)
            guard applicable, let date = explicitDate(paragraph), date > now, date.timeIntervalSince(now) <= 31 * 86400 else { continue }
            let iso = ISO8601DateFormatter()
            let digest = SHA256.hash(data: Data((url + iso.string(from: date)).utf8)).map { String(format: "%02x", $0) }.joined()
            let basis = matches(#"\bby\b"#, lower) ? "by" : "exact"
            events.append(ExtraResetEvent(id: digest, kind: "global_reset", status: "scheduled", resetAt: iso.string(from: date), timeBasis: basis, sourceURL: url, verifiedAt: iso.string(from: now)))
        }
        return (events, review && events.isEmpty)
    }
    static func mirrorPostURL(_ link: String) -> URL? {
        guard let url = URL(string: link), url.scheme == "https", url.host?.lowercased() == "x.noodl3.net", url.user == nil, url.password == nil, url.port == nil else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 3, parts[0].lowercased() == "thsottiaux", parts[1] == "status", !parts[2].isEmpty, parts[2].allSatisfy({ $0.isNumber && $0.isASCII }) else { return nil }
        return URL(string: "https://x.com/thsottiaux/status/\(parts[2])")
    }
    static func parseMirror(_ data: Data, source: AnnouncementSource, plan: String?, now: Date, verify: (URL) throws -> String) throws -> AnnouncementRecord {
        let xml = XMLParser(data: data), rss = AnnouncementRSS()
        xml.shouldResolveExternalEntities = false; xml.delegate = rss
        guard xml.parse(), !rss.items.isEmpty else { throw AnnouncementError.invalidContent }
        let dates = DateFormatter(); dates.locale = Locale(identifier: "en_US_POSIX"); dates.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        var record = AnnouncementRecord(source: source.url, checkedAt: now)
        var seen = Set<String>()
        for item in rss.items {
            guard let published = dates.date(from: item.published.trimmingCharacters(in: .whitespacesAndNewlines)), published <= now.addingTimeInterval(300), now.timeIntervalSince(published) <= 31 * 86400,
                  let url = mirrorPostURL(item.link.trimmingCharacters(in: .whitespacesAndNewlines)), seen.insert(url.absoluteString).inserted else { continue }
            let candidate = item.title + " " + item.description + " " + item.content
            guard matches("(?i)\\breset", candidate) else { continue }
            do {
                let original = try verify(url)
                let (events, review) = extract(original, url: url.absoluteString, plan: plan, now: now)
                record.events += events
                if review { record.reviewURLs.append(url.absoluteString) }
            } catch {
                record.reviewURLs.append(url.absoluteString)
                record.error = "Some X posts couldn’t be verified"
            }
        }
        record.events = Array(record.events.prefix(20)); record.reviewURLs = Array(record.reviewURLs.prefix(5))
        return record
    }
    static func parse(_ data: Data, source: AnnouncementSource, plan: String?, now: Date) throws -> AnnouncementRecord {
        var record = AnnouncementRecord(source: source.url, checkedAt: now)
        let raw = String(decoding: data, as: UTF8.self)
        var entries: [AnnouncementItem]
        if matches("(?i)<rss\\b", raw) {
            let delegate = AnnouncementRSS(), xml = XMLParser(data: data)
            xml.shouldResolveExternalEntities = false; xml.delegate = delegate
            guard xml.parse(), !delegate.items.isEmpty else { throw AnnouncementError.invalidContent }
            let dateFormat = DateFormatter(); dateFormat.locale = Locale(identifier: "en_US_POSIX"); dateFormat.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
            entries = delegate.items.filter {
                guard let published = dateFormat.date(from: $0.published.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
                return published <= now.addingTimeInterval(300) && now.timeIntervalSince(published) <= 31 * 86400
            }
        } else {
            guard matches("(?is)<(?:html|article)\\b", raw), !matches("(?i)(cf-chl-|just a moment|captcha)", raw) else { throw AnnouncementError.invalidContent }
            entries = [AnnouncementItem(link: source.url, content: raw)]
        }
        for entry in entries {
            let body = entry.content.isEmpty ? entry.description : entry.content
            let link = entry.link.trimmingCharacters(in: .whitespacesAndNewlines)
            let (events, review) = extract(body, url: link, plan: plan, now: now)
            record.events += events
            if review && !record.reviewURLs.contains(link) { record.reviewURLs.append(link) }
        }
        var seen = Set<String>()
        record.events = Array(record.events.filter { seen.insert($0.id).inserted }.prefix(20))
        record.reviewURLs = Array(record.reviewURLs.prefix(5))
        return record
    }
}

enum AnnouncementError: Error { case invalidContent, network, http(Int), tooLarge }
final class AnnouncementHTTP: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map { self.allowedRequest($0) } == true ? request : nil)
    }
    func allowedRequest(_ url: URL) -> Bool {
        if AnnouncementSource.allowed(url) { return true }
        return url.scheme == "https" && url.user == nil && url.password == nil && url.port == nil && ["publish.twitter.com", "publish.x.com"].contains(url.host?.lowercased() ?? "") && url.path == "/oembed"
    }
    func fetch(_ url: URL) throws -> Data {
        guard allowedRequest(url) else { throw AnnouncementError.invalidContent }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 25
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil
        // System URLCache honors ETag/Last-Modified while keeping cached responses private to this app.
        config.urlCache = URLCache(memoryCapacity: 12_000_000, diskCapacity: 24_000_000, diskPath: "CodexUsageAnnouncements")
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData)
        request.setValue("Mozilla/5.0 (compatible; CodexGauge/2.2)", forHTTPHeaderField: "User-Agent")
        let signal = DispatchSemaphore(value: 0), lock = NSLock()
        var result: Result<Data, Error> = .failure(AnnouncementError.network)
        let task = session.dataTask(with: request) { data, response, error in
            let value: Result<Data, Error>
            if let error { value = .failure(error) }
            else if let response = response as? HTTPURLResponse, response.statusCode != 200 { value = .failure(AnnouncementError.http(response.statusCode)) }
            else if let data, data.count <= 8_000_000 { value = .success(data) }
            else { value = .failure(AnnouncementError.tooLarge) }
            lock.lock(); result = value; lock.unlock(); signal.signal()
        }
        task.resume()
        guard signal.wait(timeout: .now() + 27) == .success else { task.cancel(); throw AnnouncementError.network }
        lock.lock(); defer { lock.unlock() }
        return try result.get()
    }
}
func checkAnnouncements(sources: [AnnouncementSource], previous: AnnouncementCache, plan: String?) -> AnnouncementCache {
    let http = AnnouncementHTTP()
    var result = AnnouncementCache(plan: plan)
    for source in sources where source.enabled {
        var record = previous.plan == plan ? previous.records.first { $0.source == source.url } ?? AnnouncementRecord(source: source.url) : AnnouncementRecord(source: source.url)
        do {
            let data = try http.fetch(URL(string: source.url)!)
            if source.url == AnnouncementSource.mirrorURL {
                record = try AnnouncementParser.parseMirror(data, source: source, plan: plan, now: Date()) { post in
                    var components = URLComponents(string: "https://publish.x.com/oembed")!
                    components.queryItems = [URLQueryItem(name: "url", value: post.absoluteString), URLQueryItem(name: "omit_script", value: "true")]
                    let verified = try http.fetch(components.url!)
                    guard let object = try JSONSerialization.jsonObject(with: verified) as? [String: Any],
                          let author = object["author_url"] as? String, author.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "https://x.com/thsottiaux",
                          let originalURL = object["url"] as? String, originalURL == post.absoluteString,
                          let html = object["html"] as? String, !html.contains("…"), !html.contains("&hellip;") else { throw AnnouncementError.invalidContent }
                    return html
                }
            } else { record = try AnnouncementParser.parse(data, source: source, plan: plan, now: Date()) }
        } catch {
            if case AnnouncementError.http(let code) = error { record.error = "Unavailable (HTTP \(code))" }
            else if case AnnouncementError.invalidContent = error { record.error = "Page format unavailable" }
            else { record.error = "Couldn’t check — will retry" }
        }
        result.records.append(record)
    }
    return result
}
