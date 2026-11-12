import SwiftUI
import MapKit
import Core

/// テーマの配置（F-58）で使う追加の部品：直近の釣果の写真、周りの釣り場の小さな地図。
/// どちらも中身はタップ不可（部品全体のタップは HomeView が action に流す）

/// 直近の釣果（新しい順、幅に収まるだけ）：正方形の写真に魚種とサイズ
struct RecentCatchesStrip: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        GeometryReader { geo in
            let tile = max(56, min(96, geo.size.height - 22))
            let count = max(1, Int((geo.size.width + 8) / (tile + 8)))
            let recent = Array(((try? services.store.sessions()) ?? []).flatMap(\.catches).sorted { $0.at > $1.at }.prefix(count))
            HStack(alignment: .top, spacing: 8) {
                ForEach(recent, id: \.id) { c in
                    VStack(alignment: .leading, spacing: 3) {
                        // 写真は枠に敷いて切り、サイズの札は枠に重ねる（縦長の写真でも札が枠の外へ出ない）
                        Color.clear.frame(width: tile, height: tile)
                            .overlay {
                                if let data = services.store.thumbnail(catchID: c.id), let ui = UIImage(data: data) {
                                    Image(uiImage: ui).resizable().scaledToFill()
                                } else {
                                    DS.Color.surface.overlay(Image(systemName: "fish.fill").foregroundStyle(DS.Color.faded))
                                }
                            }
                            .clipped()
                            .overlay(alignment: .bottomLeading) {
                                if let l = c.lengthCm {
                                    Text("\(Int(l.rounded()))").font(DS.Font.number(12)).foregroundStyle(.white)
                                        .padding(.horizontal, 5).padding(.vertical, 2).background(Color.black.opacity(0.5), in: Capsule()).padding(4)
                                }
                            }
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                        Text(c.species.isEmpty ? "魚" : c.species).font(DS.Font.caption).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                        Text(JPFormat.md(c.at)).font(.system(size: 9)).foregroundStyle(DS.Color.textTertiary)
                    }
                    .frame(width: tile)
                }
                if recent.isEmpty {
                    Text("釣果はまだありません").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .allowsHitTesting(false)
        }
    }
}

/// 周りの釣り場の小さな地図：ホームの釣り場を中心に、登録釣り場と近い港を釣れ率の円で。操作はできない（タップは釣り場画面へ）
struct HomeMiniMap: View {
    let model: HomeViewModel
    @Environment(AppServices.self) private var services

    var body: some View {
        let spots = services.spotsModel.allCards.filter { $0.spot.coordinate.isPlausible }.prefix(12)
        Map(initialPosition: .region(MKCoordinateRegion(center: model.coordinate.cl, latitudinalMeters: 6000, longitudinalMeters: 6000)), interactionModes: []) {
            ForEach(Array(spots)) { card in
                Annotation("", coordinate: card.spot.coordinate.cl, anchor: .center) {
                    VStack(spacing: 1) {
                        ZStack {
                            Circle().fill(DS.Color.background.opacity(0.85)).frame(width: 34, height: 34)
                            Circle().trim(from: 0, to: CGFloat(max(0, min(100, card.score))) / 100)
                                .stroke(card.spot.isRegistered ? DS.Color.accent : DS.Color.textTertiary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .rotationEffect(.degrees(-90)).frame(width: 28, height: 28)
                            Text("\(card.score)").font(DS.Font.number(12)).foregroundStyle(DS.Color.textPrimary)
                        }
                        Text(card.spot.name).font(.system(size: 8, weight: .semibold)).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                            .padding(.horizontal, 4).background(DS.Color.background.opacity(0.7), in: Capsule())
                    }
                }
            }
            UserAnnotation(anchor: .center) { _ in
                Circle().fill(.white).frame(width: 9, height: 9).overlay(Circle().stroke(DS.Color.background, lineWidth: 1.5))
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
        .mapControlVisibility(.hidden)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .allowsHitTesting(false)
        .task { if services.spotsModel.cards.isEmpty { services.spotsModel.attach(services) } }
    }
}


/// テーマの `style.glass` 用の面：ぼかし（material）あり／なし、面の濃さ、薄い白い枠と上辺のハイライト
struct GlassShape: View {
    var cornerRadius: CGFloat
    var opacity: Double
    var blur: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if blur { shape.fill(.ultraThinMaterial) }
            shape.fill(DS.Color.panel.opacity(opacity))
            // 上辺がわずかに明るいガラスの質感
            shape.fill(LinearGradient(colors: [Color.white.opacity(0.10), Color.white.opacity(0.02), .clear], startPoint: .top, endPoint: .bottom))
            // テーマの style.borderColor があればその色と太さ、無ければ薄い白い枠
            if let outline = ThemeStore.shared.theme.outlineColor {
                shape.strokeBorder(outline, lineWidth: ThemeStore.shared.theme.outlineWidth)
            } else {
                shape.strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
            }
        }
    }
}
