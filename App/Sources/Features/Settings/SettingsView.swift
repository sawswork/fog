import SwiftUI
import UniformTypeIdentifiers
import Core

/// 設定（§8、ホーム右上の歯車）。6 項目の入口を 1 画面に収め、各項目は 1 画面の子ページで完結する。
struct SettingsView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var tackleCount = 0
    @State private var rigCount = 0

    var body: some View {
        NavigationStack {
            List {
                row("タックル", system: "wrench.and.screwdriver", trailing: "\(tackleCount)・\(rigCount)") { TackleSettingsView() }
                row("釣り人", system: "person.2", trailing: AnglerSettings.ownName + (AnglerSettings.members.isEmpty ? "" : " +\(AnglerSettings.members.count)")) { AnglerSettingsView() }
                row("データ", system: "icloud", trailing: cloudLabel) { DataSettingsView() }
                row("通知", system: "bell", trailing: notifyLabel) { NotificationSettingsView() }
                row("判定", system: "fish", trailing: CoreMLSpeciesClassifier.modelVersion) { JudgementSettingsView() }
                row("自動検出", system: "location", trailing: SessionDetectionService.autoDetectionEnabled ? SessionDetectionService.sensitivity.label : "オフ") { DetectionSettingsView() }
                row("地図レイヤー", system: "square.3.layers.3d", trailing: "\(MapLayerSettings.enabled.count)/\(MapLayer.allCases.count)") { MapLayerSettingsView() }
                row("情報源", system: "info.circle", trailing: "") { SourcesSettingsView() }
                row("テーマ", system: "paintpalette", trailing: ThemeStore.shared.theme.label) { ThemeSettingsView() }
                row("診断", system: "waveform.path.ecg", trailing: "") { DiagnosticsView() }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .background(ThemeBackground(name: .bgSheet))
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark").foregroundStyle(DS.Color.textSecondary) }
                }
            }
            .onAppear { Perf.mark("設定を開いた"); reload() }
            .onReceive(NotificationCenter.default.publisher(for: .fogStoreDidChange)) { _ in reload() }
        }
        .preferredColorScheme(ThemeStore.shared.theme.colorScheme)
        .tint(DS.Color.accent)
    }

    private func reload() {
        tackleCount = (try? services.store.tackles().count) ?? 0
        rigCount = (try? services.store.rigs().count) ?? 0
    }

    private var cloudLabel: String {
        switch services.persistence.mode {
        case .cloudKit: return "iCloud"
        case .local: return "ローカル"
        case .inMemory: return "一時"
        }
    }

    private var notifyLabel: String {
        let on = NotificationSettings.Kind.allCases.filter { NotificationSettings.isEnabled($0) }.count
        return "\(on)/\(NotificationSettings.Kind.allCases.count)"
    }

    private func row<D: View>(_ title: String, system: String, trailing: String, @ViewBuilder destination: @escaping () -> D) -> some View {
        NavigationLink { destination() } label: {
            HStack(spacing: DS.Spacing.m) {
                Image(systemName: system).font(.system(size: 16, weight: .semibold)).foregroundStyle(DS.Color.accent).frame(width: 24)
                Text(title).font(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                Spacer()
                Text(trailing).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
            }
            .padding(.vertical, DS.Spacing.s)
        }
        .listRowBackground(DS.Color.background)
        .listRowSeparatorTint(DS.Color.surfaceRaised)
    }
}

extension DetectionSettings.Sensitivity {
    var label: String {
        switch self {
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        }
    }
}

// MARK: - 共通部品

private struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        content
            .scrollContentBackground(.hidden)
            .background(ThemeBackground(name: .bgSheet))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

private extension View {
    func settingsRow() -> some View {
        listRowBackground(ThemeStore.shared.theme.hasAssets ? DS.Color.panel : DS.Color.background).listRowSeparatorTint(DS.Color.surfaceRaised)
    }
}

private struct SectionLabel: View {
    let text: String
    var body: some View { Text(text).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary) }
}

// MARK: - タックル

struct TackleSettingsView: View {
    @Environment(AppServices.self) private var services
    @State private var tackles: [Tackle] = []
    @State private var rigs: [Rig] = []
    @State private var editingTackle: Tackle?
    @State private var editingRig: Rig?
    @State private var editingItem: InventoryItem?
    static let maxRigs = 10

    var body: some View {
        SettingsPage(title: "タックル") {
            List {
                Section {
                    ForEach(tackles) { t in
                        Button { editingTackle = t } label: {
                            HStack {
                                Text(t.kind == .spinning ? "スピニング" : "ベイト").font(DS.Font.caption)
                                    .foregroundStyle(DS.Color.accent)
                                    .padding(.horizontal, DS.Spacing.s).padding(.vertical, 2)
                                    .background(DS.Color.accent.opacity(0.15), in: Capsule())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.name).font(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                                    Text([t.rod, t.reel, t.line].filter { !$0.isEmpty }.joined(separator: " / "))
                                        .font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).lineLimit(1)
                                }
                                Spacer()
                            }
                        }
                        .settingsRow()
                    }
                    .onDelete { idx in idx.map { tackles[$0] }.forEach { try? services.store.deleteTackle(id: $0.id) }; reload() }
                    Button { editingTackle = Tackle(kind: tackles.contains { $0.kind == .spinning } ? .bait : .spinning, name: "") } label: {
                        Label("タックルを追加", systemImage: "plus").font(DS.Font.label).foregroundStyle(DS.Color.accent)
                    }
                    .settingsRow()
                } header: { SectionLabel(text: "タックル") }

                Section {
                    ForEach(rigs) { r in
                        Button { editingRig = r } label: {
                            HStack {
                                Text(r.displayName).font(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                                Spacer()
                                Text(r.hookSize.isEmpty ? "" : "#\(r.hookSize)").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                            }
                        }
                        .settingsRow()
                    }
                    .onDelete { idx in idx.map { rigs[$0] }.forEach { try? services.store.deleteRig(id: $0.id) }; reload() }
                    if rigs.count < Self.maxRigs {
                        Button { editingRig = Rig(sinkerGrams: 14, hookSize: "", worm: "", sortOrder: rigs.count) } label: {
                            Label("リグを追加", systemImage: "plus").font(DS.Font.label).foregroundStyle(DS.Color.accent)
                        }
                        .settingsRow()
                    }
                } header: { SectionLabel(text: "リグプリセット \(rigs.count)/\(Self.maxRigs)") }

                // 在庫（F-26）：針ロストでそのリグのシンカーとフックが 1 つ減る
                Section {
                    ForEach(services.inventory.items) { item in
                        HStack(spacing: DS.Spacing.s) {
                            Button { editingItem = item } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name).font(DS.Font.label).foregroundStyle(item.isLow ? DS.Color.holiday : DS.Color.textPrimary)
                                    Text(item.kind.label + (item.rigID.flatMap { id in rigs.first { $0.id == id }?.displayName }.map { " · \($0)" } ?? "")).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            Button { services.inventory.adjust(id: item.id, by: -1) } label: { Image(systemName: "minus.circle").font(.system(size: 18)).foregroundStyle(DS.Color.textSecondary) }.buttonStyle(.plain)
                            Text("\(item.count)").font(DS.Font.number(16)).foregroundStyle(item.isLow ? DS.Color.holiday : DS.Color.textPrimary).frame(width: 32)
                            Button { services.inventory.adjust(id: item.id, by: +1) } label: { Image(systemName: "plus.circle").font(.system(size: 18)).foregroundStyle(DS.Color.textSecondary) }.buttonStyle(.plain)
                        }
                        .settingsRow()
                    }
                    .onDelete { idx in idx.map { services.inventory.items[$0] }.forEach { services.inventory.delete(id: $0.id) } }
                    Button { editingItem = InventoryItem(name: "", kind: .sinker, count: 10, lowThreshold: 3, rigID: rigs.first?.id) } label: {
                        Label("在庫を追加", systemImage: "plus").font(DS.Font.label).foregroundStyle(DS.Color.accent)
                    }
                    .settingsRow()
                } header: { SectionLabel(text: "在庫（針ロストで減る）") }
            }
            .listStyle(.plain)
        }
        .onAppear(perform: reload)
        .sheet(item: $editingTackle) { t in TackleEditSheet(tackle: t) { reload() }.presentationDetents([.medium]) }
        .sheet(item: $editingRig) { r in RigEditSheet(rig: r) { reload() }.presentationDetents([.medium]) }
        .sheet(item: $editingItem) { i in InventoryEditSheet(item: i, rigs: rigs).presentationDetents([.medium]) }
    }

    private func reload() {
        tackles = (try? services.store.tackles()) ?? []
        rigs = ((try? services.store.rigs()) ?? []).sorted { $0.sortOrder < $1.sortOrder }
    }
}

private struct TackleEditSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State var tackle: Tackle
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Picker("種別", selection: $tackle.kind) {
                    Text("スピニング").tag(TackleKind.spinning)
                    Text("ベイト").tag(TackleKind.bait)
                }
                .pickerStyle(.segmented).settingsRow()
                TextField("名前（例: 岸壁ロック）", text: $tackle.name).settingsRow()
                TextField("ロッド", text: $tackle.rod).settingsRow()
                TextField("リール", text: $tackle.reel).settingsRow()
                TextField("ライン", text: $tackle.line).settingsRow()
            }
            .scrollContentBackground(.hidden)
            .background(ThemeBackground(name: .bgSheet))
            .navigationTitle("タックル")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var t = tackle
                        if t.name.isEmpty { t.name = t.kind == .spinning ? "スピニング" : "ベイト" }
                        try? services.store.upsert(t)
                        onSave(); dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(ThemeStore.shared.theme.colorScheme)
    }
}

private struct RigEditSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State var rig: Rig
    @State private var grams: String = ""
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("名前（空なら重さとワームから）", text: $rig.name).settingsRow()
                HStack {
                    TextField("シンカー", text: $grams).keyboardType(.decimalPad)
                    Text("g").foregroundStyle(DS.Color.textTertiary)
                }
                .settingsRow()
                TextField("フックサイズ（例: 1/0）", text: $rig.hookSize).settingsRow()
                TextField("ワーム", text: $rig.worm).settingsRow()
            }
            .scrollContentBackground(.hidden)
            .background(ThemeBackground(name: .bgSheet))
            .navigationTitle("リグ")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { grams = rig.sinkerGrams == rig.sinkerGrams.rounded() ? String(Int(rig.sinkerGrams)) : String(rig.sinkerGrams) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var r = rig
                        r.sinkerGrams = Double(grams.replacingOccurrences(of: ",", with: ".")) ?? r.sinkerGrams
                        try? services.store.upsert(r)
                        onSave(); dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(ThemeStore.shared.theme.colorScheme)
    }
}

private struct InventoryEditSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State var item: InventoryItem
    let rigs: [Rig]
    @State private var countText = ""
    @State private var thresholdText = ""
    private static let noRig = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    var body: some View {
        NavigationStack {
            Form {
                TextField("名前（例: 14g バレット）", text: $item.name).settingsRow()
                Picker("種類", selection: $item.kind) {
                    ForEach(InventoryItem.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).settingsRow()
                HStack { TextField("数", text: $countText).keyboardType(.numberPad); Text("個").foregroundStyle(DS.Color.textTertiary) }.settingsRow()
                HStack { TextField("知らせる残数", text: $thresholdText).keyboardType(.numberPad); Text("個以下").foregroundStyle(DS.Color.textTertiary) }.settingsRow()
                Picker("紐付くリグ", selection: Binding(get: { item.rigID ?? Self.noRig }, set: { item.rigID = $0 == Self.noRig ? nil : $0 })) {
                    Text("なし").tag(Self.noRig)
                    ForEach(rigs) { r in Text(r.displayName).tag(r.id) }
                }
                .settingsRow()
            }
            .scrollContentBackground(.hidden)
            .background(ThemeBackground(name: .bgSheet))
            .navigationTitle("在庫")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { countText = String(item.count); thresholdText = String(item.lowThreshold) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var i = item
                        if i.name.isEmpty { i.name = i.kind.label }
                        i.count = max(0, Int(countText) ?? i.count)
                        i.lowThreshold = max(0, Int(thresholdText) ?? i.lowThreshold)
                        services.inventory.upsert(i)
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(ThemeStore.shared.theme.colorScheme)
    }
}

// MARK: - データ

struct DataSettingsView: View {
    @Environment(AppServices.self) private var services
    @State private var shareItems: ShareItems?
    @State private var importing = false
    @State private var confirmDelete = false
    @State private var zipProgress: Double?
    @State private var message: String?

    struct ShareItems: Identifiable { let id = UUID(); let urls: [URL] }

    var body: some View {
        SettingsPage(title: "データ") {
            List {
                Section {
                    HStack {
                        Circle().fill(services.persistence.mode == .cloudKit ? DS.Color.secondary : DS.Color.textTertiary).frame(width: 8, height: 8)
                        Text(cloudStatus).font(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                    }
                    .settingsRow()
                    if let err = services.persistence.fallbackError {
                        Text(err.localizedDescription).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).settingsRow()
                    }
                } header: { SectionLabel(text: "iCloud 同期") }

                Section {
                    actionRow("CSV エクスポート", system: "tablecells") { run { ShareItems(urls: try services.dataManager.exportCSV()) } }
                    actionRow("JSON エクスポート", system: "doc.text") { run { ShareItems(urls: [try services.dataManager.exportJSON()]) } }
                    if let p = zipProgress {
                        HStack {
                            ProgressView(value: p).tint(DS.Color.accent)
                            Text("\(Int(p * 100))%").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                        }
                        .settingsRow()
                    } else {
                        actionRow("写真付き ZIP", system: "photo.on.rectangle") { exportZip() }
                    }
                    actionRow("JSON から復元", system: "square.and.arrow.down") { importing = true }
                } header: { SectionLabel(text: "エクスポート・復元") }

                Section {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("全データ削除", systemImage: "trash").font(DS.Font.label)
                    }
                    .settingsRow()
                    if let message {
                        Text(message).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).settingsRow()
                    }
                }
            }
            .listStyle(.plain)
        }
        .sheet(item: $shareItems) { items in ShareSheet(urls: items.urls) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let n = try services.dataManager.importJSON(from: url)
                message = "\(n) 釣行を復元しました"
            } catch { message = "復元できませんでした: \(error.localizedDescription)" }
        }
        .confirmationDialog("すべての釣果・釣行・釣り場を削除します。元に戻せません。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("全データ削除", role: .destructive) {
                do { try services.dataManager.deleteAll(); message = "削除しました" } catch { message = error.localizedDescription }
            }
            Button("キャンセル", role: .cancel) {}
        }
    }

    private var cloudStatus: String {
        switch services.persistence.mode {
        case .cloudKit: return "iCloud に同期中"
        case .local: return "この端末だけに保存（iCloud 利用不可）"
        case .inMemory: return "一時保存（再起動で消えます）"
        }
    }

    private func actionRow(_ title: String, system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: system).font(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
        }
        .settingsRow()
    }

    private func run(_ make: () throws -> ShareItems) {
        do { shareItems = try make() } catch { message = error.localizedDescription }
    }

    private func exportZip() {
        zipProgress = 0
        Task {
            do {
                let url = try await services.dataManager.exportZipWithPhotos { p in Task { @MainActor in zipProgress = p } }
                shareItems = ShareItems(urls: [url])
            } catch { message = error.localizedDescription }
            zipProgress = nil
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - 通知

struct NotificationSettingsView: View {
    @State private var enabled: [NotificationSettings.Kind: Bool] = [:]
    @State private var weekendOnly = NotificationSettings.briefWeekendOnly
    @State private var registeredOnly = NotificationSettings.briefRegisteredOnly
    @State private var homeTimeOn = NotificationSettings.homeTimeMinutes != nil
    @State private var homeTime = Date()

    var body: some View {
        SettingsPage(title: "通知") {
            List {
                Section {
                    ForEach(NotificationSettings.Kind.allCases) { kind in
                        Toggle(isOn: Binding(
                            get: { enabled[kind] ?? NotificationSettings.isEnabled(kind) },
                            set: { enabled[kind] = $0; NotificationSettings.setEnabled($0, for: kind) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.title).font(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                                Text(kind.detail).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                            }
                        }
                        .tint(DS.Color.accent)
                        .settingsRow()
                    }
                }
                Section {
                    Toggle(isOn: $weekendOnly) { Text("週末（土日祝）の前夜だけ").font(DS.Font.label).foregroundStyle(DS.Color.textPrimary) }
                        .tint(DS.Color.accent).settingsRow()
                        .onChange(of: weekendOnly) { _, v in NotificationSettings.briefWeekendOnly = v }
                    Toggle(isOn: $registeredOnly) { Text("登録した釣り場を見ているときだけ").font(DS.Font.label).foregroundStyle(DS.Color.textPrimary) }
                        .tint(DS.Color.accent).settingsRow()
                        .onChange(of: registeredOnly) { _, v in NotificationSettings.briefRegisteredOnly = v }
                } header: { SectionLabel(text: "明日のベストタイムの条件") }
                Section {
                    Toggle(isOn: $homeTimeOn) { Text("帰る時間を知らせる").font(DS.Font.label).foregroundStyle(DS.Color.textPrimary) }
                        .tint(DS.Color.accent).settingsRow()
                        .onChange(of: homeTimeOn) { _, on in NotificationSettings.homeTimeMinutes = on ? minutes(of: homeTime) : nil }
                    if homeTimeOn {
                        DatePicker("帰る時間", selection: $homeTime, displayedComponents: .hourAndMinute)
                            .font(DS.Font.label).foregroundStyle(DS.Color.textPrimary).tint(DS.Color.accent).settingsRow()
                            .onChange(of: homeTime) { _, d in NotificationSettings.homeTimeMinutes = minutes(of: d) }
                    }
                    Text("釣行中だけ鳴ります。日の入り 30 分前と満潮 1 時間前は自動").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).settingsRow()
                } header: { SectionLabel(text: "安全") }
            }
            .listStyle(.plain)
        }
        .onAppear {
            if let m = NotificationSettings.homeTimeMinutes, let d = Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) { homeTime = d }
            else if let d = Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: Date()) { homeTime = d }
        }
        .task { await SessionNotifications.requestAuthorization() }
    }

    private func minutes(of date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}

// MARK: - 判定

struct JudgementSettingsView: View {
    @Environment(AppServices.self) private var services
    @State private var accuracy: SessionReview.Accuracy?

    var body: some View {
        SettingsPage(title: "判定") {
            List {
                // 釣れ率の精度（F-42）：高いときと低いときの 1 時間あたりの釣果
                Section {
                    if let a = accuracy, a.sessions > 0 {
                        HStack {
                            Text("釣れ率 70 以上のとき").font(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                            Spacer()
                            Text(a.catchesPerHourHigh.map { String(format: "%.2f 尾/時", $0) } ?? "—").font(DS.Font.number(16)).foregroundStyle(DS.Color.accent)
                        }
                        .settingsRow()
                        HStack {
                            Text("70 未満のとき").font(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                            Spacer()
                            Text(a.catchesPerHourLow.map { String(format: "%.2f 尾/時", $0) } ?? "—").font(DS.Font.number(16)).foregroundStyle(DS.Color.textSecondary)
                        }
                        .settingsRow()
                        Text(a.ratio.map { String(format: "%d 釣行・%d 尾。高いときは低いときの %.1f 倍", a.sessions, a.catchesHigh + a.catchesLow, $0) }
                             ?? "\(a.sessions) 釣行・\(a.catchesHigh + a.catchesLow) 尾。比較にはどちらの時間帯の釣果も要ります")
                            .font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).settingsRow()
                    } else {
                        Text(accuracy == nil ? "計算中" : "終わった釣行がまだありません").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).settingsRow()
                    }
                } header: { SectionLabel(text: "釣れ率の精度（全釣行の答え合わせ）") }

                HStack {
                    Text("魚種判定モデル").font(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                    Spacer()
                    Text(CoreMLSpeciesClassifier.modelVersion).font(DS.Font.number(16)).foregroundStyle(DS.Color.textSecondary)
                }
                .settingsRow()
                HStack {
                    Text("修正履歴").font(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                    Spacer()
                    Text("\(CoreMLSpeciesClassifier.loadCorrections().correctionCount) 件").font(DS.Font.number(16)).foregroundStyle(DS.Color.textSecondary)
                }
                .settingsRow()
                Text("修正は候補の並び順に反映されます。判定の学習は写真を集めてから（scripts/train_classifier）。")
                    .font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).settingsRow()
            }
            .listStyle(.plain)
        }
        .task { accuracy = Perf.measure("釣れ率の精度の集計") { SessionReviewer.accuracy(services: services) } }
    }
}

// MARK: - 診断（処理時間と固まりの記録）

struct DiagnosticsView: View {
    @State private var entries: [Perf.Entry] = []
    @State private var copied = false

    var body: some View {
        SettingsPage(title: "診断") {
            List {
                Section {
                    HStack {
                        Button {
                            UIPasteboard.general.string = Perf.report
                            copied = true
                        } label: { Label(copied ? "コピーしました" : "記録をコピー", systemImage: "doc.on.doc").font(DS.Font.label).foregroundStyle(DS.Color.accent) }
                        .buttonStyle(.plain)
                        Spacer()
                        Button(role: .destructive) { Perf.clear(); entries = [] } label: { Text("消去").font(DS.Font.caption).foregroundStyle(DS.Color.holiday) }
                            .buttonStyle(.plain)
                    }
                    .settingsRow()
                    Text("■ はメインスレッドが 400 ms 以上止まった記録（直前にしていた操作つき）、⏱ は 50 ms を超えた処理、✖ は前回の起動が正常に終わらなかった印。固まる・落ちるときは、ここをコピーして知らせてください")
                        .font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).settingsRow()
                } header: { SectionLabel(text: "処理時間と固まり（新しい順・最大 300 件）") }
                Section {
                    ForEach(entries) { e in
                        Text(e.line).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(e.kind == .stall || e.kind == .crash ? DS.Color.holiday : (e.kind == .slow ? DS.Color.sun : DS.Color.textSecondary))
                            .settingsRow()
                    }
                    if entries.isEmpty { Text("記録はまだありません").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).settingsRow() }
                }
            }
            .listStyle(.plain)
        }
        .onAppear { entries = Perf.recent(120) }
    }
}

// MARK: - 自動検出

struct DetectionSettingsView: View {
    @Environment(AppServices.self) private var services
    @State private var sensitivity: DetectionSettings.Sensitivity = SessionDetectionService.sensitivity
    @State private var autoEnabled: Bool = SessionDetectionService.autoDetectionEnabled

    var body: some View {
        SettingsPage(title: "自動検出") {
            List {
                Section {
                    Toggle(isOn: $autoEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("位置情報で自動開始・終了").font(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                            Text(autoEnabled ? "常に位置を監視します（電池を使います）" : "オフ：釣行はホームの「開始」「終了」か撮影で記録します。位置は記録中と地図・撮影を開いている間だけ使います")
                                .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                        }
                    }
                    .tint(DS.Color.accent)
                    .settingsRow()
                    .onChange(of: autoEnabled) { _, on in services.detection.applyAutoDetection(on) }
                    Text("忘れて終え損ねた釣行は、最後の動き（開始・釣果・針）から 8 時間たつと自動で終わります")
                        .font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).settingsRow()
                } header: { SectionLabel(text: "釣行の記録") }

                if autoEnabled {
                    Section {
                        Picker("感度", selection: $sensitivity) {
                            ForEach(DetectionSettings.Sensitivity.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .settingsRow()
                        .onChange(of: sensitivity) { _, s in services.detection.applySensitivity(s) }

                        let s = DetectionSettings.forSensitivity(sensitivity)
                        detailRow("開始", "同じ場所に \(Int(s.dwellToStart / 60)) 分とどまる")
                        detailRow("終了", "\(Int(s.awayDistanceM)) m 離れて \(Int(s.awayToEnd / 60)) 分、または車で \(Int(s.drivingToEnd / 60)) 分")
                        detailRow("ランガン", "\(Int(s.runAndGunMaxGap / 60)) 分・\(Int(s.runAndGunMaxDistanceM / 1000)) km 以内は同じ釣行")
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("除外した場所").font(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                                Text("破棄・削除した釣行の場所から 400 m 以内では自動で始めない：\(excludedCount) 件").font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                            }
                            Spacer()
                            if excludedCount > 0 {
                                Button("消去") { SessionDetectionService.clearExclusions(); excludedCount = 0 }.font(DS.Font.caption).foregroundStyle(DS.Color.accent)
                            }
                        }
                        .settingsRow()
                    } header: { SectionLabel(text: "自動検出の感度") }
                }
            }
            .listStyle(.plain)
        }
        .onAppear { excludedCount = SessionDetectionService.excludedMeshes.count }
    }

    @State private var excludedCount = 0

    private func detailRow(_ title: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(DS.Font.label).foregroundStyle(DS.Color.textPrimary).frame(width: 64, alignment: .leading)
            Text(text).font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
        }
        .settingsRow()
    }
}

// MARK: - 釣り人（F-54）

struct AnglerSettingsView: View {
    @Environment(AppServices.self) private var services
    @State private var ownName = AnglerSettings.ownName
    @State private var members = AnglerSettings.members
    @State private var newMember = ""
    @State private var sharing = PartyService.isEnabled
    @State private var syncing = false

    var body: some View {
        SettingsPage(title: "釣り人") {
            List {
                Section {
                    HStack {
                        Text("自分").font(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                        Spacer()
                        TextField("名前", text: $ownName).multilineTextAlignment(.trailing).font(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                            .onSubmit { AnglerSettings.ownName = ownName; ownName = AnglerSettings.ownName }
                    }
                    .settingsRow()
                    ForEach(members, id: \.self) { m in
                        Text(m).font(DS.Font.label).foregroundStyle(DS.Color.textPrimary).settingsRow()
                    }
                    .onDelete { idx in idx.map { members[$0] }.forEach { AnglerSettings.remove(member: $0) }; members = AnglerSettings.members }
                    HStack {
                        TextField("いっしょに釣る人の名前", text: $newMember).font(DS.Font.label)
                        Button("追加") { AnglerSettings.add(member: newMember); members = AnglerSettings.members; newMember = "" }
                            .font(DS.Font.label).foregroundStyle(DS.Color.accent)
                            .disabled(newMember.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .settingsRow()
                    Text("撮影画面の上の名前をタップして、誰の魚かを選びます。他の人の魚は図鑑・自己記録・釣れ率の学習には入れず、釣行の尾数と共有にだけ入ります")
                        .font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).settingsRow()
                } header: { SectionLabel(text: "名前") }

                Section {
                    Toggle(isOn: $sharing) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("仲間と釣果を共有").font(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                            Text("魚種・サイズ・時刻・場所・釣った人・サムネイルを iCloud（このアプリの公開データベース）に置き、相手の端末の「釣果情報」と地図に出ます。写真本体は送りません")
                                .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                        }
                    }
                    .tint(DS.Color.accent)
                    .settingsRow()
                    .onChange(of: sharing) { _, on in
                        PartyService.isEnabled = on
                        if on { Task { await services.party.syncIfNeeded(store: services.store, force: true) } }
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("仲間の釣果 \(services.party.others.count) 件").font(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                            Text(services.party.lastError ?? services.party.lastSyncAt.map { "最終同期 " + $0.formatted(.dateTime.month().day().hour().minute()) } ?? "まだ同期していません")
                                .font(DS.Font.caption).foregroundStyle(services.party.lastError == nil ? DS.Color.textTertiary : DS.Color.holiday)
                        }
                        Spacer()
                        Button {
                            syncing = true
                            Task { await services.party.syncIfNeeded(store: services.store, force: true); syncing = false }
                        } label: { Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.Color.accent) }
                        .buttonStyle(.plain)
                        .disabled(syncing || !services.party.isAvailable)
                    }
                    .settingsRow()
                    if !services.party.isAvailable, sharing {
                        Text("iCloud のコンテナが設定されていないため共有できません").font(DS.Font.caption).foregroundStyle(DS.Color.holiday).settingsRow()
                    }
                } header: { SectionLabel(text: "共有（2 台の iPhone の間）") }
            }
            .listStyle(.plain)
        }
        .onDisappear { AnglerSettings.ownName = ownName }
    }
}

// MARK: - 情報源

struct SourcesSettingsView: View {
    @Environment(AppServices.self) private var services
    @State private var weatherAttribution: (serviceName: String, legalURL: URL)?
    @State private var newFeedURL = ""
    @State private var editingFeed: String?
    @State private var editingFilter = ""

    var body: some View {
        SettingsPage(title: "情報源") {
            List {
                Section {
                    Link(destination: EnvironmentService.openMeteoCredit.url) {
                        HStack {
                            Text(EnvironmentService.openMeteoCredit.text).font(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                            Spacer()
                            Image(systemName: "arrow.up.right").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                        }
                    }
                    .settingsRow()
                    if let a = weatherAttribution {
                        Link(destination: a.legalURL) {
                            HStack {
                                Text(a.serviceName).font(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                                Spacer()
                                Image(systemName: "arrow.up.right").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                            }
                        }
                        .settingsRow()
                    }
                    Text("潮汐: 気象庁 潮位表（分潮）").font(DS.Font.label).foregroundStyle(DS.Color.textPrimary).settingsRow()
                    Link(destination: URL(string: "https://nlftp.mlit.go.jp/ksj/")!) {
                        HStack {
                            Text("漁港・港湾: 国土数値情報（国土交通省）").font(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                            Spacer()
                            Image(systemName: "arrow.up.right").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                        }
                    }
                    .settingsRow()
                } header: { SectionLabel(text: "海況・潮汐・港") }
                Section {
                    ForEach(services.feeds.urls, id: \.self) { u in
                        Button { editingFeed = u; editingFilter = services.feeds.filters[u] ?? "" } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: DS.Spacing.s) {
                                    Text(services.feeds.feedTitles[u] ?? "取得待ち").font(DS.Font.label).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                                    if let k = services.feeds.kinds[u] {
                                        Text(k == "rss" ? "RSS" : "リンク一覧").font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.Color.textTertiary)
                                            .padding(.horizontal, 5).padding(.vertical, 1).background(DS.Color.surfaceRaised, in: Capsule())
                                    }
                                }
                                Text(u).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).lineLimit(1)
                                if let f = services.feeds.filters[u] { Text("条件: \(f)").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary) }
                            }
                        }
                        .buttonStyle(.plain)
                        .settingsRow()
                    }
                    .onDelete { idx in idx.map { services.feeds.urls[$0] }.forEach { services.feeds.remove(url: $0) } }
                    HStack {
                        TextField("サイトか RSS の URL（https://…）", text: $newFeedURL).font(DS.Font.label).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("追加") { services.feeds.add(url: newFeedURL); newFeedURL = "" }.font(DS.Font.label).foregroundStyle(DS.Color.accent)
                            .disabled(URL(string: newFeedURL)?.scheme?.hasPrefix("http") != true)
                    }
                    .settingsRow()
                    if let e = services.feeds.lastError {
                        Text(e).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).settingsRow()
                    }
                    Text("RSS でもサイトの URL でも登録できます。RSS が無いサイトはページのリンク一覧を記事として読みます（行をタップで「記事リンクの条件」を設定。例: /report/）。取得は 1 時間に 1 回。記事の本文は読みに行きません").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).settingsRow()
                } header: { SectionLabel(text: "釣果情報（RSS・サイト）") }
            }
            .listStyle(.plain)
        }
        .task { weatherAttribution = await WeatherKitProvider.attribution() }
        .alert("記事リンクの条件", isPresented: Binding(get: { editingFeed != nil }, set: { if !$0 { editingFeed = nil } })) {
            TextField("例: /report/（空なら全部）", text: $editingFilter)
            Button("保存") { if let u = editingFeed { services.feeds.setFilter(url: u, filter: editingFilter) }; editingFeed = nil }
            Button("キャンセル", role: .cancel) { editingFeed = nil }
        } message: { Text("RSS の無いサイトで、URL にこの文字を含むリンクだけを記事にします") }
    }
}

// MARK: - テーマ（F-49）

struct ThemeSettingsView: View {
    @State private var theme: AppTheme = ThemeStore.shared.theme

    var body: some View {
        SettingsPage(title: "テーマ") {
            List {
                Section {
                    Picker("テーマ", selection: $theme) {
                        ForEach(AppTheme.all) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .settingsRow()
                    Text("切り替えると全画面に反映されます。魔導書は画像が無くても色と書体だけで動きます")
                        .font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).settingsRow()
                } header: { SectionLabel(text: "見た目") }
                if theme.hasAssets {
                    Section {
                        ForEach(ThemeAssets.Name.allCases, id: \.rawValue) { name in
                            HStack(spacing: DS.Spacing.s) {
                                Image(systemName: ThemeAssets.exists(name, theme: theme) ? "checkmark.circle.fill" : "circle.dashed")
                                    .foregroundStyle(ThemeAssets.exists(name, theme: theme) ? DS.Color.secondary : DS.Color.textTertiary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(name.rawValue).font(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                                    Text(name.note).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                                }
                                Spacer()
                            }
                            .settingsRow()
                        }
                        Text("App/Resources/Themes/\(theme.assetFolder)/ に PNG か JPG で置くと次のビルドから使われます")
                            .font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).settingsRow()
                        Text(ThemeAssets.diagnostics(for: theme))
                            .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary).settingsRow()
                    } header: { SectionLabel(text: "画像（\(ThemeAssets.Name.allCases.filter { ThemeAssets.exists($0, theme: theme) }.count)/\(ThemeAssets.Name.allCases.count)）") }
                    let characters = ThemeAssets.Name.allCases.filter { $0.isCharacter && ThemeAssets.exists($0, theme: theme) }
                    if !characters.isEmpty {
                        Section {
                            ForEach(characters, id: \.rawValue) { name in
                                CharacterTuningRow(name: name).settingsRow()
                            }
                        } header: { SectionLabel(text: "キャラクターの位置（画面を見ながら調整。閉じると反映）") }
                    }
                }
            }
            .listStyle(.plain)
        }
        .onChange(of: theme) { _, t in ThemeStore.shared.theme = t }
    }
}

/// キャラクターの倍率と位置ずらし
private struct CharacterTuningRow: View {
    let name: ThemeAssets.Name
    @State private var scale: Double = 1
    @State private var dx: Double = 0
    @State private var dy: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack {
                Text(name.rawValue).font(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                Spacer()
                Button("戻す") { scale = 1; dx = 0; dy = 0; save() }.font(DS.Font.caption).foregroundStyle(DS.Color.accent)
            }
            slider("大きさ", $scale, 0.4...2.5)
            slider("横", $dx, -200...200)
            slider("縦", $dy, -200...200)
        }
        .onAppear { scale = ThemeAssets.scale(name); dx = ThemeAssets.offset(name).width; dy = ThemeAssets.offset(name).height }
    }

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack(spacing: DS.Spacing.s) {
            Text(label).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).frame(width: 36, alignment: .leading)
            Slider(value: value, in: range).tint(DS.Color.accent).onChange(of: value.wrappedValue) { _, _ in save() }
            Text(label == "大きさ" ? String(format: "%.2f", value.wrappedValue) : "\(Int(value.wrappedValue))")
                .font(DS.Font.number(11)).foregroundStyle(DS.Color.textSecondary).frame(width: 36, alignment: .trailing)
        }
    }

    private func save() {
        ThemeAssets.setScale(name, scale)
        ThemeAssets.setOffset(name, CGSize(width: dx, height: dy))
        ThemeLayoutTuning.shared.revision += 1
    }
}
