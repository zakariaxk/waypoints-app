import Core
import DesignSystem
import SwiftUI

// Help requests (PRD HELP-1..7): "Ask for a hand" in the add menu, a map layer, a sheet
// section, the posting sheet, and the detail sheet. The gateway resolves names per viewer:
// friends and teammates see the requester's name and car, drivers nearby see
// "A driver needs a hand" when the requester opted in.

enum HelpText {
    static func name(_ k: HelpKind) -> String {
        switch k {
        case .flatTire: String(localized: "Flat tire", bundle: .module)
        case .jumpStart: String(localized: "Jump start", bundle: .module)
        case .outOfFuel: String(localized: "Out of fuel", bundle: .module)
        case .stuck: String(localized: "Stuck", bundle: .module)
        case .other: String(localized: "Something else", bundle: .module)
        }
    }

    static let anonymous = String(localized: "A driver needs a hand", bundle: .module)
    static var disclosure: LocalizedStringKey {
        "This shares your exact spot with the people you pick until you clear it. For an emergency, call emergency services."
    }
    static var homeZone: LocalizedStringKey {
        "You're inside a home zone. Home zones don't apply to a help request: the people you pick see this exact spot."
    }

    static func who(_ r: HelpRequest) -> String { r.isMine ? String(localized: "You", bundle: .module) : (r.displayName ?? anonymous) }
}

extension MapGlyph {
    static let help = MapGlyph("report.help")
}

// MARK: Map plug-ins

struct HelpLayer: MapLayerProvider {
    let env: AppEnvironment
    var id: String { "help" }

    func items(in region: MapRegion) -> AsyncStream<[MapItem]> {
        AsyncStream { c in
            let task = Task {
                let requests = (try? await env.gateway.helpRequests(in: region)) ?? []
                c.yield(requests.map { r in
                    MapItem(id: r.id.description, coordinate: r.coordinate, glyph: .help, tint: .brake,
                            title: HelpText.who(r), priority: 10)
                })
                c.finish()
            }
            c.onTermination = { _ in task.cancel() }
        }
    }

    @MainActor func detail(for item: MapItem) -> AnyView? {
        HelpRequestID(string: item.id).map { AnyView(HelpDetail(env: env, requestID: $0)) }
    }
}

struct HelpSection: MapSheetSection {
    let env: AppEnvironment
    var id: String { "help" }
    var order: Int { 5 }
    @MainActor func view(region: MapRegion) -> AnyView { AnyView(HelpSectionView(env: env, region: region)) }
}

struct HelpSectionView: View {
    let env: AppEnvironment
    let region: MapRegion
    @State private var requests: [HelpRequest] = []
    @State private var reload = 0

    /// Yours first, then newest first.
    private var ordered: [HelpRequest] {
        requests.sorted { a, b in
            if a.isMine != b.isMine { return a.isMine }
            return a.createdAt > b.createdAt
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !requests.isEmpty {
                SectionLabel("NEEDS A HAND")
                ForEach(ordered) { r in
                    Button { env.router.open(.help(r.id)) } label: {
                        Row(Text(verbatim: HelpText.who(r)),
                            subtitle: Text(verbatim: HelpText.name(r.kind)),
                            leading: { ReportBadge(kind: "help") },
                            trailing: {
                                if r.responderCount > 0 {
                                    Text("\(r.responderCount) coming", bundle: .module).typeStyle(.readoutS)
                                } else {
                                    Disclosure()
                                }
                            })
                    }
                    .buttonStyle(RowButtonStyle())
                }
            }
        }
        .task(id: "\(region.hashValue)-\(reload)") {
            requests = (try? await env.gateway.helpRequests(in: region)) ?? []
        }
        .task {
            for await event in await env.realtime.events() {
                if case let .mapEvent(e) = event, e.kind == .help { reload += 1 }
            }
        }
    }
}

struct HelpAction: MapAction {
    var id: String { "help" }
    var title: String { String(localized: "Ask for a hand", bundle: .module) }
    var symbol: String { "hand.raised" }
    var order: Int { 15 }
    @MainActor func perform(at coordinate: Coordinate, router: any Router) { router.open(.askForHelp(coordinate)) }
}

// MARK: Posting

struct AskForHelp: View {
    let env: AppEnvironment
    /// Where the menu was opened; replaced by your own position when a fix arrives (HELP-1).
    let fallback: Coordinate
    @Environment(\.dismiss) private var dismiss
    @State private var kind: HelpKind?
    @State private var note = ""
    @State private var showNearby = false
    @State private var point: Coordinate?
    @State private var inHomeZone = false
    @State private var posting = false
    @State private var error: String?
    @State private var posted: HelpRequest?
    @State private var done = 0
    @State private var failed = 0

    init(env: AppEnvironment, fallback: Coordinate) {
        self.env = env
        self.fallback = fallback
    }

    var body: some View {
        if let posted {
            HelpDetail(env: env, requestID: posted.id, initial: posted)
                .padding(.top, Space.s24)
                .presentationDetents([.medium])
                .sheetChrome()
        } else {
            form
        }
    }

    private var form: some View {
        Sheet(Text("Ask for a hand", bundle: .module)) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s16) {
                    FlowChips(kinds: HelpKind.allCases, selected: $kind)
                    Field("Note", text: $note, prompt: "Optional", limit: 120)
                    Row(Text("Also show drivers nearby", bundle: .module),
                        subtitle: Text("Without your name, as \"A driver needs a hand\"", bundle: .module),
                        showsDivider: false,
                        trailing: { Toggle("", isOn: $showNearby).labelsHidden().tint(.sodium) })
                        .padding(.horizontal, -Space.margin)
                    Text(HelpText.disclosure).typeStyle(.sub).foregroundStyle(Color.chalk)
                    if inHomeZone {
                        Text(HelpText.homeZone).typeStyle(.foot).foregroundStyle(Color.sodium)
                    }
                    if let error { Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake) }
                    PrimaryButton("Ask for a hand", isLoading: posting) { post() }
                        .disabled(kind == nil || posting)
                }
                .padding(.horizontal, Space.margin)
                .padding(.bottom, Space.s24)
            }
        }
        .presentationDetents([.large])
        .haptic(.done, trigger: done)
        .haptic(.fail, trigger: failed)
        .task { await locate() }
    }

    private func locate() async {
        let location = env.location
        let fix: Coordinate? = await withTaskGroup(of: Coordinate?.self) { group in
            group.addTask {
                for await sample in await location.samples() { return sample.coordinate }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let at = fix ?? fallback
        point = at
        for await zones in await location.homeZones() {
            inHomeZone = zones.contains { $0.center.distance(to: at) <= Double($0.radiusMeters) }
            break
        }
    }

    private func post() {
        guard let kind else { return }
        posting = true
        error = nil
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = HelpDraft(kind: kind, coordinate: point ?? fallback, note: trimmed.isEmpty ? nil : trimmed,
                              showNearby: showNearby)
        Task {
            defer { posting = false }
            do {
                posted = try await env.gateway.postHelp(draft)
                done += 1
            } catch WaypointsError.conflict {
                error = String(localized: "You already have a request out. Clear it before asking again.", bundle: .module)
                failed += 1
            } catch WaypointsError.rateLimited {
                error = String(localized: "That's a lot of requests. Try again later.", bundle: .module)
                failed += 1
            } catch {
                self.error = String(localized: "Couldn't ask for a hand. Check your connection and try again.", bundle: .module)
                failed += 1
            }
        }
    }
}

/// The five kinds as chips, wrapped to the width.
private struct FlowChips: View {
    let kinds: [HelpKind]
    @Binding var selected: HelpKind?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.s8) { chips }
            VStack(alignment: .leading, spacing: Space.s8) {
                HStack(spacing: Space.s8) { ForEach(kinds.prefix(3), id: \.self, content: chip) }
                HStack(spacing: Space.s8) { ForEach(kinds.dropFirst(3), id: \.self, content: chip) }
            }
        }
    }

    private var chips: some View { ForEach(kinds, id: \.self, content: chip) }

    private func chip(_ k: HelpKind) -> some View {
        Chip(LocalizedStringKey(HelpText.name(k)), isSelected: selected == k) { selected = k }
    }
}

// MARK: Detail

struct HelpDetail: View {
    let env: AppEnvironment
    let requestID: HelpRequestID
    let initial: HelpRequest?
    @Environment(\.dismiss) private var dismiss
    @State private var request: HelpRequest?
    @State private var gone = false
    @State private var busy = false
    @State private var error: String?
    @State private var done = 0

    init(env: AppEnvironment, requestID: HelpRequestID, initial: HelpRequest? = nil) {
        self.env = env
        self.requestID = requestID
        self.initial = initial
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            if let r = request {
                content(r)
            } else if gone {
                Text("This request has ended.", bundle: .module).typeStyle(.body).foregroundStyle(Color.dust)
            } else {
                SkeletonRow()
            }
        }
        .padding(.horizontal, Space.margin)
        .haptic(.done, trigger: done)
        .task {
            if request == nil { request = initial }
            await load()
        }
        .task {
            for await event in await env.realtime.events() {
                if case let .mapEvent(e) = event, e.kind == .help, e.id == requestID.description {
                    if e.op == .remove { request = nil; gone = true } else { await load() }
                }
            }
        }
    }

    @ViewBuilder private func content(_ r: HelpRequest) -> some View {
        HStack(spacing: Space.s12) {
            ReportBadge(kind: "help")
            Text(verbatim: HelpText.name(r.kind)).typeStyle(.title).foregroundStyle(Color.chalk)
            Spacer()
            if !r.isMine {
                // SAFE-1, X1: the request itself is reportable by id, so the anonymous nearby
                // form can be reported without the client ever learning who posted it.
                Menu {
                    Button("Report") { env.router.open(.reportContent(.help(r.id))) }
                    if let requester = r.requesterID {
                        Button("Report person") { env.router.open(.reportContent(.user(requester))) }
                    }
                } label: { Image.symbol(Symbol.more).frame(width: Size.hitTarget, height: Size.hitTarget) }
                .accessibilityLabel(Text("More", bundle: .module))
            }
        }
        if r.isMine {
            Text("Your request", bundle: .module).typeStyle(.bodyStrong).foregroundStyle(Color.chalk)
        } else if let name = r.displayName {
            Text(verbatim: name).typeStyle(.bodyStrong).foregroundStyle(Color.chalk)
            if let car = r.carLabel { CarBadge(car) }
        } else {
            Text(verbatim: HelpText.anonymous).typeStyle(.bodyStrong).foregroundStyle(Color.chalk)
        }
        Text("Asked \(r.createdAt.formatted(.relative(presentation: .named))) · ends \(r.expiresAt.formatted(.relative(presentation: .named)))")
            .typeStyle(.foot).foregroundStyle(Color.dust)
        if let note = r.note { Text(verbatim: note).typeStyle(.body).foregroundStyle(Color.chalk) }
        if r.isMine {
            if r.responders.isEmpty {
                Text("Nobody is on the way yet.", bundle: .module).typeStyle(.sub).foregroundStyle(Color.dust)
            } else {
                Text("On the way: \(r.responders.map(\.displayName).formatted(.list(type: .and)))")
                    .typeStyle(.sub).foregroundStyle(Color.go)
            }
            HStack(spacing: Space.s12) {
                PrimaryButton("I'm good", isLoading: busy) { end(r) }
                SecondaryButton("Add an hour") { extend(r) }
            }
        } else {
            if r.isComing {
                Text("They know you're on the way.", bundle: .module).typeStyle(.bodyStrong).foregroundStyle(Color.go)
                PrimaryButton("Directions") { directions(r) }
            } else {
                if r.responderCount > 0 {
                    Text("\(r.responderCount) on the way", bundle: .module).typeStyle(.sub).foregroundStyle(Color.dust)
                }
                HStack(spacing: Space.s12) {
                    PrimaryButton("On my way", isLoading: busy) { respond(r) }
                    SecondaryButton("Directions") { directions(r) }
                }
            }
        }
        if let error { Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake) }
    }

    private func load() async {
        do {
            request = try await env.gateway.helpRequest(requestID)
        } catch WaypointsError.notFound {
            request = nil
            gone = true
        } catch {}
    }

    private func directions(_ r: HelpRequest) {
        env.router.open(.navigate(to: r.coordinate, name: HelpText.who(r)))
    }

    private func respond(_ r: HelpRequest) {
        busy = true
        Task {
            defer { busy = false }
            do {
                request = try await env.gateway.respondToHelp(r.id)
                done += 1
            } catch {
                self.error = String(localized: "Couldn't send that. Check your connection and try again.", bundle: .module)
            }
        }
    }

    private func end(_ r: HelpRequest) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await env.gateway.endHelp(r.id)
                done += 1
                dismiss()
            } catch {
                self.error = String(localized: "Couldn't clear it. Check your connection and try again.", bundle: .module)
            }
        }
    }

    private func extend(_ r: HelpRequest) {
        Task {
            do {
                request = try await env.gateway.extendHelp(r.id)
            } catch {
                self.error = String(localized: "Couldn't extend it. Check your connection and try again.", bundle: .module)
            }
        }
    }
}
