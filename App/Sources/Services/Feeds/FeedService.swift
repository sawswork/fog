import Foundation
import Core
import os

/// 登録 RSS の取得と保存（F-27）。原則 3 で許された外部通信のひとつ。
/// URL は設定（UserDefaults）、記事は App Group の JSON。取得はフィードごとに 1 時間に 1 回まで。
@MainActor
@Observable
final class FeedService {
    static let urlsKey = "fog.feeds.urls"
    static let filtersKey = "fog.feeds.filters"
    static let maxItemsPerFeed = 50
    private(set) var items: [FeedItem] = []
    private(set) var feedTitles: [String: String] = [:]
    /// RSS が無いサイトで、ページから見つけた RSS の URL（自動探索の結果）
    private(set) var resolvedFeeds: [String: String] = [:]
    /// 読み方：rss / html（リンク一覧）
    private(set) var kinds: [String: String] = [:]
    private(set) var lastError: String?
    /// 記事が入れ替わるたびに進む（画面側の再計算の合図）
    private(set) var revision = 0
    /// 保存形式の版。記事の項目が増えたときに上げると、次の再計算で 1 時間の制限を無視して取り直す
    static let schemaVersion = 2
    private var gate = FetchGate(minimumInterval: 3600)
    private var refreshing = false
    private static let log = Logger(subsystem: "fog", category: "feeds")

    private var storeURL: URL { FogShared.containerURL.appendingPathComponent("feeds.json") }

    init() { load() }

    var urls: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.urlsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.urlsKey) }
    }

    func add(url: String) {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty, URL(string: u)?.scheme?.hasPrefix("http") == true, !urls.contains(u) else { return }
        urls.append(u)
        gate.release(u)
        Task { await refreshIfNeeded(force: true) }
    }

    /// リポジトリの所有者が knowlsaws → sawswork に変わった（2026-11-09）。登録済みの fog-feeds の URL を新しい所有者に書き換える
    func migrateRepositoryOwnerIfNeeded() {
        let old = "/knowlsaws/fog-feeds/", new = "/sawswork/fog-feeds/"
        let oldPages = "knowlsaws.github.io/fog-feeds", newPages = "sawswork.github.io/fog-feeds"
        let current = urls
        let migrated = current.map { $0.replacingOccurrences(of: old, with: new).replacingOccurrences(of: oldPages, with: newPages) }
        guard migrated != current else { return }
        var seen = Set<String>()
        urls = migrated.filter { seen.insert($0).inserted }
        var f = filters
        for (o, n) in zip(current, migrated) where o != n { if let v = f[o] { f[n] = v; f[o] = nil } }
        filters = f
        for (o, n) in zip(current, migrated) where o != n {
            feedTitles[n] = feedTitles[o]; feedTitles[o] = nil
            kinds[n] = kinds[o]; kinds[o] = nil
            resolvedFeeds[n] = resolvedFeeds[o].map { $0.replacingOccurrences(of: old, with: new) }; resolvedFeeds[o] = nil
            items = items.map { i in var i = i; if i.feedURL == o { i.feedURL = n }; return i }
            gate.release(n)
        }
        save()
        Task { await refreshIfNeeded(force: true) }
    }

    func remove(url: String) {
        urls.removeAll { $0 == url }
        items.removeAll { $0.feedURL == url }
        feedTitles[url] = nil; resolvedFeeds[url] = nil; kinds[url] = nil
        var f = filters; f[url] = nil; filters = f
        save()
    }

    /// RSS の無いサイトの「記事リンクの条件」（URL にこの文字を含むリンクだけ記事にする）
    var filters: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Self.filtersKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.filtersKey) }
    }

    func setFilter(url: String, filter: String) {
        var f = filters
        let t = filter.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { f[url] = nil } else { f[url] = t }
        filters = f
        gate.release(url)
        Task { await refreshIfNeeded(force: true) }
    }

    /// 必要なら取得。圏外や失敗でも投げない（残っている記事で動く）
    func refreshIfNeeded(now: Date = .now, force: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        var changed = false
        for url in urls {
            guard force || gate.tryAcquire(url, now: now), let u = URL(string: url) else { continue }
            do {
                // 自動探索で RSS が見つかっているサイトは、その RSS を読む
                let target = resolvedFeeds[url].flatMap(URL.init(string:)) ?? u
                let data = try await Self.download(target)
                var result: (title: String, items: [FeedItem])?
                if let parsed = FeedParser.parse(data, feedURL: url, fetchedAt: now) {
                    result = (parsed.title, parsed.items); kinds[url] = "rss"
                } else if let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .shiftJIS) ?? String(data: data, encoding: .japaneseEUC) {
                    // RSS の無いサイト：まずページが指す RSS を探し（1 回だけ余分に読む）、無ければリンク一覧を記事にする（F-45）
                    if resolvedFeeds[url] == nil, let discovered = HTMLFeed.discoverFeedURLs(html: html, baseURL: u).first,
                       let d = try? await Self.download(discovered), let parsed = FeedParser.parse(d, feedURL: url, fetchedAt: now) {
                        resolvedFeeds[url] = discovered.absoluteString
                        result = (parsed.title, parsed.items); kinds[url] = "rss"
                    } else {
                        let list = HTMLFeed.items(html: html, baseURL: u, feedURL: url, feedTitle: nil, pathFilter: filters[url], fetchedAt: now)
                        if list.isEmpty { lastError = "記事リンクが見つからない: \(url)"; continue }
                        result = (list[0].feedTitle, list); kinds[url] = "html"
                    }
                }
                guard let result else { lastError = "読めない形式: \(url)"; continue }
                feedTitles[url] = result.title
                var merged = items.filter { $0.feedURL != url }
                let known = Dictionary(uniqueKeysWithValues: items.filter { $0.feedURL == url }.map { ($0.id, $0) })
                // 前から知っている記事は最初に見た時刻を保つ（リンク一覧は日付が無いことがあり、新着を上に出すため）
                let fresh = result.items.map { i -> FeedItem in var i = i; if let k = known[i.id] { i.fetchedAt = k.fetchedAt }; return i }
                merged += Array(fresh.prefix(Self.maxItemsPerFeed))
                items = merged
                lastError = nil
                changed = true
                revision += 1
            } catch {
                gate.release(url)
                lastError = error.localizedDescription
                Self.log.notice("feed fetch failed \(url, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if changed { save() }
    }

    /// 関連が強い順（魚種名・釣り場名）→ 新しい順
    func sorted(keywords: [String]) -> [FeedItem] { FeedRelevance.sorted(items, keywords: keywords) }

    /// ホームの 1 行：関連が強い記事か、無ければ最新
    func headline(keywords: [String]) -> FeedItem? { sorted(keywords: keywords).first }

    nonisolated private static func download(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("Fog/1.0 (iOS; personal fishing log)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }

    private struct Persisted: Codable { var items: [FeedItem]; var titles: [String: String]; var gate: FetchGate; var resolved: [String: String]?; var kinds: [String: String]?; var schema: Int? }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL), let p = try? FogJSON.decode(Persisted.self, from: data) else { return }
        items = p.items; feedTitles = p.titles; resolvedFeeds = p.resolved ?? [:]; kinds = p.kinds ?? [:]
        // 古い形式で保存した記事は座標などが無いので、制限を外して次の再計算で取り直す
        gate = (p.schema ?? 1) >= Self.schemaVersion ? p.gate : FetchGate(minimumInterval: 3600)
        revision += 1
    }

    private func save() {
        guard let data = try? FogJSON.encode(Persisted(items: items, titles: feedTitles, gate: gate, resolved: resolvedFeeds, kinds: kinds, schema: Self.schemaVersion)) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
