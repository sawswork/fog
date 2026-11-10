import SwiftUI
import Core

/// 相談役（F-53）：アプリの記録について聞く／店先の話を声で記録して地図のメモにする。
struct AssistantView: View {
    let home: HomeViewModel
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var recorder = SpeechRecorder()
    @State private var working = false

    var body: some View {
        let assistant = services.assistant
        VStack(spacing: DS.Spacing.m) {
            Color.clear.frame(height: 0).onAppear { Perf.mark("相談を開いた") }
            HStack {
                Text("相談").font(DS.Font.number(20)).foregroundStyle(DS.Color.textPrimary)
                Spacer()
                Button { assistant.clear() } label: { Image(systemName: "trash").foregroundStyle(DS.Color.textTertiary) }.buttonStyle(.plain)
                Button { dismiss() } label: { Image(systemName: "xmark").foregroundStyle(DS.Color.textSecondary) }.buttonStyle(.plain).padding(.leading, DS.Spacing.m)
            }
            if let reason = assistant.unavailableReason {
                Text(reason).font(DS.Font.caption).foregroundStyle(DS.Color.holiday)
            }
            ScrollViewReader { reader in
                ScrollView {
                    VStack(spacing: DS.Spacing.s) {
                        if assistant.messages.isEmpty {
                            Text("文字か声で、質問も記録もそのまま。\n質問の例：明日の鹿部はどう？／先月の釣果は？\n記録の例：鹿部で先週ホッケが好調らしい（店の人の話をそのまま話してもよい）。場所ごとに整理して地図にメモを置きます")
                                .font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(assistant.messages) { m in
                            HStack {
                                if m.role == .user { Spacer(minLength: 40) }
                                Text(m.text).font(DS.Font.label)
                                    .foregroundStyle(m.role == .user ? DS.Color.background : DS.Color.textPrimary)
                                    .padding(DS.Spacing.m)
                                    .background(m.role == .user ? DS.Color.accent : DS.Color.surface, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)).themeOutline(DS.Radius.chip)
                                if m.role == .assistant { Spacer(minLength: 40) }
                            }
                            .id(m.id)
                        }
                        if assistant.isResponding || working {
                            HStack { ProgressView().tint(DS.Color.accent); Text(working ? "整理しています" : "考えています").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary); Spacer() }
                        }
                    }
                }
                .onChange(of: assistant.messages.count) { _, _ in
                    if let last = assistant.messages.last { withAnimation { reader.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            if recorder.isRecording {
                Text(recorder.transcript.isEmpty ? "聞いています…" : recorder.transcript).font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading).lineLimit(3)
            }
            if let e = recorder.error { Text(e).font(DS.Font.caption).foregroundStyle(DS.Color.holiday) }
            HStack(spacing: DS.Spacing.s) {
                TextField("質問、または記録したい話", text: $input, axis: .vertical)
                    .lineLimit(1...4)
                    .font(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                    .padding(DS.Spacing.m).background(DS.Color.surface, in: RoundedRectangle(cornerRadius: DS.Radius.chip)).themeOutline(DS.Radius.chip)
                    .onSubmit { submit(input) }
                Button { toggleRecording() } label: {
                    Image(systemName: recorder.isRecording ? "stop.circle.fill" : "mic.circle.fill").font(.system(size: 34))
                        .foregroundStyle(recorder.isRecording ? DS.Color.holiday : DS.Color.accent)
                }
                .buttonStyle(.plain)
                Button { submit(input) } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 34)).foregroundStyle(input.isEmpty ? DS.Color.textTertiary : DS.Color.accent)
                }
                .buttonStyle(.plain)
                .disabled(input.isEmpty || assistant.isResponding || working)
            }
        }
        .padding(DS.Spacing.l)
        .background(ThemeBackground(name: .bgDetail))
        .onDisappear { if recorder.isRecording { recorder.stop() } }
    }

    private func toggleRecording() {
        if recorder.isRecording {
            recorder.stop()
            let text = recorder.transcript
            if !text.isEmpty { submit(text) }
        } else {
            Task { await recorder.start() }
        }
    }

    private func submit(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        input = ""
        let assistant = services.assistant
        working = true
        Task {
            // 質問か記録かは内容から判定する（タブは無い）
            let intent = await assistant.classify(t)
            if intent == .question {
                let context = await AssistantContext.build(services: services, home: home, question: t)
                working = false
                await assistant.ask(t, context: context)
                return
            }
            assistant.append(user: t)
            do {
                let spots = ((try? services.store.spots()) ?? []).filter(\.isRegistered).map(\.name)
                let items = await assistant.organizeShopTalk(t, hintPlaces: spots)
                var made: [String] = []
                for item in items {
                    let resolved = NoteResolver.resolve(place: item.place, services: services, fallback: home.coordinate)
                    var text = item.summary
                    if !item.species.isEmpty { text += "（\(item.species.joined(separator: "・"))）" }
                    let note = Core.Note(coordinate: resolved.coordinate, text: text, placeName: resolved.name, source: .voice)
                    try? services.store.upsert(note)
                    made.append("・\(resolved.name ?? "現在地")：\(item.summary)")
                }
                assistant.append(assistant: made.isEmpty ? "メモにできる内容がありませんでした" : "地図にメモを置きました\n" + made.joined(separator: "\n"))
                working = false
            }
        }
    }
}

/// 話に出た場所の名前を座標に直す（F-53）：登録釣り場 → 同梱の港データ（よみでも当たる）→ 現在地
@MainActor
enum NoteResolver {
    static func resolve(place: String, services: AppServices, fallback: Coordinate) -> (coordinate: Coordinate, name: String?) {
        let p = place.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else {
            let c = services.location.lastFix?.coordinate ?? fallback
            return (c, nil)
        }
        let spots = ((try? services.store.spots()) ?? []).filter { $0.coordinate.isPlausible }
        if let spot = spots.first(where: { $0.name == p }) ?? spots.first(where: { $0.name.contains(p) || p.contains($0.name) }) {
            return (spot.coordinate, spot.name)
        }
        PortReadingIndex.shared.prepare(catalog: PortCatalog.bundled())
        if let port = PortReadingIndex.shared.search(p, limit: 1).first ?? PortCatalog.bundled().ports.first(where: { $0.name.contains(p) }) {
            return (port.coordinate, port.name)
        }
        let c = services.location.lastFix?.coordinate ?? fallback
        return (c, p)
    }
}
