import Foundation
import MapKit
import Core

/// 相談の振り分け先（F-65）。声や文字の入力を、記録・操作の命令／自分の記録への質問／次の一手／計画／魚の質問／
/// 釣果情報の要約／釣行のまとめ に分け、アプリの記録から答えを組み立てる。
/// 数字はすべてアプリが計算する（Core）。言語モデルは、その事実の行を選んで言い直すところにだけ使う。通信は増やさない
/// （計画の車の所要時間は Apple の経路検索、釣果情報は登録済みの取得元。どちらも前からある通信）
@MainActor
enum AssistantActions {
    struct Reply {
        var text: String
        /// 共有できる文（釣行のまとめ）
        var share: String?
        /// 撮影画面を開いてほしい（海図の画面のマイクから）
        var openCamera = false
    }

    /// 呼び名（標準和名と別名）→ 標準和名
    static let speciesIndex: [String: String] = {
        var out: [String: String] = [:]
        for s in Species.initialCatalog {
            out[s.name] = s.name
            for alias in s.aliases where out[alias] == nil { out[alias] = s.name }
        }
        return out
    }()

    static func route(_ text: String) -> AssistantIntent {
        AssistantRouter.route(text, species: speciesIndex, worms: RigPartsStore.load().worms)
    }

    /// `.other`（予報の質問・店先の話）は nil を返す（これまでの流れに任せる）
    static func run(_ intent: AssistantIntent, text: String, services: AppServices, home: HomeViewModel) async -> Reply? {
        switch intent {
        case .command(let command): return await execute(command, services: services, home: home)
        case .records: return await records(text, services: services, home: home)
        case .advice: return advice(services: services, home: home)
        case .plan: return await plan(text, services: services, home: home)
        case .fish(let name): return await fish(name, question: text, services: services, home: home)
        case .feedDigest: return await feedDigest(services: services)
        case .tripSummary: return tripSummary(text, services: services, home: home)
        case .other: return nil
        }
    }

    // MARK: 1. 記録・操作の命令

    static func execute(_ command: VoiceCommand, services: AppServices, home: HomeViewModel) async -> Reply {
        switch command {
        case .start:
            if home.isRecording { return Reply(text: "すでに記録中です") }
            return Reply(text: await home.toggleSession() ? "釣行を開始しました" : "位置が分からず開始できませんでした。釣り場を選んでからもう一度")
        case .end:
            guard home.isRecording else { return Reply(text: "記録中の釣行はありません") }
            let count = home.liveSession?.catches.count ?? 0
            await home.toggleSession()
            return Reply(text: "釣行を終了しました（\(count) 尾）")
        case .lost(let count):
            guard home.isRecording else { return Reply(text: "釣行中だけ記録できます。先に「開始」と言ってください") }
            var done = 0
            for _ in 0..<count where services.hookRecorder.record(.lost) != nil { done += 1 }
            guard done > 0 else { return Reply(text: "位置が分からず、ロストを記録できませんでした") }
            let total = ((try? services.store.activeSession())?.hookEvents.filter { $0.kind == .lost }.count) ?? done
            return Reply(text: "ロストを \(done) 回記録しました（この釣行 \(total) 回）")
        case .hookAdded:
            guard home.isRecording else { return Reply(text: "釣行中だけ記録できます。先に「開始」と言ってください") }
            return Reply(text: services.hookRecorder.record(.added) != nil ? "針の追加を記録しました" : "位置が分からず記録できませんでした")
        case .rig(let hook, let sinker, let worm):
            // 言われた項目だけ替える。ほかは今のリグのまま
            let rigs = (try? services.store.rigs()) ?? []
            let current = rigs.first { $0.id == services.capture.currentRigID }
            let newHook = hook ?? current.map { RigParts.normalizeHook($0.hookSize) }.flatMap { $0.isEmpty ? nil : $0 }
            let newSinker = sinker ?? current.flatMap { $0.sinkerGrams > 0 ? $0.sinkerGrams : nil }
            let newWorm = worm ?? current.flatMap { $0.worm.isEmpty ? nil : $0.worm }
            guard let resolved = Rig.resolve(hook: newHook, sinkerGrams: newSinker, worm: newWorm, in: rigs) else { return Reply(text: "リグを読み取れませんでした") }
            if resolved.isNew { try? services.store.upsert(resolved.rig) }
            services.capture.currentRigID = resolved.rig.id
            UserDefaults.standard.set(false, forKey: RigPartsStore.clearedKey)
            // 言われた大きさ・重さが登録に無ければ足しておく（次から選べる）
            var parts = RigPartsStore.load()
            var changed = false
            if let hook, parts.addHook(hook) { changed = true }
            if let sinker, parts.addSinker(RigParts.gramsText(sinker)) { changed = true }
            if changed { RigPartsStore.save(parts) }
            var detail: [String] = []
            if resolved.rig.sinkerGrams > 0 { detail.append("シンカー \(RigParts.gramsText(resolved.rig.sinkerGrams))g") }
            if !resolved.rig.hookSize.isEmpty { detail.append("フック #\(RigParts.normalizeHook(resolved.rig.hookSize))") }
            if !resolved.rig.worm.isEmpty { detail.append("ワーム \(resolved.rig.worm)") }
            return Reply(text: "リグを替えました：" + detail.joined(separator: "、"))
        case .tackle(let kind):
            services.capture.currentTackle = kind
            return Reply(text: "タックルを\(kind == .spinning ? "スピニング" : "ベイト")にしました")
        case .camera:
            return Reply(text: "撮影画面を開きます", openCamera: true)
        }
    }

    // MARK: 2. 自分の記録への質問

    private static func records(_ question: String, services: AppServices, home: HomeViewModel) async -> Reply {
        let store = services.store
        let sessions = (try? store.sessions()) ?? []
        let spots = (try? store.spots()) ?? []
        let rigNames = Dictionary(((try? store.rigs()) ?? []).map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        let filter = RecordQuery.filter(for: question, spots: spots, species: speciesIndex, now: .now, timeZone: home.timeZone)
        let facts = RecordQuery.facts(question: question, sessions: sessions, spots: spots, rigNames: rigNames, filter: filter, ownName: AnglerSettings.ownName, timeZone: home.timeZone)
        guard !facts.lines.isEmpty else { return Reply(text: facts.headline) }
        return Reply(text: await services.assistant.rephrase(question: question, facts: facts.context, fallback: facts.text))
    }

    // MARK: 3. いま何をすべきか

    /// 釣行中の「次の一手」の材料。海図の画面のひとことにも使う
    static func advisorInput(services: AppServices, home: HomeViewModel, now: Date = .now) -> SessionAdvisor.Input {
        let live = home.liveSession
        let env = services.environment.scoreSnapshot(at: now, coordinate: home.coordinate)
        let rigs = (try? services.store.rigs()) ?? []
        let rig = rigs.first { $0.id == (services.capture.currentRigID ?? live?.rigID) }
        // 見立ての数（その港の海図があれば）
        var zones = 0
        if let chart = PortChartCatalog.bundled().chart(containing: home.coordinate) {
            zones = CastPredictor.predict(.init(chart: chart, user: services.location.lastFix?.coordinate, windFromDeg: env.windDirectionDeg, windSpeedMS: env.windSpeedMS,
                                                tideRateCmPerHour: env.tideRateCmPerHour, pastCatches: [], todayCatches: [])).count
        }
        // この釣り場の実績：いちばん釣れている潮の動き
        var bestTide: (label: String, count: Int, total: Int)?
        if let spot = home.spot {
            let own = ((try? services.store.sessions()) ?? []).filter { $0.spotID == spot.id }.flatMap(\.catches).filter { $0.isOwn(ownName: AnglerSettings.ownName) }
            let dist = Analytics.conditionDistribution(of: own, timeZone: home.timeZone)
            let known = dist.byTide.filter { $0.key != "不明" }
            if let top = known.max(by: { $0.value < $1.value }) { bestTide = (top.key, top.value, known.values.reduce(0, +)) }
        }
        let tideNow = env.tideRateCmPerHour.map { abs($0) < 2 ? "潮止まり" : ($0 > 0 ? "上げ" : "下げ") }
        let twilight = ChartViewModel.twilightBands(from: now, to: now.addingTimeInterval(6 * 3600), coordinate: home.coordinate).first { $0.start > now }?.start
        return SessionAdvisor.Input(now: now, sessionStartedAt: live?.startedAt, catchTimes: live?.catches.map(\.at) ?? [],
                                    lostTimes: live?.hookEvents.filter { $0.kind == .lost }.map(\.at) ?? [],
                                    scoreNow: home.score?.score ?? 0, timeline: home.timeline.filter { $0.at >= now },
                                    tideRateCmPerHour: env.tideRateCmPerHour, windSpeedMS: env.windSpeedMS, sinkerGrams: rig.flatMap { $0.sinkerGrams > 0 ? $0.sinkerGrams : nil },
                                    zoneCount: zones, tideNow: tideNow, bestTide: bestTide, nextTwilight: twilight, timeZone: home.timeZone)
    }

    private static func advice(services: AppServices, home: HomeViewModel) -> Reply {
        let suggestions = SessionAdvisor.advise(advisorInput(services: services, home: home))
        let head = home.isRecording ? "いまの提案（\(home.spot?.name ?? "現在地")）" : "釣行中ではないので、いまの条件からの提案です（\(home.spot?.name ?? "現在地")）"
        return Reply(text: head + "\n" + SessionAdvisor.text(suggestions))
    }

    // MARK: 4. 次の釣行の計画

    private static func plan(_ question: String, services: AppServices, home: HomeViewModel) async -> Reply {
        let tz = home.timeZone, now = Date()
        let request = TripPlanner.parse(question, now: now, timeZone: tz)
        var targets: [(name: String, coordinate: Coordinate)] = ((try? services.store.spots()) ?? []).filter { $0.isRegistered && $0.coordinate.isPlausible }.prefix(6).map { ($0.name, $0.coordinate) }
        if let spot = home.spot, spot.coordinate.isPlausible, !targets.contains(where: { $0.name == spot.name }) { targets.insert((spot.name, spot.coordinate), at: 0) }
        guard !targets.isEmpty else { return Reply(text: "登録した釣り場がありません。釣り場の地図から登録すると、予報を比べて提案できます") }
        let env = services.environment
        let origin = services.location.lastFix?.coordinate
        var candidates: [TripPlanner.Candidate] = []
        for target in targets {
            await env.refreshIfNeeded(at: target.coordinate, now: now)
            let tide = env.tideStation(near: target.coordinate).map { TideEngine(station: $0) }
            let horizon = env.forecastHorizon(for: target.coordinate)
            let calc = HomeViewModel.DayCalculator(engine: ScoreEngine(), builder: env.builder(for: target.coordinate), inputs: env.inputs(for: target.coordinate), tide: tide,
                                                   coordinate: target.coordinate, timeZone: tz, horizon: horizon)
            var best: TripPlanner.Candidate?
            for day in request.days {
                let points = calc.compute(from: day).timeline
                guard let c = TripPlanner.best(spotName: target.name, dayStart: day, points: points, request: request, now: now) else { continue }
                if best == nil || c.score > (best?.score ?? 0) { best = c }
            }
            guard var c = best else { continue }
            // その時間の天気。予報が届かない日は、潮と時間帯だけの見込みだと書く
            if let horizon, c.start <= horizon {
                let e = env.snapshot(at: c.start, coordinate: target.coordinate)
                var w: [String] = []
                if let v = e.windSpeedMS { w.append("風 \(Int(v.rounded()))m") }
                if let t = e.airTemperatureC { w.append("気温 \(Int(t.rounded()))°") }
                if let p = e.precipitationChance { w.append("降水 \(Int((p * 100).rounded()))%") }
                if let h = e.waveHeightM { w.append(String(format: "波 %.1fm", h)) }
                c.weather = w.joined(separator: " ")
            } else {
                c.weather = "天気の予報がまだ届かない日（潮と時間帯だけの見込み）"
            }
            if let origin { c.driveSeconds = await driveSeconds(from: origin, to: target.coordinate) }
            candidates.append(c)
        }
        return Reply(text: TripPlanner.text(request: request, ranked: TripPlanner.rank(candidates), timeZone: tz))
    }

    /// 車の所要時間（Apple の経路検索。F-56 と同じ）。分からなければ nil
    private static func driveSeconds(from: Coordinate, to: Coordinate) async -> Double? {
        guard from.isPlausible, to.isPlausible else { return nil }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: from.latitude, longitude: from.longitude)))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: to.latitude, longitude: to.longitude)))
        request.transportType = .automobile
        return try? await MKDirections(request: request).calculateETA().expectedTravelTime
    }

    // MARK: 5. 魚について

    private static func fish(_ name: String, question: String, services: AppServices, home: HomeViewModel) async -> Reply {
        let sessions = (try? services.store.sessions()) ?? []
        let own = sessions.flatMap(\.catches).filter { $0.isOwn(ownName: AnglerSettings.ownName) }
        var species = name, length: Double?
        if species.isEmpty {
            // 「これ」：いちばん新しい釣果
            guard let latest = own.filter({ !$0.species.isEmpty }).max(by: { $0.at < $1.at }) else { return Reply(text: "魚の名前を入れて聞いてください（例：アイナメはどう食べる？）") }
            species = latest.species; length = latest.lengthCm
        }
        let catalog = await Task.detached(priority: .userInitiated) { FishCatalog.bundled() }.value
        guard let entry = catalog.entry(forSpecies: species) else { return Reply(text: "「\(species)」のデータが図鑑にありません") }
        let mine = own.filter { $0.species == species }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = home.timeZone
        let lines = FishAnswer.facts(entry, month: cal.component(.month, from: Date()), ownCount: mine.count, ownMaxCm: mine.compactMap(\.lengthCm).max(), lengthCm: length)
        let fallback = lines.prefix(7).joined(separator: "\n")
        return Reply(text: await services.assistant.rephrase(question: question, facts: lines.joined(separator: "\n"), fallback: fallback))
    }

    // MARK: 6. 釣果情報の要約

    private static func feedDigest(services: AppServices) async -> Reply {
        await services.feeds.refreshIfNeeded()
        return Reply(text: FeedDigest.make(items: services.feeds.items, species: speciesIndex, now: .now).text)
    }

    // MARK: 7. 釣行のまとめ

    private static func tripSummary(_ question: String, services: AppServices, home: HomeViewModel) -> Reply {
        let store = services.store
        let sessions = (try? store.sessions()) ?? []          // 新しい順
        guard let session = sessions.first(where: \.isActive) ?? sessions.first else { return Reply(text: "まとめる釣行がありません") }
        let spots = Dictionary(((try? store.spots()) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ownName = AnglerSettings.ownName, me = AnglerSettings.deviceID
        var items = session.catches.map { TripSummary.Item(angler: ($0.angler?.isEmpty == false ? $0.angler : nil) ?? ownName, species: $0.species, lengthCm: $0.lengthCm, at: $0.at) }
        var members: [String] = [ownName]
        // 同行した仲間の端末の釣果（F-62）
        if PartyService.isEnabled {
            let ownLegs = sessions.map { PartyTrip.Leg(SharedSession.make(from: $0, spot: spots[$0.spotID], ownName: ownName, device: me)) }
            let resolved = PartyTrips.resolve(own: ownLegs, others: services.party.otherSessions.map { PartyTrip.Leg($0) }, ownName: ownName)
            members += resolved.companions[session.id] ?? []
            let shared = PartyTrips.catches(in: resolved.companionLegs[session.id] ?? [], from: services.party.others)
            items += shared.map { TripSummary.Item(angler: $0.angler.isEmpty ? "仲間" : $0.angler, species: $0.species, lengthCm: $0.lengthCm, at: $0.at) }
        }
        let tideName = session.catches.compactMap { $0.env?.tideName }.first ?? session.snapshots.compactMap(\.tideName).first
        let text = TripSummary.make(spotName: spots[session.spotID]?.name ?? "釣り場", startedAt: session.startedAt, endedAt: session.endedAt, items: items, members: members,
                                    lost: session.hookEvents.filter { $0.kind == .lost }.count, tideName: tideName, timeZone: home.timeZone)
        return Reply(text: text, share: text)
    }
}
