import Core
import DesignSystem
import PerformanceModel
import SwiftUI
import VehicleCatalog

/// A bench-race opponent (STR-10): a catalog car, stock or with mods from `ModCatalog`, run by
/// the model with a clean launch, like a house car.
struct BenchCar: Hashable {
    let label: String
    let spec: VehicleSpec
    let mods: [String]

    var title: String {
        mods.isEmpty ? "\(label) · stock" : "\(label) · \(mods.count) mod\(mods.count == 1 ? "" : "s")"
    }
}

/// Pick the car with the vehicle picker, then its mods.
struct BenchPicker: View {
    let env: AppEnvironment
    let done: (BenchCar) -> Void
    @State private var car: Car?
    @State private var spec: VehicleSpec?
    @State private var available: [Mod] = []
    @State private var chosen: Set<String> = []
    @State private var noSpec = false

    var body: some View {
        NavigationStack {
            Group {
                if let car, let spec {
                    mods(car: car, spec: spec)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        if noSpec {
                            Text("The catalog has no power figure for that car. Pick another.")
                                .typeStyle(.foot).foregroundStyle(Color.brake).padding(.horizontal, Space.margin)
                        }
                        VehiclePicker(catalog: env.catalog, actionTitle: "Race this car") { picked in
                            guard case let .car(new) = picked else { return }
                            Task { await choose(new) }
                        }
                    }
                }
            }
            .background(Color.asphalt.ignoresSafeArea())
            .navigationTitle("Bench race")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func mods(car: Car, spec: VehicleSpec) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s16) {
                Text(verbatim: car.fullLabel).typeStyle(.title).foregroundStyle(Color.chalk)
                Text(verbatim: HouseCar(rung: 0, spec: spec).specLine).typeStyle(.sub).foregroundStyle(Color.dust)
                if !available.isEmpty {
                    SectionLabel("MODS")
                    ForEach(available) { m in
                        Button { toggle(m) } label: {
                            Row(Text(verbatim: m.name), subtitle: Text(verbatim: m.rangeText(base: spec.hpCrank)), trailing: {
                                Image(systemName: chosen.contains(m.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(chosen.contains(m.id) ? Color.sodium : Color.gravel)
                            })
                        }
                        .buttonStyle(RowButtonStyle())
                    }
                }
                PrimaryButton(chosen.isEmpty ? "Race it stock" : "Race it with these mods") {
                    let ids = available.map(\.id).filter(chosen.contains)
                    done(BenchCar(label: car.fullLabel, spec: spec, mods: ids))
                }
                QuietButton("Pick another car") { self.car = nil; self.spec = nil; chosen = [] }
            }
            .padding(Space.margin)
        }
    }

    private func toggle(_ m: Mod) {
        if chosen.contains(m.id) {
            chosen.remove(m.id)
            return
        }
        chosen.subtract(m.conflicts)
        for other in chosen.compactMap(ModCatalog.mod) where other.conflicts.contains(m.id) { chosen.remove(other.id) }
        chosen.insert(m.id)
        for r in m.requires { chosen.insert(r) }
    }

    private func choose(_ new: NewCar) async {
        var variant: CatalogVariant?
        if let id = new.catalogVariantID { variant = try? await env.catalog.variant(id) }
        let c = Car(ownerID: UserID(raw: UUID()), catalogVariantID: new.catalogVariantID, year: new.year, make: new.make,
                    model: new.model, trim: new.trim)
        guard let s = VehicleSpec.from(variant: variant, car: c) else { noSpec = true; return }
        noSpec = false
        available = ModCatalog.available(for: s, platform: ModCatalog.platform(for: c, variant: variant))
        spec = s
        car = c
    }
}
