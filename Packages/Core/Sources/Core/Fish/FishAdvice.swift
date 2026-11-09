import Foundation

/// 種のデータから「釣るためのアドバイス」と「釣れる場所」を組み立てる（F-60）。
/// 出典の数値と文章だけから決まる規則で、通信も学習済みモデルも使わない（端末で即時・全種に出せる）
public enum FishAdvice {
    public struct Output: Hashable, Sendable {
        /// 2〜5 文のアドバイス
        public var advice: [String]
        /// 釣れる場所（短い語の列：堤防・岩礁帯・水深 4〜155 m …）
        public var places: [String]
        /// 分布の 1 文（Wikipedia の分布節の先頭）
        public var distribution: String?
    }

    static let monthNames = ["", "1月", "2月", "3月", "4月", "5月", "6月", "7月", "8月", "9月", "10月", "11月", "12月"]

    /// `now` の月を基準に、今が釣り時かどうかも書く
    public static func make(_ e: FishEntry, month: Int? = nil, ownCount: Int = 0, ownMaxCm: Double? = nil) -> Output {
        var advice: [String] = []
        let eco = (e.ecology ?? "") + " " + (e.summary ?? "") + " " + (e.usage ?? "") + " " + (e.biology ?? "")
        let groups = Set(e.groups)

        // 時期
        let season = e.seasonMonths ?? [], spawn = e.spawningMonths ?? []
        if !season.isEmpty {
            advice.append("時期は\(monthList(season))が狙い目" + (month.map { season.contains($0) ? "。今月はまさに旬" : "" } ?? "") + "。")
        } else if !spawn.isEmpty {
            advice.append("産卵期（\(monthList(spawn))）の前後に岸近くへ寄るので、その少し前が狙い目。")
        }
        if let m = month, spawn.contains(m), !season.contains(m) {
            advice.append("今月は産卵期。浅場に寄る一方で食いが落ちる時期もあるので、朝夕のマズメに絞ると良い。")
        }

        // 場所
        var places: [String] = []
        if groups.contains("堤防") || eco.contains("防波堤") || eco.contains("堤防") { places.append("堤防・漁港") }
        if groups.contains("磯") || eco.contains("磯") { places.append("磯") }
        if groups.contains("砂浜") || groups.contains("投げ") || eco.contains("砂泥") || eco.contains("砂底") || eco.contains("砂浜") { places.append("砂浜・砂泥底") }
        if eco.contains("岩礁") || e.habitatType == "reef-associated" || groups.contains("根魚") { places.append("岩礁帯・根周り") }
        if eco.contains("藻場") || eco.contains("海藻") || eco.contains("アマモ") { places.append("藻場") }
        if groups.contains("汽水") || eco.contains("汽水") || eco.contains("河口") { places.append("河口・汽水域") }
        if groups.contains("渓流") || eco.contains("渓流") || eco.contains("上流") { places.append("渓流・上流") }
        if groups.contains("淡水") && !groups.contains("渓流") { places.append("河川・湖沼") }
        if groups.contains("船") || groups.contains("深場") || (e.depthMinM ?? 0) >= 30 { places.append("沖（船）") }
        if groups.contains("回遊魚") || e.habitatType?.hasPrefix("pelagic") == true { places.append("潮通しの良い表層・中層") }
        if let h = e.habitatTypeJa, places.isEmpty { places.append(h) }
        if let a = e.depthMinM, let b = e.depthMaxM { places.append("水深 \(a)〜\(b) m") } else if let b = e.depthMaxM { places.append("水深 〜\(b) m") }
        if let t1 = e.tempMinC, let t2 = e.tempMaxC { places.append("水温 \(Int(t1.rounded()))〜\(Int(t2.rounded()))℃") }
        var seen = Set<String>(); places = places.filter { seen.insert($0).inserted }

        if !places.isEmpty {
            advice.append("場所は" + places.prefix(3).joined(separator: "、") + "を探す。")
        }
        if let a = e.depthMinM, let b = e.depthMaxM, a <= 5, b <= 60 {
            advice.append("浅い所にもいるので、岸からも十分狙える。")
        } else if let a = e.depthMinM, a >= 50 {
            advice.append("水深 \(a) m より深い所が主な住処なので、基本は船釣り。")
        }

        // 餌・釣り方（食性と釣りの分類から）
        var how: [String] = []
        if eco.contains("小魚") || eco.contains("魚類を") || eco.contains("魚食") { how.append("小魚を食べるのでルアーや泳がせが効く") }
        if eco.contains("甲殻類") || eco.contains("エビ") || eco.contains("カニ") { how.append("エビ・カニの餌や甲殻類に似せたワームが良い") }
        if eco.contains("多毛類") || eco.contains("ゴカイ") || eco.contains("イソメ") { how.append("イソメ類の餌釣りが手堅い") }
        if eco.contains("プランクトン") { how.append("プランクトン食なのでサビキやトリック仕掛けが向く") }
        if eco.contains("藻") && (eco.contains("食べ") || eco.contains("摂食")) && !eco.contains("小魚") { how.append("海藻や付着物も食べるので、ノリやオキアミの餌も試す") }
        if groups.contains("エギング") { how.append("エギ（餌木）で狙うのが定番") }
        if groups.contains("サビキ") { how.append("サビキ仕掛けで数釣りができる") }
        if groups.contains("ルアー") && how.isEmpty { how.append("ルアーの反応が良い") }
        if groups.contains("投げ") { how.append("投げ釣りで広く探る") }
        if groups.contains("夜釣り") || eco.contains("夜行性") || eco.contains("夜間に") { how.append("夜行性なので夜釣りか朝夕のマズメ") }
        else if eco.contains("昼行性") { how.append("昼行性なので日中でも釣れる") }
        if !how.isEmpty { advice.append(how.prefix(2).joined(separator: "。") + "。") }

        // サイズの目安
        if let mx = e.maxLengthCm {
            var s = "最大で \(Int(mx.rounded())) cm"
            if let c = e.commonLengthCm ?? e.typicalLengthCm { s += "、よく釣れるのは \(Int(c.rounded())) cm 前後" }
            if let own = ownMaxCm { s += "（自己記録 \(Int(own.rounded())) cm）" }
            advice.append(s + "。")
        }
        if ownCount > 0 { advice.append("これまでに \(ownCount) 尾。釣った条件はこの下の「自分の釣果」から振り返れる。") }

        // 注意
        if groups.contains("危険") || eco.contains("毒") || eco.contains("棘") && eco.contains("刺") {
            advice.append("棘や毒に注意。素手で触らず、フィッシュグリップと針外しを使う。")
        }
        if e.status == "introduced" { advice.append("外来種。釣ったら放さず持ち帰るか、自治体のルールに従う。") }
        if advice.isEmpty { advice.append("出典に釣り方の手がかりが少ない魚。同じ科の近い魚の狙い方を参考に。") }

        let dist = e.distributionJa.flatMap { $0.split(separator: "。").first.map(String.init) }
        return Output(advice: advice, places: places, distribution: dist)
    }

    static func monthList(_ months: [Int]) -> String {
        let sorted = Array(Set(months)).sorted()
        guard !sorted.isEmpty else { return "" }
        // 連続する範囲は「11〜2月」とまとめる（年またぎも）
        var ranges: [(Int, Int)] = []
        var start = sorted[0], prev = sorted[0]
        for m in sorted.dropFirst() {
            if m == prev + 1 { prev = m } else { ranges.append((start, prev)); start = m; prev = m }
        }
        ranges.append((start, prev))
        if ranges.count >= 2, ranges[0].0 == 1, ranges[ranges.count - 1].1 == 12 {
            let last = ranges.removeLast(); ranges[0] = (last.0, ranges[0].1)
        }
        return ranges.map { $0.0 == $0.1 ? "\($0.0)月" : "\($0.0)〜\($0.1)月" }.joined(separator: "・")
    }
}
