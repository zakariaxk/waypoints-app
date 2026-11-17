import Core
import DesignSystem
import SwiftUI
import UIKit

/// KNW-3/4/7: one guide — tools, parts with cost, checkable steps kept on the device,
/// tradeoffs and mistakes, sources at the foot, "Simulate this" when the task installs mods,
/// and "Add to build log" once every step is checked.
struct GuideDetailScreen: View {
    let ctx: GuidesContext
    let guideID: GuideID?
    /// A car the screen was opened for (KNW-7 logs to it without asking); nil picks below.
    private let contextCarID: CarID?
    /// The viewer's first car, for the mod-sim route; nil falls back to a mod list sheet.
    @State private var carID: CarID?
    @State private var cars: [Car] = []
    @State private var guide: Guide?
    @State private var failed = false
    @State private var done: Set<Int> = []
    @State private var showMods = false
    @State private var pickerCars: [Car] = []
    @State private var showPicker = false
    @State private var logging = false
    @State private var logged = false
    @State private var logFailed = false
    @State private var shared: SharedImage?
    @State private var copiedParts = false
    @Environment(\.displayScale) private var displayScale

    init(ctx: GuidesContext, guideID: GuideID, carID: CarID? = nil) {
        self.ctx = ctx; self.guideID = guideID; self.contextCarID = carID
        _carID = State(initialValue: carID)
    }
    init(ctx: GuidesContext, guide: Guide, carID: CarID? = nil) {
        self.ctx = ctx; self.guideID = nil; self.contextCarID = carID
        _carID = State(initialValue: carID)
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
        .toolbar {
            if guide != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    IconButton(Symbol.share, label: "Share guide") { shareGuide() }
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showMods) {
            NavigationStack {
                List(guide?.linkedModIDs ?? [], id: \.self) { id in Text(verbatim: id).typeStyle(.body) }
                    .navigationTitle(Text("Linked mods", bundle: .module))
            }
            .presentationDetents([.medium])
        }
        .sheet(item: $shared) { ShareSheet(items: [$0.image]).presentationDetents([.medium, .large]) }
        .confirmationDialog(String(localized: "Log to which car?", bundle: .module),
                            isPresented: $showPicker, titleVisibility: .visible) {
            ForEach(pickerCars) { car in
                Button(car.nickname ?? car.shortLabel) {
                    if let guide { Task { await log(guide, to: car.id) } }
                }
            }
        }
    }

    private func content(_ guide: Guide) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: guide.task).typeStyle(.title).foregroundStyle(Color.chalk)
                .padding(.horizontal, Space.margin).padding(.top, Space.s16)
            Text(verbatim: "\(difficultyLabel(guide.difficulty)) · \(GuidesScreen.timeLabel(guide))")
                .typeStyle(.sub).foregroundStyle(Color.dust)
                .padding(.horizontal, Space.margin).padding(.top, Space.s4)
            // KNW-8: one row per person; the same chip votes or unvotes.
            Chip("Helpful · \(guide.votesCount)", isSelected: guide.votedByMe) { Task { await toggleVote(guide) } }
                .padding(.horizontal, Space.margin).padding(.top, Space.s12)

            if !guide.parts.isEmpty {
                SectionLabel("PARTS")
                ForEach(Array(guide.parts.enumerated()), id: \.offset) { _, part in
                    Row(Text(verbatim: part.name),
                        subtitle: part.partNumber.map { Text(verbatim: $0) },
                        trailing: { Text(readout: costLabel(part), token: .readoutS).foregroundStyle(Color.dust) })
                }
                // KNW-11: the whole parts list on the clipboard for a parts order.
                QuietButton(copiedParts ? "Copied" : "Copy parts list") { copyParts(guide) }
                    .disabled(copiedParts)
                    .padding(.horizontal, Space.margin)
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
            // KNW-7: every step checked offers one tap onto the car's build timeline.
            if !guide.steps.isEmpty && Set(guide.steps.indices).isSubset(of: done) {
                if logged {
                    PrimaryButton("Logged") {}.disabled(true)
                        .padding(.horizontal, Space.margin).padding(.top, Space.s24)
                } else {
                    PrimaryButton("Add to build log", isLoading: logging) { logTapped(guide) }
                        .padding(.horizontal, Space.margin).padding(.top, Space.s24)
                    if logFailed {
                        Text("Couldn't log it. Try again.", bundle: .module)
                            .typeStyle(.sub).foregroundStyle(Color.brake)
                            .padding(.horizontal, Space.margin).padding(.top, Space.s8)
                    }
                }
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

    /// KNW-8: optimistic toggle; a failed write puts the chip back.
    private func toggleVote(_ guide: Guide) async {
        var next = guide
        next.votedByMe.toggle()
        next.votesCount += next.votedByMe ? 1 : -1
        self.guide = next
        do {
            if next.votedByMe { try await ctx.env.guides.vote(guide.id) }
            else { try await ctx.env.guides.unvote(guide.id) }
        } catch {
            self.guide = guide
        }
    }

    /// KNW-10: renders the guide card and hands it to the share sheet.
    private func shareGuide() {
        guard let guide else { return }
        let image = GuideShare.render(guide: guide, time: GuidesScreen.timeLabel(guide), scale: displayScale)
        if let image { shared = SharedImage(image: image) }
    }

    /// KNW-11: "Name — $12" per line so it pastes straight into a parts order.
    private func copyParts(_ guide: Guide) {
        UIPasteboard.general.string = guide.parts
            .map { "\($0.name) — \(costLabel($0))" }
            .joined(separator: "\n")
        copiedParts = true
        Task { try? await Task.sleep(for: .seconds(Timing.toast)); copiedParts = false }
    }

    private func toggle(_ guide: Guide, _ index: Int) {
        if done.contains(index) { done.remove(index) } else { done.insert(index) }
        UserDefaults.standard.set(Array(done), forKey: Self.stepsKey(guide.id))
    }

    private static func stepsKey(_ id: GuideID) -> String { "guide.steps.\(id)" }
    private static func loadSteps(_ id: GuideID) -> Set<Int> {
        Set(UserDefaults.standard.array(forKey: stepsKey(id)) as? [Int] ?? [])
    }

    /// KNW-7: the car the guide applies to when exactly one matches, the car the screen was
    /// opened for, or a small picker when the match is ambiguous.
    private func logTapped(_ guide: Guide) {
        let matches = cars.filter { $0.make == guide.make }
            .filter { guide.model.map { $0.model.localizedCaseInsensitiveContains($1) } ?? true }
        if let contextCarID { Task { await log(guide, to: contextCarID) } }
        else if matches.count == 1 { Task { await log(guide, to: matches[0].id) } }
        else {
            pickerCars = matches.isEmpty ? cars : matches
            showPicker = true
        }
    }

    /// KNW-7: one timeline entry — the guide's task, today, and its first linked mod.
    private func log(_ guide: Guide, to target: CarID) async {
        guard !logging else { return }
        logging = true; logFailed = false
        do {
            try await ctx.env.garage.addBuildEntry(BuildEntry(
                carID: target, happenedOn: .now, title: String(guide.task.prefix(60)),
                body: "Waypoints guide · " + guide.vehicleLabel, modID: guide.linkedModIDs.first))
            logged = true
        } catch { logFailed = true }
        logging = false
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
        let dollars = { (cents: Int) in (cents / 100).formatted(.currency(code: "USD").precision(.fractionLength(0))) }
        return part.estCostCentsLow == part.estCostCentsHigh
            ? dollars(part.estCostCentsLow)
            : "\(dollars(part.estCostCentsLow))–\(dollars(part.estCostCentsHigh))"
    }

    private func load() async {
        // Routes reach this screen with no car; resolve the viewer's first so
        // "Simulate this" can open the mod sim instead of the raw mod list.
        if let me = await ctx.env.auth.currentSession()?.userID {
            cars = (try? await ctx.env.garage.cars(of: me)) ?? []
            if carID == nil { carID = cars.first?.id }
        }
        guard guide == nil, let guideID else { return }
        do { guide = try await ctx.env.guides.guide(guideID); done = Self.loadSteps(guideID); failed = false }
        catch { failed = true }
    }
}
