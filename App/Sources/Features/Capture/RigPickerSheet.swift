import SwiftUI
import Core

/// リグの部品の登録（フックの大きさ・シンカーの重さ・ワーム）を置く場所。端末内（UserDefaults）。
/// SwiftData の表を増やさない：表を増やすと iCloud の本番スキーマの更新（開発者の作業）が要るため
enum RigPartsStore {
    static let key = "fog.rigParts"
    /// 撮影画面で「どれも なし」にしたことを覚える鍵（次に開いたとき、勝手に先頭のリグを選ばない）
    static let clearedKey = "fog.rigCleared"

    static func load() -> RigParts {
        guard let data = UserDefaults.standard.data(forKey: key), let parts = try? JSONDecoder().decode(RigParts.self, from: data) else { return .standard }
        return parts
    }

    static func save(_ parts: RigParts) {
        if let data = try? JSONEncoder().encode(parts) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// 撮影画面のリグの選択（F-14 の例外的入力）。フック・シンカー・ワームを、登録してあるものからタップで選ぶ。文字は打たない。
/// 閉じたときに、選んだ組み合わせを返す（同じ組み合わせのリグがあればそれ、無ければ新しく作るのは呼び出し側）
struct RigPickerSheet: View {
    /// これまでに使った組み合わせ
    let rigs: [Rig]
    let current: Rig?
    /// 選び直したときだけ呼ぶ：フック・シンカー（g）・ワームの名前。どれも nil ならリグなし
    let onCommit: (String?, Double?, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var parts = RigPartsStore.load()
    @State private var hook: String?
    @State private var sinker: Double?
    @State private var worm: String?
    @State private var initial: Selection?
    @State private var adding: RigPartAddRow.Kind?

    private struct Selection: Equatable { var hook: String?; var sinker: Double?; var worm: String? }
    private let columns = [GridItem(.adaptive(minimum: 62), spacing: 8)]

    /// 登録に無い値（以前のリグのもの）も、選択中なら並べる
    private var hookOptions: [String] { parts.hooks + (hook.map { parts.hooks.contains($0) ? [] : [$0] } ?? []) }
    private var sinkerOptions: [Double] {
        (parts.sinkers + (sinker.map { s in parts.sinkers.contains { abs($0 - s) < 0.05 } ? [] : [s] } ?? [])).sorted()
    }
    private var extraWorm: String? { worm.flatMap { label in parts.worms.contains { $0.label == label } ? nil : label } }

    private var summary: String {
        Rig.resolve(hook: hook, sinkerGrams: sinker, worm: worm, in: [])?.rig.displayName ?? "リグなし"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                Text("リグ").font(.system(size: 20, weight: .bold)).foregroundStyle(DS.Color.textPrimary)
                Text(summary).font(DS.Font.label).foregroundStyle(DS.Color.accent).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: DS.Spacing.s)
                Button("決定") { dismiss() }.font(.system(size: 16, weight: .semibold)).foregroundStyle(DS.Color.accent)
            }
            .padding(.horizontal, DS.Spacing.l).padding(.top, DS.Spacing.l).padding(.bottom, DS.Spacing.s)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    section("フック", "大きさ", kind: .hook) {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                            chip("なし", selected: hook == nil) { hook = nil }
                            ForEach(hookOptions, id: \.self) { h in
                                chip("#" + h, selected: hook == h) { hook = h }
                                    .contextMenu { Button("この登録を消す", role: .destructive) { parts.removeHook(h); if hook == h { hook = nil }; RigPartsStore.save(parts) } }
                            }
                        }
                    }
                    section("シンカー", "重さ", kind: .sinker) {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                            chip("なし", selected: sinker == nil) { sinker = nil }
                            ForEach(sinkerOptions, id: \.self) { g in
                                chip(RigParts.gramsText(g) + "g", selected: sinker.map { abs($0 - g) < 0.05 } ?? false) { sinker = g }
                                    .contextMenu { Button("この登録を消す", role: .destructive) { parts.removeSinker(g); if sinker == g { sinker = nil }; RigPartsStore.save(parts) } }
                            }
                        }
                    }
                    section("ワーム", "メーカー・サイズ・色", kind: .worm) {
                        VStack(spacing: 8) {
                            wormRow(title: "なし", detail: "", selected: worm == nil) { worm = nil }
                            ForEach(parts.worms) { w in
                                wormRow(title: w.maker.isEmpty ? w.label : w.maker, detail: w.maker.isEmpty ? "" : [w.size, w.color].filter { !$0.isEmpty }.joined(separator: " · "),
                                        selected: worm == w.label) { worm = w.label }
                                    .contextMenu { Button("この登録を消す", role: .destructive) { parts.removeWorm(id: w.id); if worm == w.label { worm = nil }; RigPartsStore.save(parts) } }
                            }
                            if let extra = extraWorm { wormRow(title: extra, detail: "登録に無いワーム", selected: true) {} }
                            if parts.worms.isEmpty, adding != .worm {
                                Text("「＋ 追加」でワームを登録すると、次からここで選べます").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    if !rigs.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("これまでの組み合わせ").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.textSecondary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(rigs.suffix(12).reversed()) { r in
                                        Button { apply(r) } label: {
                                            Text(r.displayName).font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                                                .padding(.horizontal, 12).frame(height: 34)
                                                .background(DS.Color.surface, in: Capsule())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, DS.Spacing.l).padding(.bottom, DS.Spacing.l).padding(.top, DS.Spacing.xs)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DS.Color.background)
        .onAppear {
            guard initial == nil else { return }
            if let current, !current.isEmpty { apply(current) }
            initial = Selection(hook: hook, sinker: sinker, worm: worm)
        }
        .onDisappear {
            // 選び直したときだけ伝える（開いて閉じただけでは何も変えない）
            let now = Selection(hook: hook, sinker: sinker, worm: worm)
            if let initial, initial != now { onCommit(hook, sinker, worm) }
        }
    }

    /// そのリグの部品を選んだ状態にする
    private func apply(_ rig: Rig) {
        let h = RigParts.normalizeHook(rig.hookSize)
        hook = h.isEmpty ? nil : h
        sinker = rig.sinkerGrams > 0 ? rig.sinkerGrams : nil
        worm = rig.worm.isEmpty ? nil : rig.worm
    }

    // MARK: 部品

    private func section<Content: View>(_ title: String, _ hint: String, kind: RigPartAddRow.Kind, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 16, weight: .bold)).foregroundStyle(DS.Color.textPrimary)
                Text(hint).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                Spacer()
                Button { withAnimation(.easeOut(duration: 0.15)) { adding = adding == kind ? nil : kind } } label: {
                    Label(adding == kind ? "閉じる" : "追加", systemImage: adding == kind ? "xmark" : "plus")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.accent)
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(DS.Color.accent.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            if adding == kind {
                RigPartAddRow(kind: kind) { a, b, c in add(kind, a, b, c) }
            }
            content()
        }
    }

    /// 登録に足して、そのまま選ぶ
    private func add(_ kind: RigPartAddRow.Kind, _ a: String, _ b: String, _ c: String) -> Bool {
        var ok = false
        switch kind {
        case .hook:
            ok = parts.addHook(a)
            let h = RigParts.normalizeHook(a)
            if !h.isEmpty, parts.hooks.contains(h) { hook = h; ok = true }
        case .sinker:
            ok = parts.addSinker(a)
            if let g = RigParts.parseGrams(a) { sinker = g; ok = true }
        case .worm:
            if let made = parts.addWorm(maker: a, size: b, color: c) { worm = made.label; ok = true }
            else if let same = parts.worms.first(where: { $0.label == WormPreset(maker: a, size: b, color: c).label }) { worm = same.label; ok = true }
        }
        if ok { RigPartsStore.save(parts) }
        return ok
    }

    private func chip(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.system(size: 15, weight: .semibold)).foregroundStyle(selected ? DS.Color.background : DS.Color.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity).frame(height: 42)
                .background(selected ? DS.Color.accent : DS.Color.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func wormRow(title: String, detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 13, weight: .regular)).foregroundStyle(DS.Color.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(selected ? DS.Color.accent : DS.Color.textTertiary)
            }
            .padding(.horizontal, 14).frame(height: 46)
            .background(DS.Color.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? DS.Color.accent : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 部品を 1 つ登録する入力の行。撮影画面のシートと 設定 > タックル の両方で使う。
/// 「追加」は、入力欄からフォーカスを外して日本語入力の変換を確定させてから読む（変換中の文字を取りこぼさない）
struct RigPartAddRow: View {
    enum Kind { case hook, sinker, worm }
    let kind: Kind
    /// 入力（フック・シンカーは 1 つめだけ使う）。足せたら true
    let onAdd: (String, String, String) -> Bool

    @State private var a = ""
    @State private var b = ""
    @State private var c = ""
    @State private var failed = false
    @FocusState private var focus: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                switch kind {
                case .hook:
                    field("大きさ（例 1/0）", $a, 0)
                case .sinker:
                    field("重さ（例 14）", $a, 0).keyboardType(.decimalPad)
                    Text("g").font(DS.Font.label).foregroundStyle(DS.Color.textTertiary)
                case .worm:
                    field("メーカー", $a, 0)
                    field("サイズ", $b, 1)
                    field("色", $c, 2)
                }
                Button("追加") { commit() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.Color.accent)
            }
            if failed {
                Text(kind == .sinker ? "重さを数字で入れてください（例 14、3.5）" : "入力が空です").font(DS.Font.caption).foregroundStyle(DS.Color.holiday)
            }
        }
    }

    private func field(_ placeholder: String, _ text: Binding<String>, _ index: Int) -> some View {
        TextField(placeholder, text: text)
            .font(.system(size: 15))
            .foregroundStyle(DS.Color.textPrimary)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .focused($focus, equals: index)
            .submitLabel(kind == .worm && index < 2 ? .next : .done)
            .onSubmit { if kind == .worm, index < 2 { focus = index + 1 } else { commit() } }
            .padding(.horizontal, 10).frame(height: 40)
            .background(DS.Color.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func commit() {
        focus = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            if onAdd(a, b, c) { a = ""; b = ""; c = ""; failed = false } else { failed = true }
        }
    }
}
