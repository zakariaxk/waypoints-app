import Core
import DesignSystem
import SwiftUI

/// KNW-3/4: one guide — tools, parts with cost, checkable steps kept on the device,
/// tradeoffs and mistakes, sources at the foot, and "Simulate this" when the task installs mods.
struct GuideDetailScreen: View {
    let ctx: GuidesContext
    let guideID: GuideID?
    /// The viewer's first car, for the mod-sim route; nil falls back to a mod list sheet.
    let carID: CarID?
    @State private var guide: Guide?
    @State private var failed = false
    @State private var done: Set<Int> = []
    @State private var showMods = false

    init(ctx: GuidesContext, guideID: GuideID, carID: CarID? = nil) {
        self.ctx = ctx; self.guideID = guideID; self.carID = carID
    }
    init(ctx: GuidesContext, guide: Guide, carID: CarID? = nil) {
        self.ctx = ctx; self.guideID = nil; self.carID = carID
        _guide = State(initialValue: guide)
        _done = State(initialValue: Self.loadSteps(guide.id))
    }

    var body: some View {
        ScrollView {
            if let guide {
                content(guide)
            } else if failed {
                ErrorState(Text("Couldn't load this guide.", bundle: .module)) { Task { await load() } }
            }
        }
        .background(Color.asphalt.ignoresSafeArea())
        .navigationTitle(guide.map { Text(verbatim: $0.vehicleLabel) } ?? Text(""))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(isPresented: $showMods) {
            NavigationStack {
                List(guide?.linkedModIDs ?? [], id: \.self) { id in Text(verbatim: id).typeStyle(.body) }
                    .navigationTitle(Text("Linked mods", bundle: .module))
            }
            .presentationDetents([.medium])
        }
    }

    private func content(_ guide: Guide) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: guide.task).typeStyle(.title).foregroundStyle(Color.chalk)
                .padding(.horizontal, Space.margin).padding(.top, Space.s16)
            Text(verbatim: "\(difficultyLabel(guide.difficulty)) · \(GuidesScreen.timeLabel(guide))")
                .typeStyle(.sub).foregroundStyle(Color.dust)
                .padding(.horizontal, Space.margin).padding(.top, Space.s4)

            if !guide.parts.isEmpty {
                SectionLabel("PARTS")
                ForEach(Array(guide.parts.enumerated()), id: \.offset) { _, part in
                    Row(Text(verbatim: part.name),
                        subtitle: part.partNumber.map { Text(verbatim: $0) },
                        trailing: { Text(readout: costLabel(part), token: .readoutS).foregroundStyle(Color.dust) })
                }
            }
            if !guide.tools.isEmpty {
                SectionLabel("TOOLS")
                ForEach(guide.tools, id: \.self) { tool in
                    Row(Text(verbatim: tool), showsDivider: false)
                }
            }
            SectionLabel("STEPS")
            ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
                stepRow(guide, index, step)
            }
            if let tradeoffs = guide.tradeoffs {
                SectionLabel("TRADEOFFS")
                Text(verbatim: tradeoffs).typeStyle(.body).foregroundStyle(Color.dust)
                    .padding(.horizontal, Space.margin)
            }
            if let mistakes = guide.mistakes {
                SectionLabel("COMMON MISTAKES")
                Text(verbatim: mistakes).typeStyle(.body).foregroundStyle(Color.brake)
                    .padding(.horizontal, Space.margin)
            }
            if !guide.linkedModIDs.isEmpty {
                PrimaryButton("Simulate this") {
                    if let carID, ctx.registry.canOpen(.modSim(carID)) { ctx.env.router.open(.modSim(carID)) }
                    else { showMods = true }
                }
                .padding(.horizontal, Space.margin).padding(.top, Space.s24)
            }
            SectionLabel("SOURCES")
            ForEach(guide.sources, id: \.self) { url in
                Link(destination: url) {
                    Row(Text(verbatim: url.host ?? url.absoluteString), trailing: { Disclosure() })
                }
                .buttonStyle(RowButtonStyle())
            }
        }
        .padding(.bottom, Space.s48)
    }

    /// KNW-3: a tappable check circle per step; the set is kept on the device.
    private func stepRow(_ guide: Guide, _ index: Int, _ step: String) -> some View {
        Button { toggle(guide, index) } label: {
            Row(Text(verbatim: step), leading: {
                Image.symbol(done.contains(index) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done.contains(index) ? Color.go : Color.gravel)
            }, trailing: { Text(verbatim: "\(index + 1)").typeStyle(.readoutS) })
        }
        .buttonStyle(RowButtonStyle())
    }

    private func toggle(_ guide: Guide, _ index: Int) {
        if done.contains(index) { done.remove(index) } else { done.insert(index) }
        UserDefaults.standard.set(Array(done), forKey: Self.stepsKey(guide.id))
    }

    private static func stepsKey(_ id: GuideID) -> String { "guide.steps.\(id)" }
    private static func loadSteps(_ id: GuideID) -> Set<Int> {
        Set(UserDefaults.standard.array(forKey: stepsKey(id)) as? [Int] ?? [])
    }

    private func difficultyLabel(_ d: Int) -> String {
        switch d {
        case 1: String(localized: "Difficulty · easy", bundle: .module)
        case 2: String(localized: "Difficulty · moderate", bundle: .module)
        case 3: String(localized: "Difficulty · involved", bundle: .module)
        case 4: String(localized: "Difficulty · hard", bundle: .module)
        default: String(localized: "Difficulty · expert", bundle: .module)
        }
    }

    private func costLabel(_ part: GuidePart) -> String {
        let dollars = { (cents: Int) in cents.formatted(.currency(code: "USD").precision(.fractionLength(0))) }
        return part.estCostCentsLow == part.estCostCentsHigh
            ? dollars(part.estCostCentsLow)
            : "\(dollars(part.estCostCentsLow))–\(dollars(part.estCostCentsHigh))"
    }

    private func load() async {
        guard guide == nil, let guideID else { return }
        do { guide = try await ctx.env.guides.guide(guideID); done = Self.loadSteps(guideID); failed = false }
        catch { failed = true }
    }
}
