import SwiftUI
import MapKit
import Photos
import Core

/// 釣果の写真を全画面で見る（F-55）。ピンチで拡大、ドラッグで移動、ダブルタップで切替。
/// 写真本体はフォトライブラリから読み（長辺 2048）、読めない（消した・権限なし）ときはサムネイルを大きく出す。
struct PhotoViewer: View {
    let catchItem: Catch
    /// 仲間の釣果など、ライブラリに写真が無いときのサムネイル
    var fallback: Data?
    @Environment(\.dismiss) private var dismiss
    @Environment(AppServices.self) private var services
    @State private var image: UIImage?
    @State private var loading = true
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { geo in
                Group {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else if loading {
                        ProgressView().tint(.white)
                    } else {
                        VStack(spacing: DS.Spacing.s) {
                            Image(systemName: "photo").font(.system(size: 40)).foregroundStyle(.white.opacity(0.5))
                            Text("写真を読めません（ライブラリから消えたか、写真の権限がありません）").font(DS.Font.caption).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    MagnifyGesture()
                        .onChanged { v in scale = min(6, max(1, lastScale * v.magnification)) }
                        .onEnded { _ in lastScale = scale; if scale <= 1.01 { withAnimation { offset = .zero; lastOffset = .zero } } }
                        .simultaneously(with: DragGesture()
                            .onChanged { v in if scale > 1 { offset = CGSize(width: lastOffset.width + v.translation.width, height: lastOffset.height + v.translation.height) } }
                            .onEnded { _ in lastOffset = offset })
                )
                .onTapGesture(count: 2) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if scale > 1 { scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero } else { scale = 2.5; lastScale = 2.5 }
                    }
                }
            }
            VStack {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: DS.Spacing.s) {
                            Text(catchItem.species.isEmpty ? "魚" : catchItem.species).font(DS.Font.number(20)).foregroundStyle(.white)
                            if let l = catchItem.lengthCm { Text("\(Int(l.rounded()))cm").font(DS.Font.number(20)).foregroundStyle(DS.Color.accent) }
                        }
                        Text(catchItem.at, format: .dateTime.year().month().day().hour().minute()).font(DS.Font.caption).foregroundStyle(.white.opacity(0.7))
                        if let a = catchItem.angler, !a.isEmpty { Text(a).font(DS.Font.caption).foregroundStyle(DS.Color.sun) }
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 36, height: 36).background(Color.white.opacity(0.15), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(DS.Spacing.l)
                Spacer()
            }
        }
        .preferredColorScheme(.dark)
        .task { await load() }
    }

    private func load() async {
        defer { loading = false }
        if let id = catchItem.photoLocalIdentifier ?? catchItem.photoLocalIdentifiers.first,
           let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
           let cg = await PhotoLibraryService().image(for: asset, maxPixel: 2048) {
            image = UIImage(cgImage: cg)
            return
        }
        if let data = fallback ?? services.store.thumbnail(catchID: catchItem.id), let ui = UIImage(data: data) { image = ui }
    }
}

/// 釣行の軌跡と釣果の位置を全画面の地図で（F-55）。ピンチ・ドラッグで動かせる
struct SessionMapSheet: View {
    let session: Core.Session
    let spotName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let coords = session.track.map(\.coordinate).filter(\.isPlausible).map(\.cl)
        let catches = session.catches.filter { $0.coordinate.isPlausible }
        let center = coords.isEmpty ? catches.first?.coordinate.cl : coords[coords.count / 2]
        ZStack(alignment: .top) {
            Map(initialPosition: .region(MKCoordinateRegion(center: center ?? CLLocationCoordinate2D(latitude: 41.77, longitude: 140.73), latitudinalMeters: 700, longitudinalMeters: 700)),
                interactionModes: [.pan, .zoom, .rotate]) {
                if coords.count >= 2 { MapPolyline(coordinates: coords).stroke(DS.Color.accent, lineWidth: 4) }
                ForEach(catches, id: \.id) { c in
                    Annotation(c.species + (c.lengthCm.map { " \(Int($0.rounded()))" } ?? ""), coordinate: c.coordinate.cl) {
                        Circle().fill(DS.Color.accent).frame(width: 14, height: 14).overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                }
                ForEach(session.hookEvents.filter { $0.kind == .lost && $0.coordinate.isPlausible }, id: \.id) { e in
                    Annotation("", coordinate: e.coordinate.cl) { Circle().fill(.white).frame(width: 8, height: 8) }
                }
            }
            .mapStyle(.hybrid(elevation: .flat, pointsOfInterest: .excludingAll))
            .ignoresSafeArea()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(spotName).font(DS.Font.number(18)).foregroundStyle(.white)
                    Text("\(session.catches.count)尾 · 軌跡 \(coords.count) 点").font(DS.Font.caption).foregroundStyle(.white.opacity(0.75))
                }
                .padding(DS.Spacing.m).background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 36, height: 36).background(Color.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(DS.Spacing.l)
        }
    }
}
