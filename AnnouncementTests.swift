func testAnnouncements() throws {
    let now = ExtraResetEvent.date("2026-10-29T19:00:00Z")!
    let url = "https://openai.com/index/test-announcement"
    let good = "We will reset Codex usage for all Pro users on October 31, 2026 at 5 PM PDT."
    func events(_ text: String, plan: String? = "pro") -> [ExtraResetEvent] {
        AnnouncementParser.extract(text, url: url, plan: plan, now: now).0
    }
    precondition(events(good).first?.resetAt == "2026-11-01T00:00:00Z")
    precondition(events(good.replacingOccurrences(of: "on October", with: "by October")).first?.timeBasis == "by")
    precondition(events(good, plan: "plus").isEmpty)
    precondition(events(good, plan: nil).isEmpty)
    precondition(events(good.replacingOccurrences(of: "all Pro users", with: "all users")).count == 1)
    precondition(events(good.replacingOccurrences(of: "all Pro users", with: "eligible Pro users")).isEmpty)
    precondition(events(good.replacingOccurrences(of: "all Pro users", with: "all Pro users who joined today")).isEmpty)
    precondition(events(good.replacingOccurrences(of: ", 2026", with: "")).isEmpty)
    precondition(events(good.replacingOccurrences(of: "PDT", with: "")).isEmpty)
    precondition(events(good.replacingOccurrences(of: "PDT", with: "PST")).isEmpty)
    precondition(events(good.replacingOccurrences(of: "October 31, 2026 at 5 PM PDT", with: "tomorrow")).isEmpty)
    precondition(events(good.replacingOccurrences(of: "October 31", with: "October 27")).isEmpty)
    precondition(events("Example: " + good).isEmpty)
    precondition(events("Update: the reset was cancelled.\n" + good).isEmpty)
    precondition(events(good.replacingOccurrences(of: "will reset", with: "will not reset")).isEmpty)
    precondition(events(good + " Claim your banked reset.").isEmpty)
    precondition(events(good + " Then again November 2, 2026 at 5 PM PST.").isEmpty)
    precondition(events("<script>" + good + "</script><p>No announcement.</p>").isEmpty)
    precondition(events("<pre>" + good + "</pre>").isEmpty)
    precondition(AnnouncementParser.extract(good, url: "https://openai.com.example.org/news", plan: "pro", now: now).0.isEmpty)
    precondition(AnnouncementParser.explicitDate("2026-10-31T17:00:00-07:00") == ExtraResetEvent.date("2026-11-01T00:00:00Z"))
    precondition(AnnouncementParser.explicitDate("2026-10-31T17:00-07:00") == ExtraResetEvent.date("2026-11-01T00:00:00Z"))
    precondition(AnnouncementParser.explicitDate("February 30, 2026 at 5 PM UTC") == nil)
    let source = AnnouncementSource(name: "Test", url: url, enabled: true)
    let xml = "<rss><channel><item><title>Reset</title><link>\(url)</link><pubDate>Thu, 29 Oct 2026 00:00:00 GMT</pubDate><description><![CDATA[<p>\(good)</p>]]></description></item></channel></rss>"
    let record = try AnnouncementParser.parse(Data(xml.utf8), source: source, plan: "pro", now: now)
    precondition(record.events.count == 1)
    let old = xml.replacingOccurrences(of: "29 Oct", with: "01 Sep")
    let oldRecord = try AnnouncementParser.parse(Data(old.utf8), source: source, plan: "pro", now: now)
    precondition(oldRecord.events.isEmpty)
    let cache = AnnouncementCache(records: [record], plan: "pro")
    precondition(cache.feed(sources: [], plan: "pro").events.isEmpty)
    precondition(cache.feed(sources: [source], plan: "plus").events.isEmpty)
    let fallback = NextReset.choose(normal: now.addingTimeInterval(3600), extra: record.events[0], now: now)
    precondition(fallback.extra == nil)
    let mirrorLink = "https://x.noodl3.net/thsottiaux/status/12345#m"
    let mirrorXML = "<rss><channel><item><title>Reset</title><link>\(mirrorLink)</link><pubDate>Thu, 29 Oct 2026 00:00:00 GMT</pubDate><description>reset</description></item></channel></rss>"
    let mirrorData = Data(mirrorXML.utf8)
    let mirrored = try AnnouncementParser.parseMirror(mirrorData, source: AnnouncementSource.mirror, plan: "pro", now: now) { url in
        precondition(url.absoluteString == "https://x.com/thsottiaux/status/12345"); return good
    }
    precondition(mirrored.events.count == 1 && mirrored.events[0].sourceURL == "https://x.com/thsottiaux/status/12345")
    let fake = try AnnouncementParser.parseMirror(mirrorData, source: AnnouncementSource.mirror, plan: "pro", now: now) { _ in "No upcoming reset" }
    precondition(fake.events.isEmpty)
    let unavailable = try AnnouncementParser.parseMirror(mirrorData, source: AnnouncementSource.mirror, plan: "pro", now: now) { _ in throw AnnouncementError.network }
    precondition(unavailable.events.isEmpty && unavailable.reviewURLs.count == 1 && unavailable.error != nil)
    precondition(AnnouncementParser.mirrorPostURL("https://x.noodl3.net/imposter/status/12345") == nil)
    precondition(AnnouncementParser.mirrorPostURL("https://x.noodl3.net.evil.test/thsottiaux/status/12345") == nil)
    precondition(!AnnouncementSource.trustedPost(URL(string: "https://x.com/thsottiaux/status/12345?redirect=evil")!))
    print("Passed: announcement dates, timezone/DST, scope, cancellation, banked/ambiguous exclusions, RSS, disabled sources, and plan changes.")
}
