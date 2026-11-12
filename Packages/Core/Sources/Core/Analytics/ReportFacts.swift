import Foundation

/// 釣行後レポートの材料（F-21）。文章は App 側の Foundation Models が作り、失敗時は `ReportTemplate` の定型文を使う。
public struct ReportFacts: Hashable, Sendable {
    public var spotName: String
    public var startedAt: Date
    public var endedAt: Date
    public var hours: Double
    public var catches: Int
    public var species: [(name: String, count: Int, maxCm: Double?)]
    /// 釣れた時間帯（時刻順）
    public var catchTimes: [Date]
    /// 釣れた時刻の潮（上げ/下げ/潮止まり → 尾数）
    public var catchesByTide: [String: Int]
    /// 釣れた時刻の光量（朝マズメ/昼/… → 尾数）
    public var catchesByLight: [String: Int]
    public var tideName: String?
    public var windRangeMS: (min: Double, max: Double)?
    public var seaTempC: Double?
    public var pressureTrend: Double?
    public var comparison: Analytics.Comparison?
    public var records: [String]   // 「初 アイナメ」「アイナメ 自己記録 42cm」
    public var hookLosses: Int
    /// 釣った人ごとの尾数（自分だけの釣行なら空）。自分の端末で撮った、ほかの人の魚を含む（F-54）
    public var byAngler: [(name: String, count: Int)] = []

    public static func == (l: ReportFacts, r: ReportFacts) -> Bool { l.spotName == r.spotName && l.startedAt == r.startedAt && l.catches == r.catches }
    public func hash(into h: inout Hasher) { h.combine(startedAt); h.combine(spotName) }

    /// `ownName` は自分の名前。初物・自己記録は自分の魚だけで数える（ほかの人の魚は記録に入れない。F-54）
    public static func make(session: Session, spotName: String, previous: Session?, allCatchesBefore: [(Catch, UUID)], ownName: String? = nil,
                            timeZone: TimeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current) -> ReportFacts {
        let end = session.endedAt ?? Date()
        let catches = session.catches.sorted { $0.at < $1.at }
        var bySpecies: [String: (Int, Double?)] = [:]
        for c in catches {
            var v = bySpecies[c.species] ?? (0, nil)
            v.0 += 1
            if let l = c.lengthCm { v.1 = max(v.1 ?? 0, l) }
            bySpecies[c.species] = v
        }
        let species = bySpecies.sorted { $0.value.0 > $1.value.0 }.map { (name: $0.key, count: $0.value.0, maxCm: $0.value.1) }
        let dist = Analytics.conditionDistribution(of: catches, timeZone: timeZone)
        let winds = session.snapshots.compactMap(\.windSpeedMS)
        var records: [String] = []
        var seen = allCatchesBefore.filter { $0.0.isOwn(ownName: ownName) }
        for c in catches where c.isOwn(ownName: ownName) {
            let j = Analytics.judge(new: c, newSpotID: session.spotID, existing: seen)
            if j.isFirstSpecies { records.append("初 \(c.species)") }
            else if j.isPersonalBest, let l = c.lengthCm { records.append("\(c.species) 自己記録 \(Int(l.rounded()))cm") }
            else if j.isSpotRecord, let l = c.lengthCm { records.append("\(c.species) \(spotName)記録 \(Int(l.rounded()))cm") }
            seen.append((c, session.spotID))
        }
        // 釣った人ごと（ほかの人の魚があるときだけ）
        var byAngler: [(name: String, count: Int)] = []
        if catches.contains(where: { !$0.isOwn(ownName: ownName) }) {
            var counts: [String: Int] = [:], order: [String] = []
            for c in catches {
                let name = c.isOwn(ownName: ownName) ? (ownName.flatMap { $0.isEmpty ? nil : $0 } ?? "自分") : (c.angler ?? "ほかの人")
                if counts[name] == nil { order.append(name) }
                counts[name, default: 0] += 1
            }
            // 尾数の多い順。同じなら先に釣った人から
            byAngler = order.enumerated().sorted { a, b in
                let ca = counts[a.element] ?? 0, cb = counts[b.element] ?? 0
                return ca != cb ? ca > cb : a.offset < b.offset
            }.map { (name: $0.element, count: counts[$0.element] ?? 0) }
        }
        var facts = ReportFacts(
            spotName: spotName,
            startedAt: session.startedAt,
            endedAt: end,
            hours: end.timeIntervalSince(session.startedAt) / 3600,
            catches: catches.count,
            species: species,
            catchTimes: catches.map(\.at),
            catchesByTide: dist.byTide,
            catchesByLight: dist.byLight,
            tideName: session.snapshots.first?.tideName,
            windRangeMS: winds.isEmpty ? nil : (winds.min()!, winds.max()!),
            seaTempC: session.snapshots.compactMap(\.seaSurfaceTempC).last,
            pressureTrend: session.snapshots.compactMap(\.pressureTrend3hHPa).last,
            comparison: Analytics.comparison(current: session, previous: previous),
            records: records,
            hookLosses: session.hookEvents.filter { $0.kind == .lost }.count
        )
        facts.byAngler = byAngler
        return facts
    }
}

/// 定型文のレポート（Foundation Models が使えないときのフォールバック）。
public enum ReportTemplate {
    public static func summary(_ f: ReportFacts) -> String {
        if f.catches == 0 { return "ボウズ（\(hoursText(f.hours))）" }
        if let tide = topKey(f.catchesByTide), let light = topKey(f.catchesByLight), f.catches >= 2 {
            return "\(light)の\(tide)に\(f.catches)尾"
        }
        let main = f.species.first.map { "\($0.name)\($0.maxCm.map { " \(Int($0.rounded()))cm" } ?? "")" } ?? ""
        return "\(f.catches)尾 \(main)".trimmingCharacters(in: .whitespaces)
    }

    public static func body(_ f: ReportFacts, timeZone: TimeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current) -> String {
        var lines: [String] = []
        let fmt = DateFormatter()
        fmt.timeZone = timeZone
        fmt.dateFormat = "H:mm"
        lines.append("\(f.spotName) \(fmt.string(from: f.startedAt))〜\(fmt.string(from: f.endedAt))（\(hoursText(f.hours))）")
        if f.catches == 0 {
            lines.append("釣果なし。")
        } else {
            let sp = f.species.map { "\($0.name) \($0.count)尾\($0.maxCm.map { "（最大 \(Int($0.rounded()))cm）" } ?? "")" }.joined(separator: "、")
            lines.append("釣果 \(f.catches)尾：\(sp)。")
            if !f.byAngler.isEmpty { lines.append("釣った人：" + f.byAngler.map { "\($0.name) \($0.count)尾" }.joined(separator: "、") + "。") }
            let times = f.catchTimes.map { fmt.string(from: $0) }.joined(separator: " ")
            lines.append("釣れた時刻 \(times)。")
            if let tide = topKey(f.catchesByTide), let light = topKey(f.catchesByLight) {
                lines.append("\(light)・\(tide)の時間帯に集中した。")
            }
        }
        var cond: [String] = []
        if let t = f.tideName { cond.append(t) }
        if let w = f.windRangeMS { cond.append(String(format: "風 %.0f〜%.0f m/s", w.min, w.max)) }
        if let s = f.seaTempC { cond.append(String(format: "水温 %.1f℃", s)) }
        if let p = f.pressureTrend { cond.append(String(format: "気圧 %+.1f hPa/3h", p)) }
        if !cond.isEmpty { lines.append("条件：" + cond.joined(separator: "、") + "。") }
        if let c = f.comparison {
            var diff: [String] = []
            diff.append(c.catchesDelta == 0 ? "尾数は前回と同じ" : (c.catchesDelta > 0 ? "前回より \(c.catchesDelta)尾多い" : "前回より \(-c.catchesDelta)尾少ない"))
            if let w = c.windDeltaMS, abs(w) >= 1 { diff.append(String(format: "風は %@%.0f m/s", w > 0 ? "+" : "", w)) }
            if let s = c.seaTempDeltaC, abs(s) >= 0.5 { diff.append(String(format: "水温は %@%.1f℃", s > 0 ? "+" : "", s)) }
            lines.append("前回比：" + diff.joined(separator: "、") + "。")
        }
        if !f.records.isEmpty { lines.append("記録：" + f.records.joined(separator: "、") + "。") }
        if f.hookLosses > 0 { lines.append("針ロスト \(f.hookLosses)回。") }
        lines.append(nextHint(f))
        return lines.joined(separator: "\n")
    }

    static func nextHint(_ f: ReportFacts) -> String {
        if f.catches == 0 {
            if let w = f.windRangeMS, w.max > 8 { return "次回：風が 5 m/s 以下の日を狙う。" }
            if f.tideName == "長潮" || f.tideName == "若潮" { return "次回：大潮〜中潮の潮が動く時間帯に。" }
            return "次回：マズメの時間帯に合わせて入る。"
        }
        if let light = topKey(f.catchesByLight), let tide = topKey(f.catchesByTide) {
            return "次回：\(light)の\(tide)を狙う。"
        }
        return "次回：同じ時間帯を試す。"
    }

    static func hoursText(_ h: Double) -> String {
        let minutes = Int((h * 60).rounded())
        return minutes >= 60 ? "\(minutes / 60)時間\(minutes % 60 == 0 ? "" : "\(minutes % 60)分")" : "\(minutes)分"
    }

    static func topKey(_ dict: [String: Int]) -> String? {
        dict.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
    }
}
