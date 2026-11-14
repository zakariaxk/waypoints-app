import Core
import DesignSystem
import SwiftUI

/// What the picker returns.
public enum PickedVehicle: Sendable, Hashable {
    /// Full mode: everything needed to create a car.
    case car(NewCar)
    /// Model-only mode (Spots).
    case model(make: String, model: String, modelID: Int64, year: Int?)
    /// Range mode (Market "Fits").
    case fitment(Fitment)
}

public enum PickerMode: Sendable, Hashable { case full, modelOnly, range }

/// The 16 paint families with representative colors (plan 11.1).
public enum PaintFamily: String, CaseIterable, Sendable {
    case black, white, silver, gray, red, maroon, orange, yellow, gold, green, teal, blue, navy, purple, brown, beige

    public var hex: String {
        switch self {
        case .black: "#111214"
        case .white: "#F2F2F0"
        case .silver: "#A7A9AC"
        case .gray: "#5E6266"
        case .red: "#B11226"
        case .maroon: "#5C1A22"
        case .orange: "#E2641B"
        case .yellow: "#F2C21B"
        case .gold: "#B8963E"
        case .green: "#2F6B3A"
        case .teal: "#1F7A80"
        case .blue: "#2B6CD1"
        case .navy: "#1C2A4A"
        case .purple: "#5B3A7A"
        case .brown: "#5A3B26"
        case .beige: "#CDBB98"
        }
    }

    public var title: String { rawValue.capitalized }
}

/// G4 Vehicle picker (plan 11.1): one question at a time, a breadcrumb of answers, search always on top.
public struct VehiclePicker: View {
    let catalog: any VehicleCatalogService
    let mode: PickerMode
    let markerIcon: String
    let actionTitle: LocalizedStringKey
    let onPick: @MainActor (PickedVehicle) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var results: [CatalogVariant] = []
    @State private var popular: [CatalogMake] = []
    @State private var allMakes: [CatalogMake] = []
    @State private var models: [CatalogModel] = []
    @State private var years: [Int] = []
    @State private var variants: [CatalogVariant] = []

    @State private var make: CatalogMake?
    @State private var model: CatalogModel?
    @State private var year: Int?
    @State private var yearTo: Int?
    @State private var variant: CatalogVariant?
    @State private var manualTrim: ManualTrim?
    @State private var family: PaintFamily?
    @State private var customColor: Color = .gray
    @State private var useCustom = false
    @State private var paintName = ""
    @State private var showVIN = false
    @State private var vin = ""
    @State private var vinError: String?
    @State private var scanning = false
    @State private var tick = 0

    struct ManualTrim: Hashable { var trim = ""; var engine = ""; var drive = "" }
    /// The free-text car typed after "Mine isn't listed" at the make or model step (GAR-3).
    struct UnlistedCar: Hashable { var make = ""; var model = ""; var year = ""; var trim = "" }

    public init(catalog: any VehicleCatalogService, mode: PickerMode = .full, markerIcon: String = "coupe",
                actionTitle: LocalizedStringKey = "Add to garage", onPick: @escaping @MainActor (PickedVehicle) -> Void) {
        self.catalog = catalog; self.mode = mode; self.markerIcon = markerIcon; self.actionTitle = actionTitle
        self.onPick = onPick
    }

    private enum Step: Hashable { case make, model, year, yearTo, trim, color }

    private var step: Step {
        guard make != nil else { return .make }
        guard model != nil else { return .model }
        switch mode {
        case .modelOnly: return .year
        case .range: return year == nil ? .year : .yearTo
        case .full:
            if year == nil { return .year }
            if variant == nil && manualTrim == nil { return .trim }
            return .color
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            Field("Search", text: $query, prompt: "Search, like '2019 mustang gt'")
                .padding(.horizontal, Space.margin)
                .padding(.top, Space.s8)
            breadcrumb
            ScrollView {
                if !query.isEmpty {
                    searchResults
                } else {
                    stepView.transition(.opacity)
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Color.asphalt)
        .motion(.standard, value: step)
        .haptic(.tick, trigger: tick)
        .toolbar {
            if mode == .full {
                ToolbarItem(placement: .topBarTrailing) { QuietButton("Use VIN") { showVIN = true } }
            }
        }
        .sheet(isPresented: $showVIN) { vinSheet }
        .task {
            popular = (try? await catalog.popularMakes()) ?? []
            allMakes = (try? await catalog.makes()) ?? []
        }
        .task(id: query) {
            guard !query.isEmpty else { results = []; return }
            try? await Task.sleep(for: .milliseconds(150))
            results = (try? await catalog.search(query, limit: 8)) ?? []
        }
    }

    // MARK: Breadcrumb

    @ViewBuilder private var breadcrumb: some View {
        let tokens: [(String, () -> Void)] = [
            make.map { m in (m.name, { clear(from: .make) }) },
            model.map { m in (m.name, { clear(from: .model) }) },
            year.map { y in (String(y), { clear(from: .year) }) },
            yearTo.map { y in ("to \(y)", { clear(from: .yearTo) }) },
            (variant?.trim ?? (manualTrim?.trim.isEmpty == false ? manualTrim?.trim : nil)).map { t in (t, { clear(from: .trim) }) },
        ].compactMap { $0 }
        if !tokens.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.s4) {
                    ForEach(Array(tokens.enumerated()), id: \.offset) { index, token in
                        if index > 0 { Text(verbatim: "·").foregroundStyle(Color.gravel) }
                        Button(token.0, action: token.1).typeStyle(.sub).foregroundStyle(Color.sodium)
                    }
                }
                .padding(.horizontal, Space.margin)
                .padding(.vertical, Space.s8)
            }
        }
    }

    private func clear(from step: Step) {
        switch step {
        case .make: make = nil; fallthrough
        case .model: model = nil; fallthrough
        case .year: year = nil; fallthrough
        case .yearTo: yearTo = nil; fallthrough
        case .trim: variant = nil; manualTrim = nil; fallthrough
        case .color: family = nil
        }
        unlistedAt = nil
    }

    // MARK: Steps

    @ViewBuilder private var stepView: some View {
        switch step {
        case .make: makeStep
        case .model: modelStep
        case .year: yearStep(title: mode == .range ? "From" : "Year")
        case .yearTo: yearStep(title: "To")
        case .trim: trimStep
        case .color: colorStep
        }
    }

    private var makeStep: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if !popular.isEmpty {
                SectionLabel("Popular")
                ForEach(popular) { m in makeRow(m) }
            }
            SectionLabel("All makes")
            ForEach(allMakes) { m in makeRow(m) }
            unlistedEntry(at: .make)
        }
    }

    private func makeRow(_ m: CatalogMake) -> some View {
        Button {
            make = m
            Task { models = (try? await catalog.models(of: m.id)) ?? [] }
        } label: { Row(Text(verbatim: m.name)) }
            .buttonStyle(RowButtonStyle())
    }

    private var modelStep: some View {
        let current = models.filter { $0.yearTo >= Calendar.current.component(.year, from: .now) - 1 }
        let older = models.filter { !current.contains($0) }
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(current) { modelRow($0) }
            if !older.isEmpty {
                SectionLabel("Older models")
                ForEach(older) { modelRow($0) }
            }
            unlistedEntry(at: .model)
        }
    }

    // MARK: Mine isn't listed (make and model steps)

    @State private var unlistedAt: Step?
    @State private var draftCar = UnlistedCar()

    private var currentYear: Int { Calendar.current.component(.year, from: .now) }

    /// The typed year when it is a plausible model year, otherwise nil.
    private var draftYear: Int? {
        guard let y = Int(draftCar.year.trimmingCharacters(in: .whitespaces)), (1886...currentYear + 2).contains(y) else { return nil }
        return y
    }

    private func draftReady(at step: Step) -> Bool {
        let makeName = step == .make ? draftCar.make : (make?.name ?? "")
        guard !makeName.trimmingCharacters(in: .whitespaces).isEmpty,
              !draftCar.model.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        // A car needs its year; Spots and Fits can leave it open, but not half typed.
        if mode == .full { return draftYear != nil }
        return draftCar.year.isEmpty || draftYear != nil
    }

    @ViewBuilder private func unlistedEntry(at step: Step) -> some View {
        if unlistedAt == step {
            VStack(spacing: Space.s12) {
                if step == .make {
                    Field("Make", text: $draftCar.make, prompt: "Like 'Datsun'", limit: 40)
                }
                Field("Model", text: $draftCar.model, prompt: "Like 'Skyline GT-R'", limit: 60)
                Field(mode == .full ? LocalizedStringKey("Year") : LocalizedStringKey("Year (optional)"),
                      text: $draftCar.year, prompt: "Like '1999'", limit: 4)
                    .keyboardType(.numberPad)
                if mode == .full {
                    Field("Trim (optional)", text: $draftCar.trim, prompt: "Like 'V-Spec'", limit: 40)
                }
                SecondaryButton("Use this") { useUnlisted(at: step) }
                    .disabled(!draftReady(at: step))
            }
            .padding(Space.margin)
        } else {
            Button {
                draftCar = UnlistedCar()
                unlistedAt = step
            } label: { Row(Text("Mine isn't listed", bundle: .module), showsDivider: false) }
                .buttonStyle(RowButtonStyle())
        }
    }

    /// Stores the typed car as text: no catalog ids, straight to colour (or back to the caller
    /// in model-only and range modes).
    private func useUnlisted(at step: Step) {
        guard draftReady(at: step) else { return }
        let makeName = step == .make ? draftCar.make.trimmingCharacters(in: .whitespaces) : (make?.name ?? "")
        let modelName = draftCar.model.trimmingCharacters(in: .whitespaces)
        let trim = draftCar.trim.trimmingCharacters(in: .whitespaces)
        tick += 1
        switch mode {
        case .modelOnly:
            onPick(.model(make: makeName, model: modelName, modelID: 0, year: draftYear))
        case .range:
            onPick(.fitment(Fitment(make: makeName, model: modelName, yearFrom: draftYear, yearTo: draftYear)))
        case .full:
            guard let y = draftYear else { return }
            let picked = step == .make ? CatalogMake(id: -1, name: makeName) : (make ?? CatalogMake(id: -1, name: makeName))
            make = picked
            model = CatalogModel(id: -1, makeID: picked.id, name: modelName, yearFrom: y, yearTo: y)
            year = y
            variants = []
            variant = nil
            manualTrim = ManualTrim(trim: trim)
        }
        unlistedAt = nil
    }

    private func modelRow(_ m: CatalogModel) -> some View {
        Button {
            model = m
            Task { years = (try? await catalog.years(of: m.id)) ?? Array((m.yearFrom...m.yearTo).reversed()) }
        } label: {
            Row(Text(verbatim: m.name), trailing: {
                Text(verbatim: "\(m.yearFrom)–\(m.yearTo)").typeStyle(.readoutS)
            })
        }
        .buttonStyle(RowButtonStyle())
    }

    private func yearStep(title: LocalizedStringKey) -> some View {
        let options = step == .yearTo ? years.filter { $0 >= (year ?? 0) } : years
        return VStack(alignment: .leading, spacing: 0) {
            SectionLabel(title)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.s8) {
                    ForEach(options, id: \.self) { y in
                        Button {
                            tick += 1
                            pickYear(y)
                        } label: {
                            Text(verbatim: String(y)).typeStyle(.readoutM).foregroundStyle(Color.chalk)
                                .frame(minWidth: Size.hitTarget * 1.4, minHeight: Size.control)
                                .background(Color.concrete, in: RoundedRectangle(cornerRadius: Radius.r12))
                        }
                    }
                }
                .padding(.horizontal, Space.margin)
            }
            if mode == .modelOnly, let make, let model {
                QuietButton("Any year") {
                    onPick(.model(make: make.name, model: model.name, modelID: model.id, year: nil))
                }
                .padding(Space.margin)
            }
        }
    }

    private func pickYear(_ y: Int) {
        guard let make, let model else { return }
        switch (mode, step) {
        case (.modelOnly, _):
            onPick(.model(make: make.name, model: model.name, modelID: model.id, year: y))
        case (.range, .yearTo):
            yearTo = y
            onPick(.fitment(Fitment(make: make.name, model: model.name, yearFrom: year, yearTo: y)))
        default:
            year = y
            guard mode == .full else { return }
            Task {
                variants = (try? await catalog.variants(of: model.id, year: y)) ?? []
                if variants.count == 1 { variant = variants[0] }
                if variants.isEmpty { manualTrim = ManualTrim() }
            }
        }
    }

    @State private var draftTrim = ManualTrim()
    @State private var showManual = false

    private var trimStep: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(variants) { v in
                Button { variant = v } label: {
                    Row(Text(verbatim: v.trim ?? "Base"),
                        subtitle: Text(verbatim: [v.engine, v.drive?.rawValue.uppercased(), v.transmission].compactMap { $0 }.joined(separator: " · ")))
                }
                .buttonStyle(RowButtonStyle())
            }
            if showManual {
                VStack(spacing: Space.s12) {
                    Field("Trim", text: $draftTrim.trim, prompt: "Like 'GT Premium'")
                    Field("Engine", text: $draftTrim.engine, prompt: "Like '5.0 L V8'")
                    Field("Drive", text: $draftTrim.drive, prompt: "RWD, FWD, AWD, or 4WD")
                    SecondaryButton("Use this") { manualTrim = draftTrim }
                }
                .padding(Space.margin)
            } else {
                Button { showManual = true } label: { Row(Text("Mine isn't listed", bundle: .module), showsDivider: false) }
                    .buttonStyle(RowButtonStyle())
            }
        }
    }

    private var paint: Color {
        if useCustom { return customColor }
        return family.flatMap { Color(paintHex: $0.hex) } ?? .dust
    }

    private var colorStep: some View {
        VStack(alignment: .leading, spacing: Space.s16) {
            SilhouetteIcon(markerIcon, paint: paint)
                .frame(width: Size.Marker.you * 3, height: Size.Marker.you * 3)
                .frame(maxWidth: .infinity)
                .padding(.top, Space.s16)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.s8), count: 8), spacing: Space.s8) {
                ForEach(PaintFamily.allCases, id: \.self) { f in
                    Button {
                        family = f
                        useCustom = false
                        tick += 1
                    } label: {
                        Circle().fill(Color(paintHex: f.hex) ?? .dust)
                            .overlay(Circle().strokeBorder(family == f && !useCustom ? Color.sodium : Color.seam,
                                                           lineWidth: Size.Marker.ring))
                            .frame(height: Size.hitTarget)
                    }
                    .accessibilityLabel(Text(verbatim: f.title))
                }
            }
            ColorPicker(selection: $customColor, supportsOpacity: false) {
                Text("Exact color", bundle: .module).typeStyle(.body).foregroundStyle(Color.chalk)
            }
            .onChange(of: customColor) { useCustom = true }
            Field("Paint name", text: $paintName, prompt: "Like 'Grabber Blue'", limit: 40)
            PrimaryButton(actionTitle) { finish() }
                .disabled(family == nil && !useCustom)
        }
        .padding(.horizontal, Space.margin)
        .padding(.bottom, Space.s24)
    }

    private func finish() {
        guard let make, let model, let year else { return }
        let hex = useCustom ? customColor.hexString : family?.hex
        onPick(.car(NewCar(catalogVariantID: variant?.id, year: year, make: make.name, model: model.name,
                           trim: variant?.trim ?? (manualTrim?.trim.isEmpty == false ? manualTrim?.trim : nil),
                           colorFamily: useCustom ? nil : family?.rawValue, colorHex: hex,
                           paintName: paintName.isEmpty ? nil : paintName)))
    }

    // MARK: Search

    private var searchResults: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if results.isEmpty {
                Text("Nothing found for '\(query)'.", bundle: .module).typeStyle(.sub).foregroundStyle(Color.dust).padding(Space.margin)
            }
            ForEach(results) { v in
                Button { jump(to: v) } label: {
                    Row(Text(verbatim: v.label),
                        subtitle: Text(verbatim: [v.engine, v.transmission].compactMap { $0 }.joined(separator: " · ")))
                }
                .buttonStyle(RowButtonStyle())
            }
        }
    }

    private func jump(to v: CatalogVariant) {
        query = ""
        let m = CatalogMake(id: -1, name: v.make)
        make = allMakes.first { $0.name == v.make } ?? m
        model = CatalogModel(id: v.modelID, makeID: make?.id ?? -1, name: v.model, yearFrom: v.year, yearTo: v.year)
        switch mode {
        case .full:
            year = v.year
            variant = v
        case .modelOnly:
            onPick(.model(make: v.make, model: v.model, modelID: v.modelID, year: v.year))
        case .range:
            year = v.year
            Task { years = (try? await catalog.years(of: v.modelID)) ?? [v.year] }
        }
    }

    // MARK: VIN

    private var vinSheet: some View {
        Sheet(Text("Use VIN", bundle: .module)) {
            VStack(spacing: Space.s16) {
                Field("VIN", text: $vin, prompt: "17 characters", limit: 17,
                      error: vinError.map { Text(verbatim: $0) })
                if VINScanner.isAvailable {
                    SecondaryButton("Scan with the camera") { scanning = true }
                }
                PrimaryButton("Look up") {
                    Task {
                        do {
                            let d = try await catalog.decodeVIN(vin)
                            if let id = d.variantID, let v = try await catalog.variant(id) {
                                jump(to: v)
                            } else if let makeName = d.make, let found = allMakes.first(where: { $0.name.lowercased() == makeName.lowercased() }) {
                                make = found
                                models = (try? await catalog.models(of: found.id)) ?? []
                            }
                            showVIN = false
                        } catch WaypointsError.offline {
                            vinError = "VIN lookup needs a connection."
                        } catch {
                            vinError = "That VIN didn't decode. Check the 17 characters."
                        }
                    }
                }
                .disabled(vin.count != 17)
            }
            .padding(Space.margin)
        }
        .presentationDetents([.medium])
        .fullScreenCover(isPresented: $scanning) {
            VINScanner { found in
                vin = found
                scanning = false
            }
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                IconButton(Symbol.close, label: "Close", style: .overMap) { scanning = false }.padding(Space.margin)
            }
        }
    }
}

extension Color {
    /// "#RRGGBB" for a picked custom color.
    var hexString: String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
