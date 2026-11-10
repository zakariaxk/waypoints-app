import Core
import DesignSystem
import PerformanceModel
import SwiftUI

/// Showdown (plan 10.5 F4, F5), registered as a mode inside Feed.
public enum ShowdownFeature: FeatureModule {
    public static let isAvailable = true

    @MainActor
    public static func register(in registry: FeatureRegistry, env: AppEnvironment) {
        registry.registerFeedMode(ShowdownMode(env: env))
    }
}

struct ShowdownMode: FeedMode {
    let env: AppEnvironment
    var id: String { "showdown" }
    var title: String { String(localized: "Showdown") }
    var order: Int { 10 }
    @MainActor func view() -> AnyView { AnyView(NavigationStack { ShowdownView(env: env) }) }
}

extension ShowdownClass {
    var title: LocalizedStringKey {
        switch self { case .street: "Street"; case .built: "Built"; case .show: "Show"; case .classic: "Classic" }
    }
}

// MARK: F4

struct ShowdownView: View {
    let env: AppEnvironment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cls: ShowdownClass = .street
    @State private var pair: ShowdownPair?
    @State private var loading = true
    @State private var winner: CarID?
    @State private var movement: String?
    @State private var drag: CGFloat = 0
    @State private var thud = 0
    @State private var set = 0
    @State private var showRankings = false
    @State private var entryCounts: [CarID: Int] = [:]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.s8) {
                ForEach(ShowdownClass.allCases, id: \.self) { c in
                    Chip(c.title, isSelected: cls == c) { cls = c; Task { await next() } }
                }
                Spacer()
                IconButton("list.number", label: "Rankings") { showRankings = true }
            }
            .padding(.horizontal, Space.margin)
            .padding(.vertical, Space.s8)
            if let pair {
                GeometryReader { geo in
                    VStack(spacing: Space.s2) {
                        half(pair.left, top: true, height: geo.size.height / 2)
                        half(pair.right, top: false, height: geo.size.height / 2)
                    }
                }
            } else if loading {
                SkeletonBlock(height: Size.row * 6).padding(Space.margin)
                Spacer()
            } else {
                Spacer()
                EmptyState("You've judged every pair in \(cls.rawValue.capitalized). Try another class.", actionTitle: "Next class") {
                    let all = ShowdownClass.allCases
                    cls = all[((all.firstIndex(of: cls) ?? 0) + 1) % all.count]
                    Task { await next() }
                }
                Spacer()
            }
            if pair != nil {
                QuietButton("Skip") { Task { await next() } }.padding(.bottom, Space.s8)
            }
        }
        .background(Color.asphalt)
        .haptic(.thud, trigger: thud)
        .haptic(.set, trigger: set)
        .navigationDestination(isPresented: $showRankings) { RankingsView(env: env, cls: cls) }
        .task { await next() }
    }

    private func half(_ c: ShowdownContender, top: Bool, height: CGFloat) -> some View {
        let isWinner = winner == c.car.id
        let hidden = winner != nil && !isWinner
        let paint = c.car.colorHex.flatMap { Color(paintHex: $0) } ?? .dust
        let est = VehicleSpec.from(variant: nil, car: c.car).map { estimate(base: $0, mods: c.car.mods.compactMap(ModCatalog.mod)) }
        return ZStack(alignment: top ? .bottomLeading : .topLeading) {
            MediaView(url: c.photos.first.map { env.media.publicURL(bucket: .cars, path: $0.path) }, cornerRadius: 0,
                      label: Text(verbatim: c.car.fullLabel))
                .frame(height: isWinner ? height * 2 : height)
                .clipped()
            VStack(alignment: .leading, spacing: Space.s4) {
                Button { env.router.open(.car(c.car.id)) } label: { CarBadge(c.car.shortLabel, icon: c.owner.markerIcon, paint: paint) }
                Text(verbatim: "@\(c.owner.handle)").typeStyle(.foot).foregroundStyle(Color.chalk)
                HStack(spacing: Space.s16) {
                    if let est { Readout(String(format: "%.0f", (est.hp.lowerBound + est.hp.upperBound) / 2), label: "est. hp", token: .readoutS) }
                    Readout("\(c.entry.wins)", label: "wins", token: .readoutS)
                }
                if isWinner, let movement { Text(verbatim: movement).typeStyle(.readoutM).foregroundStyle(Color.go) }
            }
            .padding(Space.s12)
            .background(Color.asphalt.opacity(0.7), in: RoundedRectangle(cornerRadius: Radius.r12))
            .padding(Space.s12)
        }
        .frame(height: hidden ? 0 : (isWinner ? height * 2 : height))
        .opacity(hidden ? 0 : 1)
        .offset(y: winner == nil ? (top ? max(0, drag) : min(0, drag)) : 0)
        .contentShape(Rectangle())
        .onTapGesture { pick(c) }
        .gesture(DragGesture()
            .onChanged { v in
                drag = v.translation.height
                if abs(drag) > Size.row && abs(drag - v.translation.height) < 1 { set += 1 }
            }
            .onEnded { v in
                let toward = top ? v.translation.height > Size.row : v.translation.height < -Size.row
                drag = 0
                if toward { pick(c) }
            })
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text("Pick \(c.car.fullLabel)"))
    }

    private func pick(_ c: ShowdownContender) {
        guard let pair, winner == nil else { return }
        let loser = pair.left.car.id == c.car.id ? pair.right : pair.left
        thud += 1
        withMotion(.win, reduceMotion: reduceMotion) { winner = c.car.id }
        Task {
            let before = (try? await env.showdown.rankings(in: cls, period: .allTime, limit: 100))?.firstIndex { $0.car.id == c.car.id }
            try? await env.showdown.vote(winner: c.car.id, loser: loser.car.id)
            let after = (try? await env.showdown.rankings(in: cls, period: .allTime, limit: 100))?.firstIndex { $0.car.id == c.car.id }
            if let after {
                let moved = (before ?? 100) - after
                movement = moved > 0 ? "▲ \(moved) in \(cls.rawValue.capitalized)" : "#\(after + 1) in \(cls.rawValue.capitalized)"
            }
            try? await Task.sleep(for: .milliseconds(500))
            await next()
        }
    }

    private func next() async {
        loading = true
        winner = nil
        movement = nil
        pair = try? await env.showdown.nextPair(in: cls)
        loading = false
    }
}

// MARK: F5

struct RankingsView: View {
    let env: AppEnvironment
    @State var cls: ShowdownClass
    @State private var period: RankingPeriod = .week
    @State private var list: [ShowdownContender] = []
    @State private var me: UserID?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SegmentedSwitch(selection: $period, options: [(.week, "This week"), (.allTime, "All time")]).padding(.horizontal, Space.margin)
                HStack(spacing: Space.s8) {
                    ForEach(ShowdownClass.allCases, id: \.self) { c in Chip(c.title, isSelected: cls == c) { cls = c } }
                }
                .padding(Space.margin)
                let mine = list.enumerated().filter { $0.element.owner.userID == me }
                if !mine.isEmpty {
                    SectionLabel("YOURS")
                    ForEach(mine, id: \.element.car.id) { i, c in row(i, c) }
                    SectionLabel("ALL")
                }
                ForEach(Array(list.enumerated()), id: \.element.car.id) { i, c in row(i, c) }
            }
        }
        .background(Color.asphalt.ignoresSafeArea())
        .navigationTitle("Rankings")
        .task(id: "\(cls)\(period)") {
            me = await env.auth.currentSession()?.userID
            list = (try? await env.showdown.rankings(in: cls, period: period, limit: 50)) ?? []
        }
    }

    private func row(_ i: Int, _ c: ShowdownContender) -> some View {
        Button { env.router.open(.car(c.car.id)) } label: {
            Row(Text(verbatim: c.car.shortLabel), subtitle: Text(verbatim: "@\(c.owner.handle)"), leading: {
                HStack(spacing: Space.s8) {
                    Text(verbatim: "\(i + 1)").typeStyle(.readoutM).foregroundStyle(Color.chalk).frame(minWidth: Space.s24)
                    MediaView(url: c.photos.first.map { env.media.publicURL(bucket: .cars, path: $0.path) }, aspectRatio: 1,
                              cornerRadius: Radius.r6, label: Text(verbatim: c.car.shortLabel))
                        .frame(width: Size.hitTarget, height: Size.hitTarget)
                }
            }, trailing: { Text(verbatim: "\(c.entry.rating)").typeStyle(.readoutS) })
        }
        .buttonStyle(RowButtonStyle())
    }
}
