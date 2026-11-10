import Foundation

/// 「どこに投げると釣れそうか」の見立て（F-63）。港の形（水面の網目）・過去と今日の釣果・風・潮の動きから、
/// 水面の升目ごとに点を付け、上位を返す。**水深や海底の地形のデータは使っていない**（公開されていないため）。
///
/// 点の内訳（合計 1）：
/// - 構造物の際（0.34）：防波堤や岸から 20 m 前後がいちばん高い
/// - 釣果（0.30）：過去に釣れた場所の近く。今日の釣果は 2.5 倍
/// - 先端の潮通し（0.20）：まわりに陸が少ない出っ張り。潮が動いているほど効く
/// - 風（0.16）：ふつうの風は風が当たる面、強風（7 m/s 超）は風裏
///
/// `percent` は確率ではなく「期待度」（30〜90）。釣果が増えるほど釣果の項が効いて当たりやすくなる。
public enum CastPredictor {
    public struct Input: Sendable {
        public var chart: PortChart
        /// 現在地。図の中にあれば、そこから届く範囲（`reachM`）に絞る
        public var user: Coordinate?
        /// 風の吹いてくる方向（北 0°、時計回り）
        public var windFromDeg: Double?
        public var windSpeedMS: Double?
        /// 潮位の変化（cm/時。正で上げ潮）
        public var tideRateCmPerHour: Double?
        public var pastCatches: [Coordinate]
        public var todayCatches: [Coordinate]
        public var reachM: Double
        public var maxZones: Int

        public init(chart: PortChart, user: Coordinate? = nil, windFromDeg: Double? = nil, windSpeedMS: Double? = nil, tideRateCmPerHour: Double? = nil,
                    pastCatches: [Coordinate] = [], todayCatches: [Coordinate] = [], reachM: Double = 70, maxZones: Int = 3) {
            self.chart = chart; self.user = user; self.windFromDeg = windFromDeg; self.windSpeedMS = windSpeedMS
            self.tideRateCmPerHour = tideRateCmPerHour; self.pastCatches = pastCatches; self.todayCatches = todayCatches
            self.reachM = reachM; self.maxZones = maxZones
        }
    }

    public struct Zone: Hashable, Sendable, Identifiable {
        public var rank: Int
        /// 絵の中の位置（0〜1）
        public var x: Double
        public var y: Double
        public var coordinate: Coordinate
        /// 期待度（30〜90）
        public var percent: Int
        /// 現在地からの距離（m）と方位（北 0°、時計回り）。現在地が分からなければ nil
        public var distanceM: Double?
        public var bearingDeg: Double?
        public var reasons: [String]
        public var id: Int { rank }
    }

    static let wEdge = 0.34, wCatch = 0.30, wTip = 0.20, wWind = 0.16
    /// 候補どうしの最小の間隔（m）
    static let separationM = 30.0

    public static func predict(_ input: Input) -> [Zone] {
        let chart = input.chart
        let grid = chart.waterGrid()
        let cols = grid.cols, rows = grid.rows
        guard cols > 2, rows > 2, input.maxZones > 0 else { return [] }
        let cellW = chart.widthM / Double(cols), cellH = chart.heightM / Double(rows)
        let cell = (cellW + cellH) / 2

        // 陸までの距離（升目の数。8 方向の幅優先）
        var dist = [Int](repeating: Int.max, count: cols * rows)
        var queue: [Int] = []
        for i in 0..<(cols * rows) where !grid.cells[i] { dist[i] = 0; queue.append(i) }
        let hasLand = !queue.isEmpty
        var head = 0
        while head < queue.count {
            let i = queue[head]; head += 1
            let r = i / cols, c = i % cols
            for dr in -1...1 {
                for dc in -1...1 where dr != 0 || dc != 0 {
                    let rr = r + dr, cc = c + dc
                    guard rr >= 0, cc >= 0, rr < rows, cc < cols else { continue }
                    let j = rr * cols + cc
                    if dist[j] == Int.max { dist[j] = dist[i] + 1; queue.append(j) }
                }
            }
        }

        // 現在地（絵の中の升目の位置）
        let userPoint: (x: Double, y: Double)? = input.user.flatMap { u in chart.contains(u) ? chart.point(for: u) : nil }
        func meters(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) -> Double {
            let dx = (ax - bx) * chart.widthM, dy = (ay - by) * chart.heightM
            return (dx * dx + dy * dy).squareRoot()
        }
        func center(_ c: Int, _ r: Int) -> (x: Double, y: Double) { ((Double(c) + 0.5) / Double(cols), (Double(r) + 0.5) / Double(rows)) }

        // 候補：水面で、現在地から届く範囲。現在地が無い・届く水面が無いときは、岸から 60 m 以内の水面
        var candidates: [Int] = []
        if let u = userPoint {
            for i in 0..<(cols * rows) where grid.cells[i] {
                let p = center(i % cols, i / cols)
                if meters(p.x, p.y, u.x, u.y) <= input.reachM { candidates.append(i) }
            }
        }
        if candidates.isEmpty {
            let limit = max(1, Int((60 / cell).rounded()))
            for i in 0..<(cols * rows) where grid.cells[i] && (!hasLand || dist[i] <= limit) { candidates.append(i) }
        }
        guard !candidates.isEmpty else { return [] }

        // 釣果の点（絵の中だけ）
        let past = input.pastCatches.filter { chart.contains($0) }.map { chart.point(for: $0) }
        let today = input.todayCatches.filter { chart.contains($0) }.map { chart.point(for: $0) }
        func catchDensity(_ p: (x: Double, y: Double)) -> Double {
            var s = 0.0
            for q in past { let d = meters(p.x, p.y, q.x, q.y); s += exp(-(d * d) / 800) }          // σ = 20 m
            for q in today { let d = meters(p.x, p.y, q.x, q.y); s += 2.5 * exp(-(d * d) / 800) }
            return s
        }
        let densities = candidates.map { catchDensity(center($0 % cols, $0 / cols)) }
        let maxDensity = densities.max() ?? 0

        // 風：風下へ進む向き（絵の中。北が上なので y は南が正）
        let speed = input.windSpeedMS ?? 0
        var down: (dc: Double, dr: Double)? = nil
        if let from = input.windFromDeg, speed >= 1.5 {
            let to = (from + 180) * .pi / 180
            down = (sin(to), -cos(to))
        }
        func landWithin(_ c: Int, _ r: Int, _ dc: Double, _ dr: Double) -> Double {
            for k in 1...4 {
                let cc = c + Int((dc * Double(k)).rounded()), rr = r + Int((dr * Double(k)).rounded())
                guard cc >= 0, rr >= 0, cc < cols, rr < rows else { return 0 }
                if !grid.cells[rr * cols + cc] { return 1 - Double(k - 1) / 4 }
            }
            return 0
        }
        let tideMoving = abs(input.tideRateCmPerHour ?? 0) > 2

        struct Scored { var index: Int; var total: Double; var edge: Double; var catchTerm: Double; var tip: Double; var windward: Double; var lee: Double }
        var scored: [Scored] = []
        for (n, i) in candidates.enumerated() {
            let c = i % cols, r = i / cols
            let dM = hasLand ? Double(dist[i]) * cell : 1_000
            let edge = hasLand ? exp(-pow((dM - 18) / 22, 2)) : 0
            // 先端：まわり（半径 3 升）の陸の割合が小さく、岸から 45 m 以内
            var land = 0, total = 0
            for dr in -3...3 { for dc in -3...3 {
                let rr = r + dr, cc = c + dc
                guard rr >= 0, cc >= 0, rr < rows, cc < cols else { continue }
                total += 1
                if !grid.cells[rr * cols + cc] { land += 1 }
            } }
            let f = total > 0 ? Double(land) / Double(total) : 0
            let tip = (f > 0 && dM <= 45) ? max(0, 1 - f / 0.2) * (tideMoving ? 1 : 0.5) : 0
            let catchTerm = maxDensity > 0 ? densities[n] / maxDensity : 0
            var windward = 0.0, lee = 0.0
            if let d = down {
                windward = landWithin(c, r, d.dc, d.dr)          // 風下側に陸＝風が当たる面
                lee = landWithin(c, r, -d.dc, -d.dr)             // 風上側に陸＝風裏
            }
            let wind = speed > 7 ? lee : windward
            let sum = wEdge * edge + wCatch * catchTerm + wTip * tip + wWind * wind
            scored.append(Scored(index: i, total: sum, edge: edge, catchTerm: catchTerm, tip: tip, windward: windward, lee: lee))
        }
        // 点の高い順。同点は升目の番号で固定（毎回同じ結果にする）
        scored.sort { $0.total != $1.total ? $0.total > $1.total : $0.index < $1.index }

        var picked: [Scored] = []
        for s in scored {
            guard s.total >= 0.12 else { break }
            let p = center(s.index % cols, s.index / cols)
            let far = picked.allSatisfy { q in
                let qp = center(q.index % cols, q.index / cols)
                return meters(p.x, p.y, qp.x, qp.y) >= separationM
            }
            if far { picked.append(s) }
            if picked.count >= input.maxZones { break }
        }

        return picked.enumerated().map { n, s in
            let p = center(s.index % cols, s.index / cols)
            let coordinate = chart.coordinate(x: p.x, y: p.y)
            var reasons: [String] = []
            if s.catchTerm > 0.4 { reasons.append("過去に釣れた場所") }
            if s.tip > 0.5 { reasons.append("先端の潮通し") }
            if s.edge > 0.6 { reasons.append("構造物の際") }
            if speed > 7, s.lee > 0.5 { reasons.append("風裏") } else if speed >= 1.5, speed <= 7, s.windward > 0.5 { reasons.append("風が当たる面") }
            var distance: Double? = nil, bearing: Double? = nil
            if let u = input.user {
                distance = Geo.distanceMeters(u, coordinate)
                let up = chart.point(for: u)
                let dx = (p.x - up.x) * chart.widthM, dy = (up.y - p.y) * chart.heightM     // 東と北（m）
                var deg = atan2(dx, dy) * 180 / .pi
                if deg < 0 { deg += 360 }
                bearing = deg
            }
            let percent = Int((30 + 60 * min(1, s.total / 0.85)).rounded())
            return Zone(rank: n + 1, x: p.x, y: p.y, coordinate: coordinate, percent: percent, distanceM: distance, bearingDeg: bearing, reasons: reasons)
        }
    }

    /// 16 方位の名前（北 0°、時計回り）
    public static func compassName(_ deg: Double) -> String {
        let names = ["北", "北北東", "北東", "東北東", "東", "東南東", "南東", "南南東", "南", "南南西", "南西", "西南西", "西", "西北西", "北西", "北北西"]
        let d = deg.truncatingRemainder(dividingBy: 360)
        let i = Int(((d < 0 ? d + 360 : d) / 22.5).rounded()) % 16
        return names[i]
    }
}
