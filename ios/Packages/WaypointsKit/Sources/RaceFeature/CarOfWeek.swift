import Core
import DesignSystem
import PerformanceModel
import SwiftUI
import VehicleCatalog

/// STR-11 car of the week (W10-6): one catalog car, stock, the same for everyone, new
/// every Monday 00:00 UTC. The lobby row shows the car and your best this week; the
/// sheet lists this week's runs — you, friends, teammates — and offers "Run it". Runs
/// save to `car_of_week_runs` through `car_of_week_save` and award nothing; the time
/// slip carries its own "Car of the week" line.
@MainActor
@Observable
final class CarOfWeekModel {
    var pick: CarOfWeekPick?
    /// A synthetic stock car for the pick, like `BenchPicker.choose` builds one.
    var car: Car?
    var spec: VehicleSpec?
    var runs: [WeeklyRun] = []
    var myID: UserID?
    var failed = false
    var running = false

    /// Your best this week, if the board has one for you.
    var myBest: Int? { runs.first { $0.userID == myID }?.etMs }

    func load(env: AppEnvironment) async {
        guard let pick = try? await env.progress.carOfWeek() else { failed = true; return }
        self.pick = pick
        failed = false
        myID = await env.auth.currentSession()?.userID
        var variant: CatalogVariant?
        if let v = try? await env.catalog.variant(pick.variantID) {
            variant = v
        } else {
            variant = (try? await env.catalog.search(pick.label, limit: 1))?.first
        }
        guard let variant else { failed = true; return }
        let c = Car(ownerID: myID ?? UserID(raw: UUID()), catalogVariantID: pick.variantID,
                    year: variant.year, make: variant.make, model: variant.model, trim: variant.trim)
        guard let s = VehicleSpec.from(variant: variant, car: c) else { failed = true; return }
        car = c
        spec = s
        // Only runs recorded under this model version are offered, like friend runs.
        runs = ((try? await env.progress.carOfWeekRuns()) ?? [])
            .filter { $0.modelVersion == PerformanceModelVersion.current }
    }
}

/// The lobby row: the week's car and your best, opening the weekly board.
struct CarOfWeekSection: View {
    let env: AppEnvironment
    @State private var model = CarOfWeekModel()
    @State private var showBoard = false

    var body: some View {
        Group {
            if let car = model.car {
                SectionLabel("CAR OF THE WEEK")
                Button { showBoard = true } label: {
                    Row(Text(verbatim: car.fullLabel), subtitle: subtitle, trailing: { Disclosure() })
                }
                .buttonStyle(RowButtonStyle())
            } else if !model.failed {
                SkeletonRow()
            }
        }
        .task { await model.load(env: env) }
        .sheet(isPresented: $showBoard) {
            Sheet(Text("Car of the week", bundle: .module)) {
                WeeklyBoardBody(model: model, env: env)
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var subtitle: Text {
        if let best = model.myBest {
            return Text(verbatim: Format.number(Double(best) / 1000, fractionDigits: 3) + " s")
        }
        return Text("No run yet this week", bundle: .module)
    }
}

/// The board inside the sheet (and the `car-of-week` debug screen): the car, its est.
/// range, this week's runs, and "Run it".
struct WeeklyBoardBody: View {
    @Bindable var model: CarOfWeekModel
    let env: AppEnvironment
    @AppStorage(Ladder.treeKey) private var tree = TreeKind.sportsman

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let spec = model.spec {
                    let est = estimate(base: spec, mods: [])
                    VStack(alignment: .leading, spacing: Space.s4) {
                        Text(verbatim: model.car?.fullLabel ?? model.pick?.label ?? "")
                            .typeStyle(.title).foregroundStyle(Color.chalk)
                        Text("Stock for everyone. A new car every Monday.", bundle: .module)
                            .typeStyle(.foot).foregroundStyle(Color.dust)
                        Readout(Format.number((est.quarterET.lowerBound + est.quarterET.upperBound) / 2, fractionDigits: 1),
                                unit: "s", label: "EST. ¼ MILE", token: .readoutL,
                                range: .init(low: est.quarterET.lowerBound, high: est.quarterET.upperBound,
                                             bounds: 8...18))
                            .frame(maxWidth: Size.row * 3, alignment: .leading)
                            .padding(.top, Space.s8)
                    }
                    .padding(.horizontal, Space.margin)
                    .padding(.top, Space.s16)
                }
                if model.failed {
                    ErrorState(Text("Couldn't load this week's car. Check your connection and try again.", bundle: .module)) {
                        Task { await model.load(env: env) }
                    }
                    .padding(.top, Space.s48)
                } else {
                    runs
                    VStack(spacing: Space.s12) {
                        PrimaryButton("Run it") { model.running = true }
                            .disabled(model.car == nil || model.spec == nil)
                    }
                    .padding(.horizontal, Space.margin)
                    .padding(.top, Space.s24)
                    .padding(.bottom, Space.s32)
                }
            }
        }
        .background(Color.asphalt.ignoresSafeArea())
        .fullScreenCover(isPresented: $model.running, onDismiss: { Task { await model.load(env: env) } }) {
            if let car = model.car, let spec = model.spec {
                RunView(env: env, car: car, spec: spec,
                        opponent: .bench(BenchCar(label: model.pick?.label ?? car.fullLabel, spec: spec, mods: [])),
                        tree: tree, weekly: true)
            }
        }
    }

    @ViewBuilder private var runs: some View {
        if model.runs.isEmpty {
            Text("No runs yet this week. Yours could be the first.", bundle: .module)
                .typeStyle(.body).foregroundStyle(Color.dust)
                .padding(.horizontal, Space.margin)
                .padding(.top, Space.s24)
        } else {
            SectionLabel("THIS WEEK")
            ForEach(model.runs) { r in
                let mine = r.userID == model.myID
                Row(mine ? Text("You", bundle: .module) : Text(verbatim: r.displayName),
                    subtitle: Text(verbatim: Format.number(Double(r.trapMphX10) / 10, fractionDigits: 1) + " mph"),
                    trailing: {
                        Text(readout: Format.number(Double(r.etMs) / 1000, fractionDigits: 3), token: .readoutS)
                            .foregroundStyle(Color.chalk)
                    })
            }
        }
    }
}

/// `waypoints://debug/car-of-week`: the weekly board with "Run it".
struct DebugCarOfWeek: View {
    let env: AppEnvironment
    @State private var model = CarOfWeekModel()

    var body: some View {
        NavigationStack {
            WeeklyBoardBody(model: model, env: env)
                .navigationTitle("Car of the week")
                .navigationBarTitleDisplayMode(.inline)
        }
        .task { await model.load(env: env) }
    }
}
