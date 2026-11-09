import SwiftUI
import ARKit
import Core

/// 撮影（§5）。全画面カメラ、中央の計測枠、タックル／リグのチップ、シャッター、結果シート。L10 で仕上げる。
struct CaptureView: View {
    @Environment(AppServices.self) private var services
    @State private var model = CaptureViewModel()
    @State private var showRigPicker = false
    @State private var showHookMenu = false
    @State private var showAnglerPicker = false
    @State private var toast: String?

    var body: some View {
        ZStack {
            // LiDAR の無い端末（iPhone 17 など）でもカメラは動く。サイズだけ未計測で記録する（F-12）
            if ARWorldTrackingConfiguration.isSupported {
                ARPreview(session: model.depth.session).ignoresSafeArea()
            } else {
                DS.Color.background.ignoresSafeArea()
                Text("カメラを使えません").font(DS.Font.label).foregroundStyle(DS.Color.textTertiary)
            }
            if model.measuresLength {
                MeasureFrame(status: model.status, lengthCm: model.liveLengthCm, endpoints: model.endpoints)
            }
            VStack {
                header
                Spacer()
                controls
            }
            if let result = model.result {
                ResultSheet(outcome: result, onChoose: { model.choose(species: $0) }, onDismiss: { model.dismissResult() })
                    .transition(.move(edge: .bottom))
            }
            if let toast {
                VStack { Spacer(); Text(toast).font(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                    .padding(.horizontal, DS.Spacing.l).padding(.vertical, DS.Spacing.s)
                    .background(DS.Color.surface.opacity(0.95), in: Capsule()).padding(.bottom, 200) }
                    .transition(.opacity)
                    .task { try? await Task.sleep(nanoseconds: 1_200_000_000); self.toast = nil }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.result?.catchRecord.id)
        .onAppear { model.attach(services: services); model.start() }
        .onDisappear { model.stop() }
        .sheet(isPresented: $showRigPicker) { rigPicker }
        .confirmationDialog("釣った人", isPresented: $showAnglerPicker, titleVisibility: .visible) {
            ForEach(model.anglerCandidates, id: \.self) { name in
                Button(name == model.angler ? "✓ \(name)" : name) { model.select(angler: name) }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("候補は 設定 > 釣り人 で増やせます")
        }
    }

    /// 上部：中央に「釣り場名 · 時刻」とその下に釣った人（F-54）。右にフラッシュ（夜釣り用、小さく）
    private var header: some View {
        ZStack {
            VStack(spacing: 4) {
                Text("\(model.spotName.isEmpty ? "釣り場" : model.spotName) · \(Date.now.formatted(.dateTime.hour().minute()))")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(Color.white.opacity(0.75))
                    .shadow(color: .black.opacity(0.5), radius: 3)
                Button { showAnglerPicker = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "person.fill").font(.system(size: 10, weight: .semibold))
                        Text(model.angler).font(.system(size: 13, weight: .semibold))
                        if model.anglerCandidates.count > 1 { Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)) }
                    }
                    .foregroundStyle(model.angler == AnglerSettings.ownName ? Color.white.opacity(0.85) : DS.Color.sun)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.black.opacity(0.55), in: Capsule())
                }
                .buttonStyle(.plain)
                if !model.measuresLength {
                    Text("サイズ計測なし（LiDAR 非対応）").font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.6))
                }
            }
            HStack {
                Spacer()
                Button { model.toggleTorch() } label: {
                    Image(systemName: model.torchOn ? "bolt.fill" : "bolt.slash").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(model.torchOn ? DS.Color.accent : Color.white.opacity(0.6)).frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DS.Spacing.m)
        .padding(.top, DS.Spacing.m)
    }

    private var controls: some View {
        HStack(alignment: .center) {
            chip(model.tackle == .spinning ? "スピニング" : "ベイト") { model.toggleTackle() }
            Spacer()
            ZStack {
                Circle().stroke(DS.Color.accent, lineWidth: 3).frame(width: 86, height: 86)
                Circle().fill(DS.Color.accent).frame(width: 70, height: 70)
                    .shadow(color: DS.Color.accent.opacity(0.6), radius: 16)
                    .opacity(model.isSaving ? 0.5 : 1)
            }
            .contentShape(Circle())
            .onTapGesture { Task { await model.shutter() } }
            .onLongPressGesture(minimumDuration: 0.5) { showHookMenu = true }
            .accessibilityLabel("撮影")
            .confirmationDialog("針", isPresented: $showHookMenu, titleVisibility: .hidden) {
                Button("針ロスト") { services.hookRecorder.record(.lost); toast = "針ロストを記録" }
                Button("針追加") { services.hookRecorder.record(.added); toast = "針追加を記録" }
                Button("キャンセル", role: .cancel) {}
            }
            Spacer()
            chip(model.rig?.displayName ?? "リグ") { showRigPicker = true }
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.bottom, DS.Spacing.l)
    }

    private func chip(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DS.Color.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.7)
                .padding(.horizontal, DS.Spacing.l)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.78), in: Capsule())
        }
        .buttonStyle(.plain)
        .frame(width: 110)
    }

    private var rigPicker: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            if model.rigs.isEmpty {
                Text("設定でリグを登録すると選べます").font(DS.Font.label).foregroundStyle(DS.Color.textTertiary)
            }
            ForEach(model.rigs) { r in
                Button { model.selectRig(r); showRigPicker = false } label: {
                    HStack {
                        Text(r.displayName).font(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                        Spacer()
                        if model.rig?.id == r.id { Circle().fill(DS.Color.accent).frame(width: 8, height: 8) }
                    }
                    .padding(DS.Spacing.m)
                    .background(DS.Color.surface, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(DS.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DS.Color.background)
        .presentationDetents([.medium])
    }
}

/// ARKit のカメラ映像（ARSCNView の背景だけを使う）。
struct ARPreview: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.automaticallyUpdatesLighting = false
        view.rendersContinuously = true
        view.scene = SCNScene()
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

/// 計測枠：魚を捉えると枠がオレンジになり、全長をライブ表示。遠い・近いはグレーで矢印。
struct MeasureFrame: View {
    let status: FrameStatus
    let lengthCm: Double?
    let endpoints: (CGPoint, CGPoint)?

    var body: some View {
        GeometryReader { geo in
            // 縦長の枠（確定画像）。魚を縦向きに入れて真上から撮る。枠の上に全長を白で大きく
            let w = geo.size.width * 0.80, h = geo.size.height * 0.46
            let color: Color = status == .ok ? DS.Color.accent : Color.white.opacity(0.35)
            VStack(spacing: DS.Spacing.m) {
                Spacer().frame(height: geo.size.height * 0.17)
                Text(lengthCm.map { status == .ok ? "\(Int($0.rounded())) cm" : " " } ?? " ")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 4)
                    .frame(height: 48)
                ZStack {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(color, lineWidth: status == .ok ? 4 : 2.5)
                        .frame(width: w, height: h)
                    if status == .tooFar {
                        Image(systemName: "arrow.down").font(.system(size: 36, weight: .bold)).foregroundStyle(Color.white.opacity(0.5))
                    } else if status == .tooClose {
                        Image(systemName: "arrow.up").font(.system(size: 36, weight: .bold)).foregroundStyle(Color.white.opacity(0.5))
                    }
                }
                Spacer()
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
    }
}

/// 撮影後の結果シート：魚種名、全長、確信度の円弧。記録更新ならオレンジのバッジ。低確信度なら候補 3 種。
struct ResultSheet: View {
    let outcome: CaptureService.Outcome
    let onChoose: (String) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: DS.Spacing.m) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.m) {
                    Text(outcome.catchRecord.species.isEmpty ? "判定中" : outcome.catchRecord.species)
                        .font(DS.Font.number(24)).foregroundStyle(DS.Color.textPrimary)
                    if let l = outcome.catchRecord.lengthCm {
                        Text("\(Int(l.rounded()))cm").font(DS.Font.score(40)).foregroundStyle(DS.Color.accent)
                        if let e = outcome.catchRecord.lengthErrorCm {
                            Text("±\(Int(e.rounded()))").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                        }
                    } else {
                        Text("サイズ未計測").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                    }
                    Spacer()
                    ZStack {
                        Circle().stroke(DS.Color.faded, lineWidth: 4)
                        Circle().trim(from: 0, to: CGFloat(outcome.catchRecord.speciesConfidence))
                            .stroke(DS.Color.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90))
                    }
                    .frame(width: 32, height: 32)
                }
                if let record = outcome.record, record.hasAny {
                    HStack(spacing: DS.Spacing.s) {
                        if record.isFirstSpecies { badge("初") }
                        if record.isPersonalBest { badge("自己記録") }
                        if record.isSpotRecord && !record.isPersonalBest { badge("釣り場記録") }
                        Spacer()
                    }
                }
                if outcome.merged {
                    Text("同じ魚にまとめました").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                }
                if outcome.catchRecord.speciesConfidence < 0.7 && outcome.catchRecord.speciesCandidates.count > 1 {
                    HStack(spacing: DS.Spacing.s) {
                        ForEach(outcome.catchRecord.speciesCandidates.prefix(3), id: \.species) { c in
                            Button { onChoose(c.species) } label: {
                                Text(c.species)
                                    .font(DS.Font.label)
                                    .foregroundStyle(c.species == outcome.catchRecord.species ? DS.Color.background : DS.Color.textPrimary)
                                    .padding(.horizontal, DS.Spacing.m).padding(.vertical, DS.Spacing.s)
                                    .background(c.species == outcome.catchRecord.species ? DS.Color.accent.opacity(0.9) : DS.Color.surfaceRaised, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(DS.Spacing.l)
            .background(DS.Color.surface.opacity(0.96), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .padding(.horizontal, DS.Spacing.l)
            .padding(.bottom, 120)
            .onTapGesture { onDismiss() }
            .task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                onDismiss()
            }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(DS.Font.label).foregroundStyle(DS.Color.background)
            .padding(.horizontal, DS.Spacing.s).padding(.vertical, 3)
            .background(DS.Color.accent, in: Capsule())
    }
}
