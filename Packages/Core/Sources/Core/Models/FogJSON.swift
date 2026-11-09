import Foundation

/// Core モデルの JSON 表現（エクスポート／インポート、フィクスチャ、SwiftData 内の埋め込み値で共通に使う）。
/// 日付は ISO 8601（UTC、ミリ秒まで）。キーはソートして差分が読めるようにする。
public enum FogJSON {
    public static func encoder(pretty: Bool = true) -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(Self.format(date))
        }
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = Self.parse(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "ISO 8601 の日付ではありません: \(s)")
            }
            return date
        }
        return d
    }

    public static func encode<T: Encodable>(_ value: T, pretty: Bool = true) throws -> Data {
        try encoder(pretty: pretty).encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder().decode(type, from: data)
    }

    // MARK: 日付

    // フォーマッタは作るのが重い（1 個 約 1 ms）。日付ごとに作っていたため、予報キャッシュ（数千の日付）の保存・読み込みや
    // 釣行の復号で数秒固まっていた（2026-11-09 診断ログ）。ISO8601DateFormatter はスレッド安全なので 1 個を使い回す
    private static let fractionFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
    private static let plainFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    public static func format(_ date: Date) -> String { fractionFormatter.string(from: date) }

    public static func parse(_ string: String) -> Date? {
        if let d = fractionFormatter.date(from: string) { return d }
        return plainFormatter.date(from: string)
    }
}
