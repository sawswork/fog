import SwiftUI
import MapKit
import Core

/// 地図の上に色面と粒子を描く（F-43）。地図の操作は通さない
struct MapLayersOverlay: View {
    let proxy: MapProxy
    let raster: FieldRaster?
    let particles: ParticleSystem
    let animate: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animate)) { timeline in
            Canvas(rendersAsynchronously: false) { ctx, _ in
                guard let raster,
                      let tl = proxy.convert(CLLocationCoordinate2D(latitude: raster.box.maxLat, longitude: raster.box.minLon), to: .local),
                      let br = proxy.convert(CLLocationCoordinate2D(latitude: raster.box.minLat, longitude: raster.box.maxLon), to: .local) else { return }
                let rect = CGRect(x: tl.x, y: tl.y, width: br.x - tl.x, height: br.y - tl.y)
                if let img = raster.image {
                    ctx.draw(Image(decorative: img, scale: 1), in: rect)
                }
                if raster.layer.vector != nil, animate, MapLayerSettings.particles {
                    particles.step(raster: raster, now: timeline.date)
                    particles.draw(in: &ctx, rect: rect, layer: raster.layer)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// 層のチップ・凡例・時刻バー
struct MapLayersControls: View {
    @Binding var layer: MapLayer
    @Binding var hourOffset: Int
    let start: Date
    let hours: Int
    let loading: Bool
    let error: String?
    var onSettings: () -> Void = {}
    private let tz = TimeZone(identifier: "Asia/Tokyo") ?? .current

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Spacing.xs) {
                    Button(action: onSettings) {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.textPrimary)
                            .padding(.horizontal, DS.Spacing.s).padding(.vertical, 6)
                            .background(DS.Color.panel.opacity(0.9), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    ForEach(MapLayerSettings.enabled) { l in
                        Button { layer = l } label: {
                            Text(l.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(layer == l ? DS.Color.background : DS.Color.textPrimary)
                                .padding(.horizontal, DS.Spacing.m).padding(.vertical, 6)
                                .background(layer == l ? DS.Color.accent : DS.Color.panel.opacity(0.9), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: DS.Spacing.s) {
                legend
                if loading { ProgressView().tint(DS.Color.textSecondary).scaleEffect(0.7) }
                if let error { Text(error).font(.system(size: 9)).foregroundStyle(DS.Color.textTertiary).lineLimit(1) }
                Spacer()
            }
            // 時刻バーは凡例の下（左上のひとまとまり）。画面の中ほどに置くと右のボタン列と漁港の一覧に重なっていた（2026-11-09 開発者の指摘）
            MapTimeBar(hourOffset: $hourOffset, start: start, hours: hours)
                .frame(height: 40)
        }
    }

    private var legend: some View {
        HStack(spacing: 4) {
            LinearGradient(stops: layer.stops.map { Gradient.Stop(color: Color(red: $0.1.0, green: $0.1.1, blue: $0.1.2), location: $0.0) }, startPoint: .leading, endPoint: .trailing)
                .frame(width: 90, height: 6).clipShape(Capsule())
            Text(layer == .fog ? "濃い＝視程が短い" : "\(layer.format(layer.range.lowerBound))〜\(layer.format(layer.range.upperBound)) \(layer.unit)").font(.system(size: 9, weight: .semibold, design: .rounded)).foregroundStyle(DS.Color.textSecondary)
        }
        .padding(.horizontal, DS.Spacing.s).padding(.vertical, 4)
        .background(DS.Color.panel.opacity(0.9), in: Capsule())
    }
}

/// 時刻バー：今から `hours` 時間先まで 1 時間刻み。タップとドラッグ
struct MapTimeBar: View {
    @Binding var hourOffset: Int
    let start: Date
    let hours: Int

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let frac = CGFloat(hourOffset) / CGFloat(max(1, hours))
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8).fill(DS.Color.panel.opacity(0.95))
                // 日付の区切りと目盛り
                ForEach(0...(hours / 24), id: \.self) { d in
                    let x = w * CGFloat(d * 24) / CGFloat(max(1, hours))
                    Rectangle().fill(DS.Color.faded).frame(width: 1).offset(x: x)
                    Text(dayLabel(d)).font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.Color.textTertiary).offset(x: x + 4, y: 2)
                }
                Capsule().fill(DS.Color.accent).frame(width: max(0, w * frac), height: 4).offset(y: geo.size.height - 10)
                Rectangle().fill(Color.white).frame(width: 2).offset(x: w * frac - 1)
                Text(label).font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(DS.Color.textPrimary)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(DS.Color.background.opacity(0.85), in: Capsule())
                    .offset(x: min(max(0, w * frac - 28), w - 60), y: geo.size.height / 2 - 9)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                hourOffset = min(hours, max(0, Int((v.location.x / w * CGFloat(hours)).rounded())))
            })
        }
    }

    // ドラッグ中は毎フレーム呼ばれるので、フォーマッタは作り置き
    private static let labelFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.timeZone = TimeZone(identifier: "Asia/Tokyo"); f.dateFormat = "d日(E) H:00"; return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.timeZone = TimeZone(identifier: "Asia/Tokyo"); f.dateFormat = "d(E)"; return f
    }()

    private var label: String { Self.labelFormatter.string(from: start.addingTimeInterval(Double(hourOffset) * 3600)) }

    private func dayLabel(_ d: Int) -> String { Self.dayFormatter.string(from: start.addingTimeInterval(Double(d) * 86_400)) }
}

/// 地図レイヤーの設定（F-43）：表示する層のオンオフ、粒子、濃さ。釣り場画面のチップ左端と設定から開く
struct MapLayerSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var enabled: Set<MapLayer> = Set(MapLayerSettings.enabled)
    @State private var particles = MapLayerSettings.particles
    @State private var density = MapLayerSettings.density
    @State private var opacity = MapLayerSettings.opacity

    var body: some View {
        List {
            ForEach(MapLayer.Group.allCases, id: \.self) { g in
                Section {
                    ForEach(MapLayer.allCases.filter { $0.group == g }) { l in
                        Toggle(isOn: Binding(get: { enabled.contains(l) }, set: { on in
                            if on { enabled.insert(l) } else { enabled.remove(l) }
                            MapLayerSettings.setEnabled(on, l)
                        })) {
                            HStack(spacing: DS.Spacing.s) {
                                LinearGradient(stops: l.stops.map { Gradient.Stop(color: Color(red: $0.1.0, green: $0.1.1, blue: $0.1.2), location: $0.0) }, startPoint: .leading, endPoint: .trailing)
                                    .frame(width: 28, height: 6).clipShape(Capsule())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(l.title + (l.vector != nil ? "（粒子）" : "")).font(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                                    if !l.detail.isEmpty { Text(l.detail).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary) }
                                }
                            }
                        }
                        .tint(DS.Color.accent)
                        .listRowBackground(DS.Color.background).listRowSeparatorTint(DS.Color.surfaceRaised)
                    }
                } header: { Text(g.rawValue).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary) }
            }
            Section {
                Toggle(isOn: $particles) { Text("粒子を動かす").font(DS.Font.label).foregroundStyle(DS.Color.textPrimary) }
                    .tint(DS.Color.accent).listRowBackground(DS.Color.background).listRowSeparatorTint(DS.Color.surfaceRaised)
                    .onChange(of: particles) { _, v in MapLayerSettings.particles = v }
                Picker("粒子の数", selection: $density) {
                    ForEach(MapLayerSettings.Density.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).listRowBackground(DS.Color.background)
                .onChange(of: density) { _, v in MapLayerSettings.density = v }
                VStack(alignment: .leading, spacing: 4) {
                    Text("色の濃さ").font(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                    Slider(value: $opacity, in: 0.15...0.8).tint(DS.Color.accent)
                        .onChange(of: opacity) { _, v in MapLayerSettings.opacity = v }
                }
                .listRowBackground(DS.Color.background).listRowSeparatorTint(DS.Color.surfaceRaised)
            } header: { Text("表示").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(ThemeBackground(name: .bgSheet))
        .navigationTitle("地図レイヤー")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { dismiss() } label: { Image(systemName: "xmark").foregroundStyle(DS.Color.textSecondary) } } }
    }
}
