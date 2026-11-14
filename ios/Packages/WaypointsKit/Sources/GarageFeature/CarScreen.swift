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
    var variant: CatalogVariant?
    var showdown: ShowdownEntry?
    var me: UserID?
    var uploading = false

    init(ctx: GarageContext, carID: CarID) { self.ctx = ctx; self.carID = carID }

    var own: Bool { car?.ownerID == me }

    var estimate: Estimate? {
        guard let car, let spec = VehicleSpec.from(variant: variant, car: car) else { return nil }
        return PerformanceModel.estimate(base: spec, mods: car.mods.compactMap(ModCatalog.mod))
    }

    func load() async {
        let env = ctx.env
        me = await env.auth.currentSession()?.userID
        guard let c = try? await env.garage.car(carID) else { return }
        car = c
        owner = try? await env.profiles.profile(c.ownerID)
        photos = (try? await env.garage.photos(of: carID)) ?? []
        entries = ((try? await env.garage.buildEntries(of: carID)) ?? []).sorted { $0.happenedOn > $1.happenedOn }
        if let v = c.catalogVariantID { variant = try? await env.catalog.variant(v) }
        showdown = try? await env.showdown.entry(for: carID)
    }

    func addPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        uploading = true
        defer { uploading = false }
        if let media = try? await ctx.env.media.upload(data, contentType: "image/jpeg", to: .cars, progress: { _ in }) {
            _ = try? await ctx.env.garage.addPhoto(to: carID, media: media)
            photos = (try? await ctx.env.garage.photos(of: carID)) ?? photos
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
    @State private var shared: SharedImage?
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
                    specs(car)
                }
                .padding(.bottom, Space.s48)
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
                Task { try? await ctx.env.garage.deleteCar(model.carID); dismiss() }
            }
        } message: { Text("Its photos and timeline are deleted too.", bundle: .module) }
        .sheet(isPresented: $addEntry) {
            TimelineEntrySheet(ctx: ctx, car: model.car!) { Task { await model.load() } }
        }
        .confirmationDialog("Enter Showdown", isPresented: $askShowdown) {
            ForEach(ShowdownClass.allCases, id: \.self) { c in
                Button(c.rawValue.capitalized) {
                    Task {
                        model.showdown = try? await ctx.env.showdown.enter(model.carID, class: c)
                    }
                }
            }
        } message: { Text("Needs at least one photo.", bundle: .module) }
        .sheet(item: $shared) { ShareSheet(items: [$0.image]).presentationDetents([.medium, .large]) }
        .photosPicker(isPresented: $pickPhoto, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { if let item = photoItem { Task { await model.addPhoto(item); photoItem = nil } } }
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
                    readout(e.hp, "EST. HP", fmt: "%.0f", bounds: 0...1200)
                    readout(e.torque, "EST. TQ", fmt: "%.0f", bounds: 0...1000)
                    readout(e.zeroToSixty, "0–60", fmt: "%.1f", unit: "s", bounds: 2...12)
                    readout(e.quarterET, "¼ MILE", fmt: "%.1f", unit: "s", bounds: 8...18)
                }
                Text("Estimates from stock specs and listed mods.", bundle: .module).typeStyle(.foot).foregroundStyle(Color.dust)
            }
            .padding(.horizontal, Space.margin)
            .padding(.top, Space.s24)
        }
        .buttonStyle(.plain)
    }

    private func readout(_ r: ClosedRange<Double>, _ label: LocalizedStringKey, fmt: String, unit: String? = nil,
                         bounds: ClosedRange<Double>) -> some View {
        Readout(String(format: fmt, (r.lowerBound + r.upperBound) / 2), unit: unit, label: label,
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
            if let entry = model.showdown {
                Row(Text("In Showdown · \(entry.showdownClass.rawValue.capitalized)", bundle: .module),
                    trailing: { Text(verbatim: "\(entry.rating)").typeStyle(.readoutS) })
            } else if !ctx.registry.feedModes.isEmpty {
                actionRow("Enter Showdown") { askShowdown = true }
                    .disabled(model.photos.isEmpty)
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
                    }
                }
            }
            .padding(.horizontal, Space.margin)
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
                    if e.isService {
                        let odo = e.odometer.map { GarageUnits.odometer($0, e.odometerUnit ?? GarageUnits.defaultOdometer) }
                        Text(odo.map { "Service · \($0)" } ?? "Service").typeStyle(.sub).foregroundStyle(Color.dust)
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

    private func specs(_ car: Car) -> some View {
        let v = model.variant, o = car.specOverrides
        let rows: [(String, String?, Bool)] = [
            ("Engine", v?.engine, false),
            ("Power", (o.hp ?? v?.hp).map { "\($0) hp" }, o.hp != nil),
            ("Drivetrain", (o.drivetrain ?? v?.drive)?.rawValue.uppercased(), o.drivetrain != nil),
            ("Transmission", v?.transmission, o.gears != nil),
            ("Weight", (o.weightLb ?? v?.weightLb).map(GarageUnits.weight(lb:)), o.weightLb != nil),
            ("Clearance", car.clearance.rawValue.capitalized, car.clearance != .stock),
        ]
        return VStack(alignment: .leading, spacing: 0) {
            SectionLabel("SPECS")
            ForEach(rows.filter { $0.1 != nil }, id: \.0) { label, value, edited in
                HStack {
                    Text(verbatim: label).typeStyle(.sub).foregroundStyle(Color.dust).frame(width: Size.row * 2.2, alignment: .leading)
                    Text(verbatim: value ?? "").typeStyle(.body).foregroundStyle(Color.chalk)
                    Spacer()
                    Text(edited ? "edited" : "stock").typeStyle(.foot).foregroundStyle(Color.gravel)
                }
                .padding(.horizontal, Space.margin)
                .padding(.vertical, Space.s8)
            }
            if model.own {
                Menu {
                    ForEach(Clearance.allCases, id: \.self) { c in
                        Button(c.rawValue.capitalized) {
                            var updated = car
                            updated.clearance = c
                            Task { model.car = try? await ctx.env.garage.updateCar(updated) }
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
                        ForEach(ModCatalog.all, id: \.id) { m in Button(m.name) { modID = m.id } }
                    } label: {
                        Row(Text("Link a mod", bundle: .module), showsDivider: false, trailing: {
                            Text(verbatim: modID.flatMap { ModCatalog.mod($0)?.name } ?? "").typeStyle(.sub)
                        })
                    }
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

    private func save() {
        saving = true
        Task {
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
                if let modID, !car.mods.contains(modID) {
                    var updated = car
                    updated.mods.append(modID)
                    try await ctx.env.garage.updateCar(updated)
                }
                onSave()
                dismiss()
            } catch WaypointsError.rateLimited {
                error = GarageCopy.rateLimited
            } catch {
                self.error = "Couldn't save. Check your connection and try again."
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
                        Avatar(name: name, url: ctx.url(.avatars, original?.avatarPath), size: .s96)
                            .overlay(alignment: .bottomTrailing) { Image.symbol(Symbol.camera).foregroundStyle(Color.sodium) }
                    }
                    .photosPicker(isPresented: $pick, selection: $photo, matching: .images)
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
                error = "That handle is taken."
            } catch WaypointsError.rateLimited {
                error = GarageCopy.rateLimited
            } catch {
                self.error = "Couldn't save. Check your connection and try again."
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Field("Find people", text: $query, prompt: "Search by handle").padding(Space.margin)
                        .textInputAutocapitalization(.never)
                    if !query.isEmpty {
                        ForEach(found) { p in
                            Row(Text(verbatim: p.displayName), subtitle: Text(verbatim: "@\(p.handle)"), leading: {
                                Avatar(name: p.displayName, size: .s40)
                            }, trailing: {
                                SecondaryButton("Add") { Task { try? await ctx.env.friends.sendRequest(to: p.userID) } }
                                    .frame(width: Size.row * 1.6)
                            })
                        }
                    } else {
                        if let url = URL(string: "https://waypoints.app/u/\(handle)") {
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
                                            Task { try? await ctx.env.friends.acceptRequest(from: r.profile.userID); await load() }
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
            try? await Task.sleep(for: .milliseconds(250))
            found = (try? await ctx.env.profiles.search(query, limit: 20)) ?? []
        }
    }

    private func load() async {
        friends = (try? await ctx.env.friends.friends()) ?? []
        requests = (try? await ctx.env.friends.incomingRequests()) ?? []
        if let me = try? await ctx.env.profiles.myProfile() { handle = me.handle; meID = me.userID }
    }

    private func remove(_ id: UserID) {
        Task { try? await ctx.env.friends.remove(id); await load() }
    }
}
