import SwiftUI
import Core

/// 仲間の釣果の 1 行（サムネイル、時刻、魚種とサイズ、釣った人）。仲間の釣行の詳細と、自分の釣行の「仲間の釣果」で使う
struct SharedCatchRow: View {
    let item: SharedCatch
    let thumbnail: Data?

    var body: some View {
        HStack(spacing: DS.Spacing.m) {
            Color.clear.frame(width: 56, height: 56)
                .overlay {
                    if let thumbnail, let ui = UIImage(data: thumbnail) {
                        Image(uiImage: ui).resizable().scaledToFill()
                    } else {
                        ZStack {
                            DS.Color.surface
                            Image(systemName: "fish.fill").foregroundStyle(DS.Color.faded)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DS.Spacing.s) {
                    Text(JPFormat.hm(item.at)).font(DS.Font.number(14)).foregroundStyle(DS.Color.textSecondary)
                    Text(item.species.isEmpty ? "魚種なし" : item.species).font(.system(size: 16, weight: .semibold)).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                    Text(PartyTrips.displayName(owner: item.angler)).font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.Color.background)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(DS.Color.sun, in: Capsule())
                }
                HStack(spacing: DS.Spacing.s) {
                    Text(item.lengthCm.map { "\(Int($0.rounded()))cm" } ?? "未計測").font(DS.Font.number(16))
                        .foregroundStyle(item.lengthCm == nil ? DS.Color.textTertiary : DS.Color.accent)
                    if let t = item.tideName { Text(t).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary) }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// 仲間の釣行の詳細（F-62）。自分は行っていない釣行：いつ・どこで・誰が・何を釣ったか。写真はタップで全画面（本体は iCloud から）
struct FriendTripDetailView: View {
    let card: LogViewModel.FriendTripCard
    @Environment(AppServices.self) private var services
    @State private var viewing: SharedCatch?

    private var trip: PartyTrip { card.trip }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                header
                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    Text(card.catches.isEmpty ? "釣果" : "釣果 \(card.catches.count)尾 · タップで写真").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                    if card.catches.isEmpty {
                        Text(trip.isActive ? "まだ釣果はありません" : "ボウズ").font(DS.Font.label).foregroundStyle(DS.Color.textSecondary)
                    }
                    ForEach(card.catches) { c in
                        Button { viewing = c } label: { SharedCatchRow(item: c, thumbnail: services.party.thumbnail(for: c.id)) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(DS.Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Color.panel, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)).themeOutline(DS.Radius.card)
            }
            .padding(DS.Spacing.l)
        }
        .background(ThemeBackground(name: .bgDetail))
        .fullScreenCover(item: $viewing) { s in
            PhotoViewer(catchItem: Catch(id: s.id, sessionID: s.id, at: s.at, coordinate: s.coordinate, species: s.species, speciesConfidence: 1, lengthCm: s.lengthCm, angler: s.angler),
                        fallback: services.party.thumbnail(for: s.id), sharedID: s.id)
        }
    }

    /// 釣り場名、日付と時間帯、いっしょに行った人、数字
    private var header: some View {
        let end = trip.endedAt ?? Date()
        let maxLen = card.catches.compactMap(\.lengthCm).max()
        return VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text(trip.spotName.isEmpty ? "釣り場" : trip.spotName).font(DS.Font.number(24)).foregroundStyle(DS.Color.textPrimary)
            Text("\(JPFormat.ymdw(trip.startedAt)) \(JPFormat.hm(trip.startedAt))〜\(trip.isActive ? "記録中" : JPFormat.hm(end)) · \(JPFormat.duration(end.timeIntervalSince(trip.startedAt)))")
                .font(DS.Font.label).foregroundStyle(DS.Color.textSecondary)
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "person.2.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Color.textTertiary)
                ForEach(trip.members, id: \.self) { name in
                    Text(name).font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Color.background)
                        .padding(.horizontal, 7).padding(.vertical, 3).background(DS.Color.sun, in: Capsule())
                }
            }
            HStack(spacing: DS.Spacing.s) {
                stat("尾数", card.catches.isEmpty ? (trip.isActive ? "0" : "ボウズ") : "\(card.catches.count)", unit: card.catches.isEmpty ? "" : "尾")
                stat("最大", maxLen.map { "\(Int($0.rounded()))" } ?? "—", unit: "cm")
                stat("魚種", "\(Set(card.catches.map(\.species).filter { !$0.isEmpty }).count)", unit: "種")
                stat("人数", "\(trip.members.count)", unit: "人")
            }
        }
    }

    private func stat(_ label: String, _ value: String, unit: String = "") -> some View {
        VStack(spacing: 2) {
            Text(label).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(DS.Font.number(20)).foregroundStyle(DS.Color.textPrimary).lineLimit(1).minimumScaleFactor(0.7)
                if !unit.isEmpty { Text(unit).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary) }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.s)
        .background(DS.Color.panel, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)).themeOutline(DS.Radius.chip)
    }
}

/// 仲間の釣行のカード（ログの横スクロール）。自分の釣行のカードと同じ形で、上に「誰の釣行か」を出す
struct FriendTripCardView: View {
    let card: LogViewModel.FriendTripCard
    let duration: String

    var body: some View {
        Color.clear
            .overlay {
                if let data = card.thumbnail, let ui = UIImage(data: data) {
                    Image(uiImage: ui).resizable().scaledToFill()
                        .overlay(LinearGradient(colors: [.clear, DS.Color.background.opacity(0.85)], startPoint: .center, endPoint: .bottom))
                } else {
                    DS.Color.panel
                }
            }
            .overlay(alignment: .topLeading) {
                // 誰の釣行か（自分は行っていない）
                HStack(spacing: 4) {
                    Image(systemName: "person.2.fill").font(.system(size: 9, weight: .bold))
                    Text(card.trip.members.joined(separator: "・")).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                }
                .foregroundStyle(DS.Color.background)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(DS.Color.sun, in: Capsule())
                .padding(DS.Spacing.s)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.trip.startedAt, format: .dateTime.year().month(.twoDigits).day(.twoDigits)).font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                    Text(card.trip.spotName.isEmpty ? "釣り場" : card.trip.spotName).font(.system(size: 20, weight: .bold)).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                    HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                        Text(card.catches.isEmpty ? (card.trip.isActive ? "0" : "ボウズ") : "\(card.catches.count)").font(DS.Font.number(24))
                            .foregroundStyle(card.catches.isEmpty ? DS.Color.textSecondary : DS.Color.textPrimary)
                        Text(card.trip.isActive ? "記録中" : duration).font(DS.Font.caption).foregroundStyle(card.trip.isActive ? DS.Color.accent : DS.Color.textTertiary)
                    }
                }
                .padding(DS.Spacing.m)
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .themeOutline(DS.Radius.card)
    }
}
