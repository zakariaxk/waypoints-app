import Core
import DesignSystem
import SwiftUI

/// Hazard reports (plan 10.3 M5, M6): layer, sheet section, "Report a hazard", routes
/// `report` and `createReport`.
public enum ReportsFeature: FeatureModule {
    public static let isAvailable = true

    @MainActor
    public static func register(in registry: FeatureRegistry, env: AppEnvironment) {
        registry.registerMapLayer(ReportsLayer(env: env))
        registry.registerMapSheetSection(ReportsSection(env: env))
        registry.registerMapAction(ReportAction())
        registry.registerRoute(.createReport, presentation: .sheet) { route in
            guard case let .createReport(c) = route else { return nil }
            return AnyView(PostReport(env: env, at: c))
        }
        registry.registerRoute(.report, presentation: .sheet) { route in
            guard case let .report(id) = route else { return nil }
            return AnyView(ReportDetail(env: env, reportID: id).padding(.top, Space.s24)
                .presentationDetents([.height(Size.row * 4.5)]).sheetChrome())
        }
    }
}

enum ReportText {
    static func name(_ k: ReportKind) -> String {
        switch k {
        case .speedBump: "Speed bump"
        case .steepEntrance: "Steep entrance"
        case .pothole: "Pothole"
        case .roughRoad: "Rough road"
        case .police: "Police"
        case .hazard: "Hazard"
        case .closure: "Closure"
        case .fuelE85: "E85 fuel"
        }
    }
}

struct ReportsLayer: MapLayerProvider {
    let env: AppEnvironment
    var id: String { "reports" }

    func items(in region: MapRegion) -> AsyncStream<[MapItem]> {
        AsyncStream { c in
            let task = Task {
                let reports = (try? await env.reports.reports(in: region)) ?? []
                c.yield(reports.map { r in
                    MapItem(id: r.id.description, coordinate: r.coordinate, glyph: .report(r.kind), tint: .sodium,
                            title: ReportText.name(r.kind), priority: r.kind.affectsClearance ? 2 : 3)
                })
                c.finish()
            }
            c.onTermination = { _ in task.cancel() }
        }
    }

    @MainActor func detail(for item: MapItem) -> AnyView? {
        ReportID(string: item.id).map { AnyView(ReportDetail(env: env, reportID: $0)) }
    }
}

struct ReportsSection: MapSheetSection {
    let env: AppEnvironment
    var id: String { "reports" }
    var order: Int { 40 }
    @MainActor func view(region: MapRegion) -> AnyView { AnyView(ReportsSectionView(env: env, region: region)) }
}

struct ReportsSectionView: View {
    let env: AppEnvironment
    let region: MapRegion
    @State private var reports: [Report] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !reports.isEmpty {
                SectionLabel("REPORTS NEARBY")
                ForEach(reports.sorted { $0.createdAt > $1.createdAt }.prefix(5)) { r in
                    Button { env.router.open(.report(r.id)) } label: {
                        Row(Text(verbatim: ReportText.name(r.kind)),
                            subtitle: Text("Confirmed by \(r.confirmations)"),
                            leading: { ReportBadge(kind: r.kind.rawValue) },
                            trailing: { Text(verbatim: r.createdAt.formatted(.relative(presentation: .numeric))).typeStyle(.readoutS) })
                    }
                    .buttonStyle(RowButtonStyle())
                }
            }
        }
        .task(id: region) { reports = (try? await env.reports.reports(in: region)) ?? [] }
    }
}

struct ReportAction: MapAction {
    var id: String { "report" }
    var title: String { String(localized: "Report a hazard") }
    var symbol: String { "exclamationmark.triangle" }
    var order: Int { 10 }
    @MainActor func perform(at coordinate: Coordinate, router: any Router) { router.open(.createReport(coordinate)) }
}

// MARK: M5 Report

struct PostReport: View {
    let env: AppEnvironment
    let at: Coordinate
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var showNote = false
    @State private var error: String?
    @State private var done = 0
    @State private var failed = 0
    @State private var posted: Report?

    var body: some View {
        Sheet(Text("What's here?")) {
            if let posted {
                HStack {
                    Text(verbatim: "\(ReportText.name(posted.kind)) reported").typeStyle(.bodyStrong).foregroundStyle(Color.chalk)
                    Spacer()
                    QuietButton("Undo") {
                        Task { try? await env.gateway.undoReport(posted.id); dismiss() }
                    }
                }
                .padding(.horizontal, Space.margin)
                .task {
                    try? await Task.sleep(for: .seconds(5))
                    dismiss()
                }
            } else {
            VStack(spacing: Space.s16) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: Space.s16) {
                    ForEach(ReportKind.allCases, id: \.self) { kind in
                        Button { post(kind) } label: {
                            VStack(spacing: Space.s4) {
                                ReportBadge(kind: kind.rawValue)
                                Text(verbatim: ReportText.name(kind)).typeStyle(.foot).foregroundStyle(Color.chalk)
                                    .multilineTextAlignment(.center).lineLimit(2)
                            }
                        }
                    }
                }
                if showNote {
                    Field("Note", text: $note, prompt: "Optional", limit: 120)
                } else {
                    QuietButton("Add a note") { showNote = true }
                }
                if let error { Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake) }
            }
            .padding(.horizontal, Space.margin)
            }
        }
        .presentationDetents([.height(Size.row * 5.7), .medium])
        .haptic(.done, trigger: done)
        .haptic(.fail, trigger: failed)
    }

    private func post(_ kind: ReportKind) {
        Task {
            do {
                posted = try await env.gateway.postReport(kind: kind, at: at, note: note.isEmpty ? nil : note)
                done += 1
            } catch WaypointsError.rateLimited {
                error = "That's a lot of reports. Try again in a few minutes."
                failed += 1
            } catch {
                self.error = "Couldn't post the report. Check your connection and try again."
                failed += 1
            }
        }
    }
}

// MARK: M6 Report detail

struct ReportDetail: View {
    let env: AppEnvironment
    let reportID: ReportID
    @State private var report: Report?
    @State private var voted = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            if let r = report {
                HStack(spacing: Space.s12) {
                    ReportBadge(kind: r.kind.rawValue)
                    Text(verbatim: ReportText.name(r.kind)).typeStyle(.title).foregroundStyle(Color.chalk)
                    Spacer()
                    Menu {
                        Button("Report") { env.router.open(.reportContent(ContentRef(kind: .report, id: r.id.description))) }
                    } label: { Image.symbol(Symbol.more).frame(width: Size.hitTarget, height: Size.hitTarget) }
                }
                Text("Reported \(r.createdAt.formatted(.relative(presentation: .named))) · confirmed by \(r.confirmations)")
                    .typeStyle(.foot).foregroundStyle(Color.dust)
                if let note = r.note { Text(verbatim: note).typeStyle(.body).foregroundStyle(Color.chalk) }
                if voted {
                    Text("Thanks. Counted.").typeStyle(.bodyStrong).foregroundStyle(Color.go)
                } else {
                    HStack(spacing: Space.s12) {
                        SecondaryButton("Still there") { vote(true) }
                        SecondaryButton("Gone") { vote(false) }
                    }
                }
            } else {
                SkeletonRow()
            }
        }
        .padding(.horizontal, Space.margin)
        .task {
            report = try? await env.reports.report(reportID)
            voted = (try? await env.reports.myVote(on: reportID)) != nil
        }
    }

    private func vote(_ stillThere: Bool) {
        voted = true
        Task { try? await env.gateway.voteReport(reportID, stillThere: stillThere) }
    }
}
