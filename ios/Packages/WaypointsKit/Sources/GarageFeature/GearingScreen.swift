import Core
import DesignSystem
import PerformanceModel
import SwiftUI

// GAR-17: gearing and tires. Worked out on the device from the catalog's gear ratios and
// redline. The catalog carries neither tire size nor final drive, so the owner enters the
// stock ones; they are kept on this device only.

/// What the owner typed for one car, stored in `UserDefaults`.
struct GearingInput: Codable, Equatable {
    var width = ""
    var aspect = ""
    var rim = ""
    var finalDrive = ""
    var redline = ""
    var cruise = GarageUnits.drivesInMiles ? "70" : "110"
    var newWidth = ""
    var newAspect = ""
    var newRim = ""
    var newFinalDrive = ""

    private static func key(_ car: CarID) -> String { "gearing.\(car)" }

    static func load(_ car: CarID) -> GearingInput {
        UserDefaults.standard.data(forKey: key(car)).flatMap { try? JSONDecoder().decode(GearingInput.self, from: $0) }
            ?? GearingInput()
    }

    func save(_ car: CarID) {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key(car))
    }

    static func number(_ text: String, in range: ClosedRange<Double>) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: ".")).flatMap { range.contains($0) ? $0 : nil }
    }

    static func tire(_ width: String, _ aspect: String, _ rim: String) -> TireSize? {
        guard let w = Double(width), let a = Double(aspect), let r = Double(rim.replacingOccurrences(of: ",", with: ".")) else { return nil }
        return TireSize(widthMM: w, aspect: a, rimIn: r)
    }

    var stockTire: TireSize? { Self.tire(width, aspect, rim) }
    var newTire: TireSize? { Self.tire(newWidth, newAspect, newRim) }
    var stockFinalDrive: Double? { Self.number(finalDrive, in: 1.5...8) }
    var changedFinalDrive: Double? { Self.number(newFinalDrive, in: 1.5...8) }
}

struct GearingScreen: View {
    let car: Car
    let variant: CatalogVariant?
    @State private var input: GearingInput

    init(car: Car, variant: CatalogVariant?) {
        self.car = car
        self.variant = variant
        _input = State(initialValue: GearingInput.load(car.id))
    }

    private var gears: [Double]? {
        let ratios = (car.specOverrides.gears ?? variant?.gears)?.filter { $0 > 0 && $0.isFinite }
        return ratios?.isEmpty == false ? ratios : nil
    }

    private var knownRedline: Int? { car.specOverrides.redline ?? variant?.redline }

    private var redline: Double? {
        knownRedline.map(Double.init) ?? GearingInput.number(input.redline, in: 1000...20000)
    }

    private var cruise: Double? { GearingInput.number(input.cruise, in: 1...400) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                stockSetup
                gearSpeeds
                comparison
                Text("Worked out from nominal tire sizes; a tire under load measures slightly smaller. Speedometer error assumes the speedometer is driven from the transmission.", bundle: .module)
                    .typeStyle(.foot).foregroundStyle(Color.dust)
                    .padding(.horizontal, Space.margin).padding(.top, Space.s24)
            }
            .padding(.bottom, Space.s48)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.asphalt.ignoresSafeArea())
        .navigationTitle(Text("Gearing and tires", bundle: .module))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: input) { input.save(car.id) }
    }

    // MARK: Stock setup

    @ViewBuilder private var stockSetup: some View {
        SectionLabel("STOCK SETUP")
        VStack(alignment: .leading, spacing: Space.s16) {
            Text("The catalog doesn't list tire size or final drive. Enter the stock ones: the tire size is on the door-jamb sticker, the final drive is in the owner's manual.", bundle: .module)
                .typeStyle(.sub).foregroundStyle(Color.dust)
            tireFields(width: $input.width, aspect: $input.aspect, rim: $input.rim)
            if tireInvalid(input.width, input.aspect, input.rim) { tireError }
            Field("Final drive ratio", text: $input.finalDrive, prompt: "Like 3.73", limit: 5).keyboardType(.decimalPad)
            if gears != nil, knownRedline == nil {
                Text("The catalog has no redline for this car. Enter it from the tachometer.", bundle: .module)
                    .typeStyle(.sub).foregroundStyle(Color.dust)
                Field("Redline (rpm)", text: $input.redline, limit: 5).keyboardType(.numberPad)
            }
        }
        .padding(.horizontal, Space.margin)
    }

    private func tireFields(width: Binding<String>, aspect: Binding<String>, rim: Binding<String>) -> some View {
        HStack(alignment: .top, spacing: Space.s12) {
            Field("Width", text: width, prompt: "mm", limit: 3).keyboardType(.numberPad)
            Field("Aspect", text: aspect, prompt: "%", limit: 2).keyboardType(.numberPad)
            Field("Rim", text: rim, prompt: "in", limit: 4).keyboardType(.decimalPad)
        }
    }

    private func tireInvalid(_ width: String, _ aspect: String, _ rim: String) -> Bool {
        !width.isEmpty && !aspect.isEmpty && !rim.isEmpty && GearingInput.tire(width, aspect, rim) == nil
    }

    private var tireError: some View {
        Text("That isn't a tire size. Use the three numbers on the sidewall, like 245 / 40 / 18.", bundle: .module)
            .typeStyle(.foot).foregroundStyle(Color.brake)
    }

    private func note(_ text: Text) -> some View {
        text.typeStyle(.body).foregroundStyle(Color.dust).padding(.horizontal, Space.margin)
    }

    // MARK: Speed in each gear, cruising rpm

    @ViewBuilder private var gearSpeeds: some View {
        SectionLabel("SPEED AT REDLINE")
        if let gears {
            if let redline, let tire = input.stockTire, let drive = input.stockFinalDrive {
                ForEach(Array(gears.enumerated()), id: \.offset) { index, ratio in
                    Row(Text("Gear \(index + 1)", bundle: .module), subtitle: Text(verbatim: Format.number(ratio, fractionDigits: 3)),
                        showsDivider: index < gears.count - 1, trailing: {
                            Readout(GarageUnits.speed(metersPerSecond: Gearing.speed(rpm: redline, gear: ratio, finalDrive: drive, tire: tire)),
                                    unit: GarageUnits.speedSymbol)
                        })
                }
                Text("At \(Int(redline).formatted(.number)) rpm.", bundle: .module)
                    .typeStyle(.foot).foregroundStyle(Color.dust).padding(.horizontal, Space.margin).padding(.top, Space.s8)
            } else {
                note(Text("Fill in the stock setup above to see the speed in each gear.", bundle: .module))
            }
            SectionLabel("CRUISING")
            Field(GarageUnits.drivesInMiles ? "Cruising speed (mph)" : "Cruising speed (km/h)", text: $input.cruise, limit: 3)
                .keyboardType(.numberPad)
                .padding(.horizontal, Space.margin)
            if let cruise, let tire = input.stockTire, let drive = input.stockFinalDrive, let top = gears.last {
                let rpm = Gearing.rpm(speed: GarageUnits.metersPerSecond(cruise), gear: top, finalDrive: drive, tire: tire)
                Row(Text("Engine speed in top gear", bundle: .module), showsDivider: false, trailing: {
                    Readout(Int(rpm.rounded()).formatted(.number), unit: "rpm")
                })
            } else {
                note(Text("Fill in the stock setup above to see rpm at this speed.", bundle: .module)).padding(.top, Space.s12)
            }
        } else {
            note(Text("The catalog has no gear ratios for this car, so there is no speed in each gear or cruising rpm to show. The tire comparison below still works.", bundle: .module))
        }
    }

    // MARK: Different tire or final drive

    @ViewBuilder private var comparison: some View {
        SectionLabel("DIFFERENT TIRE OR FINAL DRIVE")
        VStack(alignment: .leading, spacing: Space.s16) {
            tireFields(width: $input.newWidth, aspect: $input.newAspect, rim: $input.newRim)
            if tireInvalid(input.newWidth, input.newAspect, input.newRim) { tireError }
            Field("Final drive ratio", text: $input.newFinalDrive, prompt: "Same as stock", limit: 5).keyboardType(.decimalPad)
        }
        .padding(.horizontal, Space.margin)
        if let ratio = speedometerRatio {
            // What the speedometer shows relative to the true speed.
            let error = (1 / ratio - 1) * 100
            Row(Text("Speedometer error", bundle: .module),
                subtitle: abs(error) < 0.05 ? Text("Reads true", bundle: .module)
                    : error < 0 ? Text("Reads lower than you are going", bundle: .module)
                    : Text("Reads higher than you are going", bundle: .module),
                trailing: { Readout(Format.delta(error, fractionDigits: 1), unit: "%") })
                .padding(.top, Space.s12)
            if let cruise {
                Row(Text("True speed when it shows \(Int(cruise).formatted(.number)) \(GarageUnits.speedSymbol)", bundle: .module), showsDivider: false, trailing: {
                    Readout(Format.number(cruise * ratio, fractionDigits: 1), unit: GarageUnits.speedSymbol)
                })
            }
        } else {
            note(Text("Enter the stock tire size above and a different tire size or final drive here to see the speedometer error.", bundle: .module))
                .padding(.top, Space.s12)
        }
    }

    /// True speed over shown speed. Needs the stock tire for a tire change and the stock
    /// final drive for a final drive change; `nil` when nothing was changed.
    private var speedometerRatio: Double? {
        let tires = input.stockTire.flatMap { stock in input.newTire.map { $0.diameterM / stock.diameterM } }
        let finals = input.stockFinalDrive.flatMap { stock in input.changedFinalDrive.map { stock / $0 } }
        guard tires != nil || finals != nil else { return nil }
        return (tires ?? 1) * (finals ?? 1)
    }
}

#if DEBUG
/// `waypoints://debug/gearing`: the signed-in user's first car that has gear ratios, else
/// their first car (which shows the "no gear ratios" state).
struct DebugGearing: View {
    let ctx: GarageContext
    @State private var car: Car?
    @State private var variant: CatalogVariant?

    var body: some View {
        NavigationStack {
            if let car { GearingScreen(car: car, variant: variant) } else { SkeletonRow() }
        }
        .task {
            guard let me = await ctx.env.auth.currentSession()?.userID,
                  let cars = try? await ctx.env.garage.cars(of: me), let first = cars.first else { return }
            var chosen = first
            for candidate in cars {
                guard let id = candidate.catalogVariantID, let v = try? await ctx.env.catalog.variant(id) else { continue }
                if candidate.id == first.id { variant = v }
                if v.gears?.isEmpty == false { chosen = candidate; variant = v; break }
            }
            // The preview seed's Civic Type R: its stock tire and final drive, and a taller tire to compare.
            if variant?.id == 1012, GearingInput.load(chosen.id).width.isEmpty {
                var seeded = GearingInput()
                seeded.width = "245"; seeded.aspect = "30"; seeded.rim = "20"; seeded.finalDrive = "4.111"
                seeded.newWidth = "255"; seeded.newAspect = "35"; seeded.newRim = "19"
                seeded.save(chosen.id)
            }
            car = chosen
        }
    }
}
#endif
