import SwiftUI
import Core

/// 釣果情報（F-27）：登録 RSS から集めた記事の一覧。自分の魚種・釣り場に関係するものを先に、同じ強さなら新しい順。
/// 記事はタップでブラウザへ。縦スクロールを許す（図鑑グリッドと同じ例外）。
struct FeedView: View {
    let keywords: [String]
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var refreshing = false
    @State private var onlyRelevant = false
    /// 仲間の釣果の写真を全画面で（F-54/F-55）
    @State private var viewing: SharedCatch?

    private var items: [FeedItem] {
        let all = services.feeds.sorted(keywords: keywords)
        return onlyRelevant ? all.filter { !FeedRelevance.matches($0, keywords: keywords).isEmpty } : all
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("釣果情報").font(DS.Font.number(20)).foregroundStyle(DS.Color.textPrimary)
                Spacer()
                Button { onlyRelevant.toggle() } label: {
                    Text(onlyRelevant ? "関連だけ" : "全部").font(DS.Font.caption).foregroundStyle(onlyRelevant ? DS.Color.background : DS.Color.textPrimary)
                        .padding(.horizontal, DS.Spacing.m).padding(.vertical, DS.Spacing.xs)
                        .background(onlyRelevant ? DS.Color.accent : DS.Color.surface, in: Capsule())
                }
                .buttonStyle(.plain)
                Button {
                    refreshing = true
                    Task {
                        await services.feeds.refreshIfNeeded(force: true)
                        await services.party.syncIfNeeded(store: services.store, force: true)
                        refreshing = false
                    }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.Color.textSecondary).frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(refreshing)
            }
            if services.feeds.urls.isEmpty {
                Text("設定 > 情報源 で釣りメディアや釣具店ブログの RSS を登録すると、ここに集まります").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
            } else if items.isEmpty {
                Text(refreshing ? "取得中" : (services.feeds.lastError ?? "記事はまだありません")).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
            }
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: DS.Spacing.s) {
                    // 仲間の釣果（F-54）：相手の端末で撮った魚。新しい順に最大 20 件
                    let shared = services.party.others
                    if !shared.isEmpty {
                        Text("仲間の釣果").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                        ForEach(shared.prefix(20)) { s in sharedRow(s) }
                        Text("釣果情報（記事）").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).padding(.top, DS.Spacing.s)
                    }
                    ForEach(items) { item in row(item) }
                }
            }
        }
        .padding(DS.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ThemeBackground(name: .bgDetail))
        .task { await services.party.syncIfNeeded(store: services.store) }
        .fullScreenCover(item: $viewing) { s in
            PhotoViewer(catchItem: Catch(id: s.id, sessionID: s.id, at: s.at, coordinate: s.coordinate, species: s.species, speciesConfidence: 1, lengthCm: s.lengthCm, angler: s.angler),
                        fallback: services.party.thumbnail(for: s.id))
        }
    }

    private func sharedRow(_ s: SharedCatch) -> some View {
        Button { viewing = s } label: {
            HStack(spacing: DS.Spacing.m) {
                if let data = services.party.thumbnail(for: s.id), let ui = UIImage(data: data) {
                    Image(uiImage: ui).resizable().scaledToFill().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip))
                } else {
                    RoundedRectangle(cornerRadius: DS.Radius.chip).fill(DS.Color.surface).frame(width: 56, height: 56)
                        .overlay(Image(systemName: "fish.fill").foregroundStyle(DS.Color.faded))
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: DS.Spacing.s) {
                        Text(s.headline).font(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                        Text(s.angler).font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.Color.background)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(DS.Color.sun, in: Capsule())
                    }
                    HStack(spacing: DS.Spacing.s) {
                        if !s.spotName.isEmpty { Text(s.spotName).font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary).lineLimit(1) }
                        Text(s.at, format: .dateTime.month().day().hour().minute()).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                        if let t = s.tideName { Text(t).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary) }
                    }
                }
                Spacer()
            }
            .padding(DS.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Color.panel, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func row(_ item: FeedItem) -> some View {
        let hits = FeedRelevance.matches(item, keywords: keywords)
        let content = VStack(alignment: .leading, spacing: 3) {
            Text(item.title).font(DS.Font.label).foregroundStyle(DS.Color.textPrimary).lineLimit(2)
            if let s = item.summary, !s.isEmpty {
                Text(s).font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary).lineLimit(2)
            }
            HStack(spacing: DS.Spacing.s) {
                Text(item.feedTitle).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).lineLimit(1)
                if let d = item.publishedAt { Text(d, format: .dateTime.month().day().hour().minute()).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary) }
                Spacer()
                ForEach(hits.prefix(3), id: \.self) { k in
                    Text(k).font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.Color.accent)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(DS.Color.accent.opacity(0.15), in: Capsule())
                }
            }
        }
        .padding(DS.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.panel, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
        return Group {
            if let link = item.link, let url = URL(string: link) { Link(destination: url) { content } } else { content }
        }
    }
}
