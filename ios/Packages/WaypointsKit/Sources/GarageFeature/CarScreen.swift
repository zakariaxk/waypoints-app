import Core
import DesignSystem
import PerformanceModel
import PhotosUI
import SwiftUI

// MARK: G3 Car

@MainActor
@Observable
final class CarModel {
    let ctx: GarageContext
    let carID: CarID
    var car: Car?
    var owner: Profile?
    var photos: [CarPhoto] = []
    var entries: [BuildEntry] = []
    /// GAR-18: cost in cents per entry. Only ever filled for the owner.
    var costs: [BuildEntryID: Int] = [:]
    var variant: CatalogVariant?
    var showdown: ShowdownEntry?
    var me: UserID?
    var uploading = false
    var failed = false

    init(ctx: GarageContext, carID: CarID) { self.ctx = ctx; self.carID = carID }

    var own: Bool { car?.ownerID == me }

    var estimate: Estimate? {
        guard let car, let spec = VehicleSpec.from(variant: variant, car: car) else { return nil }
        return PerformanceModel.estimate(base: spec, mods: car.mods.compactMap(ModCatalog.mod))
    }

    func load() async {
        let env = ctx.env
        me = await env.auth.currentSession()?.userID
        guard let c = try? await env.garage.car(carID) else { failed = car == nil; return }
        failed = false
        car = c
        owner = try? await env.profiles.profile(c.ownerID)
        photos = (try? await env.garage.photos(of: carID)) ?? []
        entries = ((try? await env.garage.buildEntries(of: carID)) ?? []).sorted { $0.happenedOn > $1.happenedOn }
        costs = c.ownerID == me ? ((try? await env.garage.buildCosts(of: carID)) ?? [:]) : [:]
        if let v = c.catalogVariantID { variant = try? await env.catalog.variant(v) }
        showdown = try? await env.showdown.entry(for: carID)
    }

    func addPhoto(_ item: PhotosPickerItem) async -> Bool {
        uploading = true
        defer { uploading = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return false }
            let media = try await ctx.env.media.upload(data, contentType: "image/jpeg", to: .cars, progress: { _ in })
            try await ctx.env.garage.addPhoto(to: carID, media: media)
            photos = (try? await ctx.env.garage.photos(of: carID)) ?? photos
            return true
        } catch {
            return false
        }
    }
}

struct CarScreen: View {
    let ctx: GarageContext
    @State private var model: CarModel
    @State private var addEntry = false
    @State private var photoItem: PhotosPickerItem?
    @State private var pickPhoto = false
    @State private var enterClass: ShowdownClass = .street
    @State private var askShowdown = false
    @State private var confirmDelete = false
    @State private var editSpecs = false
    @State private var shared: SharedImage?
    @State private var toast: ToastMessage?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    init(ctx: GarageContext, carID: CarID) {
        self.ctx = ctx
        _model = State(initialValue: CarModel(ctx: ctx, carID: carID))
    }

    var body: some View {
        ScrollView {
            if let car = model.car {
                VStack(alignment: .leading, spacing: 0) {
                    pager
                    titleBlock(car)
                    if let est = model.estimate { readouts(est, car: car) }
                    if model.own { ownActions(car) } else { otherActions(car) }
                    timeline
                    costSummary
                    specs(car)
                }
                .padding(.bottom, Space.s48)
            } else if model.failed {
                ErrorState(Text("Couldn't load this car. Check your connection and try again.", bundle: .module)) {
                    Task { await model.load() }
                }
                .padding(.top, Space.s48)
            } else {
                SkeletonBlock(height: Size.row * 4).padding(Space.margin)
            }
        }
        .background(Color.asphalt.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.own {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Share build") { shareBuild() }
                        Button("Make primary car") {
                            Task {
                                do {
                                    try await ctx.env.profiles.updateMyProfile(ProfileUpdate(primaryCarID: model.carID))
                                    toast = ToastMessage(Text("Primary car set", bundle: .module))
                                } catch { toast = ToastMessage(Text(GarageCopy.failed)) }
                            }
                        }
                        Button("Delete car", role: .destructive) { confirmDelete = true }
                    } label: { Image.symbol(Symbol.more).frame(minWidth: Size.hitTarget, minHeight: Size.hitTarget) }
                    .accessibilityLabel(Text("More options", bundle: .module))
                }
            } else if let car = model.car {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Share build") { shareBuild() }
                        Button("Report") { ctx.env.router.open(.reportContent(ContentRef(kind: .car, id: car.id.description))) }
                    } label: { Image.symbol(Symbol.more).frame(minWidth: Size.hitTarget, minHeight: Size.hitTarget) }
                    .accessibilityLabel(Text("More options", bundle: .module))
                }
            }
        }
        .confirmationDialog("Delete this car?", isPresented: $confirmDelete) {
            Button("Delete car", role: .destructive) {
                Task {
                    do {
                        try await ctx.env.garage.deleteCar(model.carID)
                        for e in model.entries where e.remindOn != nil { ServiceReminder.cancel(e.id) }
                        dismiss()
                    } catch { toast = ToastMessage(Text(GarageCopy.failed)) }
                }
            }
        } message: { Text("Its photos and timeline are deleted too.", bundle: .module) }
        .sheet(isPresented: $addEntry) {
            if let car = model.car {
                TimelineEntrySheet(ctx: ctx, car: car, variant: model.variant) { Task { await model.load() } }
            }
        }
        .sheet(isPresented: $editSpecs) {
            if let car = model.car {
                SpecSheet(ctx: ctx, car: car, variant: model.variant) { model.car = $0 }
            }
        }
        .confirmationDialog("Enter Showdown", isPresented: $askShowdown) {
            ForEach(ShowdownClass.allCases, id: \.self) { c in
                Button(c.rawValue.capitalized) {
                    Task {
                        do { model.showdown = try await ctx.env.showdown.enter(model.carID, class: c) } catch WaypointsError.rateLimited {
                            toast = ToastMessage(Text(GarageCopy.rateLimited))
                        } catch { toast = ToastMessage(Text(GarageCopy.failed)) }
                    }
                }
            }
        } message: { Text("Needs at least one photo.", bundle: .module) }
        .sheet(item: $shared) { ShareSheet(items: [$0.image]).presentationDetents([.medium, .large]) }
        .photosPicker(isPresented: $pickPhoto, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) {
            if let item = photoItem {
                Task {
                    let added = await model.addPhoto(item)
                    if !added { toast = ToastMessage(Text("Couldn't add the photo. Check your connection and try again.", bundle: .module)) }
                    photoItem = nil
                }
            }
        }
        .toast($toast)
        .task { await model.load() }
    }

    /// GAR-15: renders the build card and hands it to the share sheet.
    private func shareBuild() {
        guard let car = model.car else { return }
        Task {
            let image = await BuildShare.render(car: car, photoURL: ctx.url(.cars, model.photos.first?.path),
                                                estimate: model.estimate, handle: model.owner?.handle,
                                                silhouette: model.owner?.markerIcon ?? "coupe", scale: displayScale)
            if let image { shared = SharedImage(image: image) }
        }
    }

    private var pager: some View {
        TabView {
            if model.photos.isEmpty {
                ZStack {
                    Color.concrete
                    if let car = model.car {
                        SilhouetteIcon(model.owner?.markerIcon ?? "coupe", paint: car.paint).padding(Space.s48)
                    }
                }
            }
            ForEach(model.photos) { p in
                MediaView(url: ctx.url(.cars, p.path), aspectRatio: 4.0 / 3.0, cornerRadius: 0,
                          label: Text(verbatim: model.car?.fullLabel ?? ""))
            }
        }
        .tabViewStyle(.page)
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .overlay(alignment: .bottomTrailing) {
            if model.own {
                Button { pickPhoto = true } label: {
                    Image.symbol(Symbol.camera).foregroundStyle(Color.chalk)
                        .frame(width: Size.hitTarget, height: Size.hitTarget)
                        .overMapMaterial(in: Circle())
                }
                .buttonStyle(PressScaleStyle())
                .padding(Space.s12)
                .accessibilityLabel(Text("Add a photo", bundle: .module))
            }
        }
    }

    private func titleBlock(_ car: Car) -> some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            if let nick = car.nickname { Text(verbatim: nick).typeStyle(.display).foregroundStyle(Color.chalk) }
            Text(verbatim: car.fullLabel).typeStyle(.title).foregroundStyle(Color.chalk)
            let sub = [car.trim, car.paintName].compactMap { $0 }.joined(separator: " · ")
            if !sub.isEmpty { Text(verbatim: sub).typeStyle(.sub).foregroundStyle(Color.dust) }
        }
        .padding(.horizontal, Space.margin)
        .padding(.top, Space.s16)
    }

    private func readouts(_ e: Estimate, car: Car) -> some View {
        Button { if model.own, ctx.registry.canOpen(.modSim(car.id)) { ctx.env.router.open(.modSim(car.id)) } } label: {
            VStack(alignment: .leading, spacing: Space.s8) {
                HStack(alignment: .top, spacing: Space.s12) {
                    readout(e.hp, "EST. HP", digits: 0, bounds: 0...1200)
                    readout(e.torque, "EST. TQ", digits: 0, bounds: 0...1000)
                    readout(e.zeroToSixty, "0–60", digits: 1, unit: "s", bounds: 2...12)
                    readout(e.quarterET, "¼ MILE", digits: 1, unit: "s", bounds: 8...18)
                }
                Text("Estimates from stock specs and listed mods.", bundle: .module).typeStyle(.foot).foregroundStyle(Color.dust)
            }
            .padding(.horizontal, Space.margin)
            .padding(.top, Space.s24)
        }
        .buttonStyle(PressScaleStyle())
    }

    private func readout(_ r: ClosedRange<Double>, _ label: LocalizedStringKey, digits: Int, unit: String? = nil,
                         bounds: ClosedRange<Double>) -> some View {
        Readout(Format.number((r.lowerBound + r.upperBound) / 2, fractionDigits: digits), unit: unit, label: label,
                range: .init(low: r.lowerBound, high: r.upperBound, bounds: bounds))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func ownActions(_ car: Car) -> some View {
        VStack(spacing: 0) {
            if ctx.registry.canOpen(.modSim(car.id)) {
                actionRow("Mod simulator") { ctx.env.router.open(.modSim(car.id)) }
            }
            if ctx.registry.canOpen(.race(car.id)) {
                actionRow("Run the strip") { ctx.env.router.open(.race(car.id)) }
            }
            if ctx.registry.canOpen(.shop(car.id)) {
                actionRow("Open in shop") { ctx.env.router.open(.shop(car.id)) }
            }
            if ctx.registry.canOpen(.drive(car.id)) {
                actionRow("Test drive") { ctx.env.router.open(.drive(car.id)) }
            }
            if let entry = model.showdown {
                Row(Text("In Showdown · \(entry.showdownClass.rawValue.capitalized)", bundle: .module),
                    trailing: { Text(verbatim: entry.rating.formatted(.number)).typeStyle(.readoutS) })
            } else if !ctx.registry.feedModes.isEmpty {
                actionRow("Enter Showdown") { askShowdown = true }
                    .disabled(model.photos.isEmpty)
            }
            NavigationLink { GearingScreen(car: car, variant: model.variant) } label: {
                Row(Text("Gearing and tires", bundle: .module), trailing: { Disclosure() })
            }
            .buttonStyle(RowButtonStyle())
            if ctx.registry.canOpen(.guides) {
                actionRow("Guides") { ctx.env.router.open(.guides) }
            }
            actionRow("Edit car") { ctx.env.router.open(.vehiclePicker(forCar: car.id)) }
            if model.uploading { Text("Uploading photo", bundle: .module).typeStyle(.foot).foregroundStyle(Color.dust).padding(Space.margin) }
        }
        .padding(.top, Space.s16)
    }

    private func actionRow(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { Row(Text(title), trailing: { Disclosure() }) }.buttonStyle(RowButtonStyle())
    }

    @ViewBuilder private func otherActions(_ car: Car) -> some View {
        if let owner = model.owner {
            Button { ctx.env.router.open(.profile(owner.userID)) } label: {
                Row(Text(verbatim: owner.displayName), subtitle: Text(verbatim: "@\(owner.handle)"), leading: {
                    Avatar(name: owner.displayName, url: ctx.url(.avatars, owner.avatarPath), size: .s40)
                }, trailing: { Disclosure() })
            }
            .buttonStyle(RowButtonStyle())
            .padding(.top, Space.s16)
            SecondaryButton("Message about this car") {
                Task {
                    if let t = try? await ctx.env.messages.openThread(with: owner.userID, listing: nil) {
                        ctx.env.router.open(.thread(t.id))
                    } else { toast = ToastMessage(Text(GarageCopy.failed)) }
                }
            }
            .padding(.horizontal, Space.margin)
            .padding(.top, Space.s12)
        }
    }

    @ViewBuilder private var timeline: some View {
        SectionLabel("TIMELINE")
        if model.entries.isEmpty && model.own {
            VStack(alignment: .leading, spacing: Space.s12) {
                Text("No entries yet. Log the first thing you did to it.", bundle: .module).typeStyle(.body).foregroundStyle(Color.dust)
                SecondaryButton("Add an entry") { addEntry = true }
            }
            .padding(.horizontal, Space.margin)
        } else {
            ForEach(model.entries) { e in
                VStack(alignment: .leading, spacing: Space.s4) {
                    Text(verbatim: e.happenedOn.formatted(date: .abbreviated, time: .omitted)).typeStyle(.readoutS).foregroundStyle(Color.dust)
                    Text(verbatim: e.title).typeStyle(.bodyStrong).foregroundStyle(Color.chalk)
                    if let cents = model.costs[e.id] {
                        Text(verbatim: GarageUnits.money(cents: cents)).typeStyle(.sub).foregroundStyle(Color.dust)
                    }
                    if e.isService {
                        let odo = e.odometer.map { GarageUnits.odometer($0, e.odometerUnit ?? GarageUnits.defaultOdometer) }
                        (odo.map { Text("Service · \($0)", bundle: .module) } ?? Text("Service", bundle: .module)).typeStyle(.sub).foregroundStyle(Color.dust)
                        if let day = e.remindOn, day >= Calendar.current.startOfDay(for: .now) {
                            Text("Reminder \(day.formatted(date: .abbreviated, time: .omitted))", bundle: .module).typeStyle(.sub).foregroundStyle(Color.dust)
                        }
                    }
                    if !e.body.isEmpty { Text(verbatim: e.body).typeStyle(.body).foregroundStyle(Color.chalk) }
                    if let path = e.photoPath {
                        MediaView(url: ctx.url(.cars, path), aspectRatio: 4.0 / 3.0, cornerRadius: Radius.r12, label: Text(verbatim: e.title))
                    }
                }
                .padding(.horizontal, Space.margin)
                .padding(.vertical, Space.s12)
                .overlay(alignment: .bottom) { Hairline().padding(.leading, Space.margin) }
            }
            if model.own { SecondaryButton("Add an entry") { addEntry = true }.padding(Space.margin) }
        }
    }

    /// GAR-18: the owner's running total and per-year subtotals. Nobody else gets costs.
    @ViewBuilder private var costSummary: some View {
        let costed = model.entries.compactMap { e in
            model.costs[e.id].map { (year: Calendar.current.component(.year, from: e.happenedOn), cents: $0) }
        }
        if model.own, !costed.isEmpty {
            let years = Dictionary(grouping: costed) { $0.year }.mapValues { $0.reduce(0) { $0 + $1.cents } }.sorted { $0.key > $1.key }
            SectionLabel("BUILD COST")
            Row(Text("Total", bundle: .module), subtitle: Text("Only you can see what the build cost.", bundle: .module), trailing: {
                Text(verbatim: GarageUnits.money(cents: costed.reduce(0) { $0 + $1.cents })).typeStyle(.readoutM).foregroundStyle(Color.chalk)
            })
            ForEach(years, id: \.key) { year, cents in
                Row(Text(verbatim: String(year)), showsDivider: year != years.last?.key, trailing: {
                    Text(verbatim: GarageUnits.money(cents: cents)).typeStyle(.readoutS)
                })
            }
        }
    }

    private func specs(_ car: Car) -> some View {
        let v = model.variant, o = car.specOverrides
        let rows: [(String, String?, Bool)] = [
            (String(localized: "Engine", bundle: .module), v?.engine, false),
            (String(localized: "Power", bundle: .module), (o.hp ?? v?.hp).map { "\($0.formatted(.number))\(thinSpace)hp" }, o.hp != nil),
            (String(localized: "Drivetrain", bundle: .module), (o.drivetrain ?? v?.drive)?.rawValue.uppercased(), o.drivetrain != nil),
            (String(localized: "Transmission", bundle: .module), v?.transmission, o.gears != nil),
            (String(localized: "Weight", bundle: .module), (o.weightLb ?? v?.weightLb).map(GarageUnits.weight(lb:)), o.weightLb != nil),
            (String(localized: "Clearance", bundle: .module), car.clearance.rawValue.capitalized, car.clearance != .stock),
        ]
        return VStack(alignment: .leading, spacing: 0) {
            SectionLabel("SPECS")
            ForEach(rows.filter { $0.1 != nil }, id: \.0) { label, value, edited in
                HStack(alignment: .firstTextBaseline, spacing: Space.s12) {
                    Text(verbatim: label).typeStyle(.sub).foregroundStyle(Color.dust).frame(width: Size.row * 2, alignment: .leading)
                    Text(verbatim: value ?? "").typeStyle(.body).foregroundStyle(Color.chalk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    (edited ? Text("edited", bundle: .module) : Text("stock", bundle: .module)).typeStyle(.foot).foregroundStyle(Color.gravel)
                }
                .padding(.horizontal, Space.margin)
                .padding(.vertical, Space.s8)
                .accessibilityElement(children: .combine)
            }
            if model.own {
                Button { editSpecs = true } label: {
                    Row(Text("Edit specs", bundle: .module), trailing: { Disclosure() })
                }
                .buttonStyle(RowButtonStyle())
                Menu {
                    ForEach(Clearance.allCases, id: \.self) { c in
                        Button(c.rawValue.capitalized) {
                            var updated = car
                            updated.clearance = c
                            Task {
                                if let saved = try? await ctx.env.garage.updateCar(updated) { model.car = saved } else {
                                    toast = ToastMessage(Text(GarageCopy.failed))
                                }
                            }
                        }
                    }
                } label: { Row(Text("Change clearance", bundle: .module), showsDivider: false, trailing: { Disclosure() }) }
            }
        }
    }
}

// MARK: G5 Timeline entry

struct TimelineEntrySheet: View {
    let ctx: GarageContext
    let car: Car
    let variant: CatalogVariant?
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date.now
    @State private var title = ""
    @State private var details = ""
    @State private var photo: PhotosPickerItem?
    @State private var pick = false
    @State private var modID: String?
    /// GAR-16
    @State private var isService = false
    @State private var odometer = ""
    @State private var unit = GarageUnits.defaultOdometer
    @State private var remind = false
    @State private var remindOn = Calendar.current.date(byAdding: .month, value: 6, to: .now) ?? .now
    /// GAR-18
    @State private var cost = ""
    /// The entry is saved and only its cost failed: the next tap retries the cost alone.
    @State private var costPending: BuildEntryID?
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        Sheet(Text("Add to timeline", bundle: .module)) {
            Color.clear.frame(height: 0).photosPicker(isPresented: $pick, selection: $photo, matching: .images)
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s16) {
                    DatePicker("Date", selection: $date, displayedComponents: .date).tint(.sodium)
                        .typeStyle(.body).foregroundStyle(Color.chalk)
                    Field("What did you do?", text: $title, limit: 60)
                    Field("Details", text: $details, limit: 500, axis: .vertical)
                    Button { pick = true } label: {
                        Row(Text(photo == nil ? "Add a photo" : "Photo added"), showsDivider: false, trailing: { Disclosure() })
                    }
                    .buttonStyle(RowButtonStyle())
                    Menu {
                        Button("None") { modID = nil }
                        ForEach(linkable, id: \.id) { m in Button(m.name) { modID = m.id } }
                    } label: {
                        Row(Text("Link a mod", bundle: .module), showsDivider: false, trailing: {
                            Text(verbatim: modID.flatMap { ModCatalog.mod($0)?.name } ?? "").typeStyle(.sub)
                        })
                    }
                    .buttonStyle(RowButtonStyle())
                    Field("Cost", text: $cost, prompt: "Optional. Only you see it.", limit: 11).keyboardType(.decimalPad)
                    Toggle("Service", isOn: $isService).tint(.sodium).typeStyle(.body).foregroundStyle(Color.chalk)
                    if isService {
                        HStack(alignment: .bottom, spacing: Space.s12) {
                            Field("Odometer", text: $odometer, prompt: "Optional", limit: 7).keyboardType(.numberPad)
                            SegmentedSwitch(selection: $unit, options: [(OdometerUnit.mi, "mi"), (OdometerUnit.km, "km")])
                                .frame(maxWidth: Size.row * 2)
                        }
                        Toggle("Remind me", isOn: $remind).tint(.sodium).typeStyle(.body).foregroundStyle(Color.chalk)
                        if remind {
                            DatePicker("On", selection: $remindOn, in: Date.now..., displayedComponents: .date).tint(.sodium)
                                .typeStyle(.body).foregroundStyle(Color.chalk)
                        }
                    }
                    if let error { Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake) }
                    PrimaryButton("Add to timeline", isLoading: saving) { save() }.disabled(title.isEmpty)
                }
                .padding(Space.margin)
            }
        }
        .presentationDetents([.large])
    }

    private var linkable: [Mod] {
        guard let spec = VehicleSpec.from(variant: variant, car: car) else { return ModCatalog.all.filter { $0.platforms.isEmpty } }
        return ModCatalog.available(for: spec, platform: ModCatalog.platform(for: car, variant: variant))
    }

    private func save() {
        guard !saving else { return }
        let cents = GarageUnits.cents(cost)
        guard cost.isEmpty || cents != nil else {
            error = String(localized: "Enter the cost as a number, like 349.99.", bundle: .module)
            return
        }
        saving = true
        Task {
            if let costPending {
                do {
                    if let cents { try await ctx.env.garage.setBuildCost(costPending, cents: cents) }
                    onSave()
                    dismiss()
                } catch {
                    self.error = String(localized: "The entry is saved, but its cost isn't. Check your connection and try again.", bundle: .module)
                }
                saving = false
                return
            }
            do {
                var path: String?
                if let photo, let data = try await photo.loadTransferable(type: Data.self) {
                    path = try await ctx.env.media.upload(data, contentType: "image/jpeg", to: .cars, progress: { _ in }).path
                }
                let reading = isService ? Int(odometer.filter(\.isNumber)) : nil
                let saved = try await ctx.env.garage.addBuildEntry(BuildEntry(
                    carID: car.id, happenedOn: date, title: title, body: details, photoPath: path, modID: modID,
                    isService: isService, odometer: reading, odometerUnit: reading == nil ? nil : unit,
                    remindOn: isService && remind ? remindOn : nil))
                await ServiceReminder.sync(saved, car: car)
                if let modID, let mod = ModCatalog.mod(modID), !car.mods.contains(modID) {
                    var updated = car
                    updated.mods.removeAll { id in
                        guard let other = ModCatalog.mod(id) else { return false }
                        return mod.conflicts.contains(id) || other.conflicts.contains(modID)
                            || (mod.category == .forcedInduction && other.category == .forcedInduction)
                    }
                    updated.mods.append(modID)
                    try await ctx.env.garage.updateCar(updated)
                }
                if let cents {
                    do { try await ctx.env.garage.setBuildCost(saved.id, cents: cents) } catch {
                        costPending = saved.id
                        onSave()
                        self.error = String(localized: "The entry is saved, but its cost isn't. Check your connection and try again.", bundle: .module)
                        saving = false
                        return
                    }
                }
                onSave()
                dismiss()
            } catch WaypointsError.rateLimited {
                error = GarageCopy.rateLimited
            } catch {
                self.error = String(localized: "Couldn't save. Check your connection and try again.", bundle: .module)
            }
            saving = false
        }
    }
}

// MARK: G10 Edit profile

struct EditProfile: View {
    let ctx: GarageContext
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var original: Profile?
    @State private var name = ""
    @State private var handle = ""
    @State private var bio = ""
    @State private var region = ""
    @State private var photo: PhotosPickerItem?
    @State private var picked: UIImage?
    @State private var pick = false
    @State private var error: String?
    @State private var saving = false

    private var changed: Bool {
        guard let o = original else { return false }
        return photo != nil || o.displayName != name || o.handle != handle || o.bio != bio || (o.homeRegion ?? "") != region
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s16) {
                    Button { pick = true } label: {
                        // SOC-6: the picked photo previews in the circle it will be cropped to.
                        Group {
                            if let picked {
                                Image(uiImage: picked).resizable().scaledToFill()
                                    .frame(width: Avatar.Diameter.s96.rawValue, height: Avatar.Diameter.s96.rawValue)
                                    .clipShape(Circle())
                            } else {
                                Avatar(name: name, url: ctx.url(.avatars, original?.avatarPath), size: .s96)
                            }
                        }
                        .overlay(alignment: .bottomTrailing) { Image.symbol(Symbol.camera).foregroundStyle(Color.sodium) }
                    }
                    .buttonStyle(PressScaleStyle())
                    .photosPicker(isPresented: $pick, selection: $photo, matching: .images)
                    .onChange(of: photo) {
                        if let photo {
                            Task {
                                picked = (try? await photo.loadTransferable(type: Data.self)).flatMap { UIImage(data: $0) }
                            }
                        }
                    }
                    Field("Name", text: $name, limit: 30)
                    Field("Handle", text: $handle, limit: 20).textInputAutocapitalization(.never)
                    Field("Bio", text: $bio, limit: 160, axis: .vertical)
                    Field("Home region", text: $region, prompt: "Like 'South Jersey'", limit: 40)
                    if let error { Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake) }
                }
                .padding(Space.margin)
            }
            .background(Color.asphalt.ignoresSafeArea())
            .navigationTitle("Edit profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { QuietButton("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { QuietButton("Save") { save() }.disabled(!changed || saving) }
            }
        }
        .task {
            guard let p = try? await ctx.env.profiles.myProfile() else { return }
            original = p; name = p.displayName; handle = p.handle; bio = p.bio; region = p.homeRegion ?? ""
        }
    }

    private func save() {
        saving = true
        Task {
            do {
                var avatar: String?
                if let photo, let data = try await photo.loadTransferable(type: Data.self) {
                    avatar = try await ctx.env.media.upload(data, contentType: "image/jpeg", to: .avatars, progress: { _ in }).path
                }
                try await ctx.env.profiles.updateMyProfile(ProfileUpdate(
                    handle: handle == original?.handle ? nil : handle.lowercased(), displayName: name, bio: bio,
                    avatarPath: avatar, homeRegion: region.isEmpty ? nil : region))
                onSave()
                dismiss()
            } catch WaypointsError.conflict {
                error = String(localized: "That handle is taken.", bundle: .module)
            } catch WaypointsError.rateLimited {
                error = GarageCopy.rateLimited
            } catch {
                self.error = String(localized: "Couldn't save. Check your connection and try again.", bundle: .module)
            }
            saving = false
        }
    }
}

// MARK: G11 Friends

struct FriendsScreen: View {
    let ctx: GarageContext
    @State private var tab = 0
    @State private var friends: [Friend] = []
    @State private var requests: [FriendRequest] = []
    @State private var query = ""
    @State private var found: [Profile] = []
    @State private var handle = ""
    @State private var meID: UserID?
    @State private var scanning = false
    @State private var requested: Set<UserID> = []
    @State private var sending: Set<UserID> = []
    @State private var toast: ToastMessage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Field("Find people", text: $query, prompt: "Search by handle").padding(Space.margin)
                        .textInputAutocapitalization(.never)
                    if !query.isEmpty {
                        ForEach(found.filter { $0.userID != meID }) { p in
                            let friend = friends.contains { $0.profile.userID == p.userID }
                            Row(Text(verbatim: p.displayName), subtitle: Text(verbatim: "@\(p.handle)"), leading: {
                                Avatar(name: p.displayName, size: .s40)
                            }, trailing: {
                                SecondaryButton(friend ? "Friends" : requested.contains(p.userID) ? "Requested" : "Add") {
                                    guard !sending.contains(p.userID) else { return }
                                    sending.insert(p.userID)
                                    askForNotifications()
                                    Task {
                                        defer { sending.remove(p.userID) }
                                        do {
                                            try await ctx.env.friends.sendRequest(to: p.userID)
                                            requested.insert(p.userID)
                                        } catch WaypointsError.rateLimited {
                                            toast = ToastMessage(Text(GarageCopy.rateLimited))
                                        } catch { toast = ToastMessage(Text(GarageCopy.failed)) }
                                    }
                                }
                                    .frame(width: Size.row * 2.2)
                                    .disabled(friend || requested.contains(p.userID) || sending.contains(p.userID))
                            })
                        }
                    } else {
                        if let meID, let url = Route.profile(meID).shareURL {
                            ShareLink(item: url) { Row(Text("Invite a friend", bundle: .module), trailing: { Image.symbol(Symbol.share) }) }
                        }
                        if let meID, let link = ProfileLink.url(for: meID) {
                            NavigationLink {
                                QRCodeScreen(Text("My code", bundle: .module), heading: Text(verbatim: "@\(handle)"),
                                             caption: Text("Have them scan it in Friends to add you.", bundle: .module), url: link)
                            } label: { Row(Text("My code", bundle: .module), trailing: { Disclosure() }) }
                            .buttonStyle(RowButtonStyle())
                        }
                        if CodeScanner.isAvailable {
                            Button { scanning = true } label: {
                                Row(Text("Scan", bundle: .module), subtitle: Text("Add someone from their code", bundle: .module), trailing: { Image.symbol(Symbol.camera) })
                            }
                            .buttonStyle(RowButtonStyle())
                        }
                        SegmentedSwitch(selection: $tab, options: [(0, "Friends"), (1, "Requests")])
                            .padding(.horizontal, Space.margin)
                        if tab == 0 {
                            ForEach(friends) { f in
                                Row(Text(verbatim: f.profile.displayName), subtitle: f.primaryCar.map { Text(verbatim: $0.shortLabel) },
                                    leading: { Avatar(name: f.profile.displayName, size: .s40) })
                                    .swipeActions { Button("Remove", role: .destructive) { remove(f.profile.userID) } }
                                    .contextMenu { Button("Remove", role: .destructive) { remove(f.profile.userID) } }
                            }
                        } else {
                            if requests.isEmpty {
                                Text("No requests.", bundle: .module).typeStyle(.body).foregroundStyle(Color.dust).padding(Space.margin)
                            }
                            ForEach(requests) { r in
                                Row(Text(verbatim: r.profile.displayName), subtitle: Text(verbatim: "@\(r.profile.handle)"), leading: {
                                    Avatar(name: r.profile.displayName, size: .s40)
                                }, trailing: {
                                    HStack {
                                        SecondaryButton("Accept") {
                                            Task {
                                                do { try await ctx.env.friends.acceptRequest(from: r.profile.userID) } catch {
                                                    toast = ToastMessage(Text(GarageCopy.failed))
                                                }
                                                await load()
                                            }
                                        }
                                        .frame(width: Size.row * 1.8)
                                        QuietButton("Decline") { remove(r.profile.userID) }
                                    }
                                })
                            }
                        }
                    }
                }
            }
            .background(Color.asphalt.ignoresSafeArea())
            .navigationTitle("Friends")
            .navigationBarTitleDisplayMode(.inline)
            .toast($toast)
        }
        .fullScreenCover(isPresented: $scanning) {
            ScanSheet { id in
                scanning = false
                dismiss()
                ctx.env.router.open(.profile(id))
            }
        }
        .task { await load() }
        .task(id: query) {
            guard !query.isEmpty else { found = []; return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let people = (try? await ctx.env.profiles.search(query, limit: 20)) ?? []
            if !Task.isCancelled { found = people }
        }
    }

    private func load() async {
        friends = (try? await ctx.env.friends.friends()) ?? []
        requests = (try? await ctx.env.friends.incomingRequests()) ?? []
        requested.formUnion(((try? await ctx.env.friends.outgoingRequests()) ?? []).map(\.profile.userID))
        if let me = try? await ctx.env.profiles.myProfile() { handle = me.handle; meID = me.userID }
    }

    private func remove(_ id: UserID) {
        Task {
            do { try await ctx.env.friends.remove(id) } catch { toast = ToastMessage(Text(GarageCopy.failed)) }
            await load()
        }
    }
}

// MARK: GAR-13 Spec overrides

/// The owner's numbers replace the catalog's (GAR-13). A blank field falls back to the
/// catalog value; a value equal to the catalog's stores no override.
struct SpecSheet: View {
    let ctx: GarageContext
    let car: Car
    let variant: CatalogVariant?
    let onSave: (Car) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var hp = ""
    @State private var torque = ""
    @State private var weight = ""
    @State private var redline = ""
    @State private var error: String?
    @State private var saving = false

    private static var metric: Bool { Locale.current.measurementSystem == .metric }

    private func parse(_ s: String) -> Int? { s.isEmpty ? nil : Int(s) }

    var body: some View {
        Sheet(Text("Edit specs", bundle: .module)) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s16) {
                    Text("Your numbers replace the catalog's. Leave a field blank to use the catalog value.", bundle: .module)
                        .typeStyle(.body).foregroundStyle(Color.dust)
                    Field("Horsepower", text: $hp).keyboardType(.numberPad)
                    Field("Torque (lb-ft)", text: $torque).keyboardType(.numberPad)
                    Field(Self.metric ? "Weight (kg)" : "Weight (lb)", text: $weight).keyboardType(.numberPad)
                    Field("Redline (rpm)", text: $redline).keyboardType(.numberPad)
                    if let error { Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake) }
                    PrimaryButton("Save specs", isLoading: saving) { save() }
                }
                .padding(Space.margin)
            }
        }
        .presentationDetents([.large])
        .onAppear {
            let o = car.specOverrides
            hp = (o.hp ?? variant?.hp).map(String.init) ?? ""
            torque = (o.torqueLbFt ?? variant?.torqueLbFt).map(String.init) ?? ""
            weight = (o.weightLb ?? variant?.weightLb).map { Self.metric ? String(Int((Double($0) / 2.20462).rounded())) : String($0) } ?? ""
            redline = (o.redline ?? variant?.redline).map(String.init) ?? ""
        }
    }

    private func save() {
        guard !saving else { return }
        guard [hp, torque, weight, redline].allSatisfy({ $0.isEmpty || (Int($0) ?? 0) > 0 }) else {
            error = String(localized: "Enter each spec as a number.", bundle: .module)
            return
        }
        saving = true
        Task {
            var updated = car
            let h = parse(hp), t = parse(torque), r = parse(redline)
            // Stored in pounds; entered in the locale's unit (SET-3).
            let w = parse(weight).map { Self.metric ? Int((Double($0) * 2.20462).rounded()) : $0 }
            updated.specOverrides.hp = h == variant?.hp ? nil : h
            updated.specOverrides.torqueLbFt = t == variant?.torqueLbFt ? nil : t
            updated.specOverrides.weightLb = w == variant?.weightLb ? nil : w
            updated.specOverrides.redline = r == variant?.redline ? nil : r
            do {
                let saved = try await ctx.env.garage.updateCar(updated)
                onSave(saved)
                dismiss()
            } catch {
                self.error = GarageCopy.failed
                saving = false
            }
        }
    }
}
