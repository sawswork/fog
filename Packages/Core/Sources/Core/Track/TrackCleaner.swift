import Foundation

/// 立ち位置の記録（軌跡）を見やすくする。
/// 測位の飛び値（数百 m 先へ飛んで戻る点）を外し、近い点を「立った場所」にまとめて、滞在した分数を出す。
/// 地図には、ぐちゃぐちゃの折れ線の代わりに「立った場所の丸（大きさは滞在時間）」と、それを結ぶ細い線を描く
public enum TrackCleaner {
    public struct Stay: Hashable, Sendable, Identifiable {
        public var id: Int
        public var coordinate: Coordinate
        /// ここに居た合計の分数（同じ場所に戻ってきた分も足す）
        public var minutes: Int
        public var firstAt: Date
        public var sampleCount: Int
    }

    public struct Output: Hashable, Sendable {
        /// 立った場所（最初に立った順）
        public var stays: [Stay]
        /// 立った場所を訪れた順に結ぶ線（同じ場所へ戻ったらその点をもう一度通る）
        public var path: [Coordinate]
        /// 外した飛び値の数
        public var dropped: Int
    }

    /// - Parameters:
    ///   - anchors: 釣果・ロストの位置（中心を決める材料。撮影時は精度の良い位置が取れている）
    ///   - end: 釣行の終わり（最後の場所の滞在時間に使う）
    public static func clean(_ track: [TrackSample], anchors: [Coordinate] = [], end: Date? = nil, mergeRadiusM: Double = 30) -> Output {
        var points = track.filter { $0.coordinate.isPlausible }.sorted { $0.at < $1.at }
        let total = points.count
        guard !points.isEmpty else { return Output(stays: [], path: [], dropped: 0) }

        // 1. 中心（緯度・経度それぞれの中央値）から離れすぎた点を外す。釣り座の移動は数百 m まで
        let all = points.map(\.coordinate) + anchors.filter(\.isPlausible)
        let center = Coordinate(latitude: median(all.map(\.latitude)), longitude: median(all.map(\.longitude)))
        let distances = all.map { Geo.distanceMeters($0, center) }
        let limit = max(250, median(distances) * 4)
        points = points.filter { Geo.distanceMeters($0.coordinate, center) <= limit }

        // 2. 行って戻る飛び値（前の点から 60 m 以上離れ、次の点が前の点の近くへ戻る）を外す。2 回かける
        for _ in 0..<2 {
            var kept: [TrackSample] = []
            for (i, p) in points.enumerated() {
                guard let prev = kept.last, i + 1 < points.count else { kept.append(p); continue }
                let jump = Geo.distanceMeters(prev.coordinate, p.coordinate)
                let back = Geo.distanceMeters(prev.coordinate, points[i + 1].coordinate)
                if jump > 60, back < jump * 0.5 { continue }
                kept.append(p)
            }
            points = kept
        }
        guard !points.isEmpty else { return Output(stays: [], path: [], dropped: total) }

        // 3. 近い点を「立った場所」にまとめる。前に立った場所へ戻ってきたら、その場所に足す
        struct Cluster { var lat: Double; var lon: Double; var n: Int; var seconds: Double; var firstAt: Date }
        var clusters: [Cluster] = []
        var visits: [Int] = []
        let last = end ?? points[points.count - 1].at
        for (i, p) in points.enumerated() {
            let next = i + 1 < points.count ? points[i + 1].at : max(last, p.at)
            // 記録の間が空きすぎたとき（背景で測位が止まっていた）は 30 分までしか数えない
            let dwell = min(max(0, next.timeIntervalSince(p.at)), 1800)
            let index = clusters.indices.min { a, b in
                Geo.distanceMeters(Coordinate(latitude: clusters[a].lat, longitude: clusters[a].lon), p.coordinate)
                    < Geo.distanceMeters(Coordinate(latitude: clusters[b].lat, longitude: clusters[b].lon), p.coordinate)
            }
            if let index, Geo.distanceMeters(Coordinate(latitude: clusters[index].lat, longitude: clusters[index].lon), p.coordinate) <= mergeRadiusM {
                let n = Double(clusters[index].n)
                clusters[index].lat = (clusters[index].lat * n + p.coordinate.latitude) / (n + 1)
                clusters[index].lon = (clusters[index].lon * n + p.coordinate.longitude) / (n + 1)
                clusters[index].n += 1
                clusters[index].seconds += dwell
                if visits.last != index { visits.append(index) }
            } else {
                clusters.append(Cluster(lat: p.coordinate.latitude, lon: p.coordinate.longitude, n: 1, seconds: dwell, firstAt: p.at))
                visits.append(clusters.count - 1)
            }
        }
        let stays = clusters.enumerated().map { i, c in
            Stay(id: i, coordinate: Coordinate(latitude: c.lat, longitude: c.lon), minutes: Int((c.seconds / 60).rounded()), firstAt: c.firstAt, sampleCount: c.n)
        }
        return Output(stays: stays, path: visits.map { stays[$0].coordinate }, dropped: total - points.count)
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// 同じ場所（`radiusM` 以内）に重なる点を、地図の上でずらして並べるための組分け。
    /// 返すのは「各点が、その組の何番目か（0 始まり）と組の大きさ」。入力の順を保つ
    public static func fanOut(_ coordinates: [Coordinate], radiusM: Double = 8) -> [(index: Int, count: Int)] {
        var groups: [[Int]] = []
        for (i, c) in coordinates.enumerated() {
            if let g = groups.firstIndex(where: { Geo.distanceMeters(coordinates[$0[0]], c) <= radiusM }) { groups[g].append(i) } else { groups.append([i]) }
        }
        var out = [(index: Int, count: Int)](repeating: (0, 1), count: coordinates.count)
        for g in groups { for (k, i) in g.enumerated() { out[i] = (k, g.count) } }
        return out
    }
}
