import Core
import DesignSystem
import PerformanceModel
import PhotosUI
import SwiftUI
import UserNotifications
import VehicleCatalog

/// The Garage tab and routes `profile`, `car`, `vehiclePicker` (plan 10.8).
public enum GarageFeature: FeatureModule {
    public static let isAvailable = true

    @MainActor
    public static func register(in registry: FeatureRegistry, env: AppEnvironment) {
        let ctx = GarageContext(env: env, registry: registry)
        registry.registerTab(.garage) { AnyView(GarageHome(ctx: ctx)) }
        registry.registerRoute(.profile, presentation: .push(tab: .garage)) { route in
            guard case let .profile(id) = route else { return nil }
            return AnyView(ProfileScreen(ctx: ctx, userID: id))
        }
        registry.registerRoute(.car, presentation: .push(tab: .garage)) { route in
            guard case let .car(id) = route else { return nil }
            return AnyView(CarScreen(ctx: ctx, carID: id))
        }
        registry.registerRoute(.vehiclePicker, presentation: .sheet) { route in
            guard case let .vehiclePicker(carID) = route else { return nil }
            return AnyView(PickerSheet(ctx: ctx, editing: carID))
        }
        #if DEBUG
        registry.registerDebugScreen("gearing") { AnyView(DebugGearing(ctx: ctx)) }
        #endif
    }
}

/// Asks for notification permission once, at a moment that gives it a reason (plan 10.2).
@MainActor
func askForNotifications() {
    let key = "notifications.asked"
    guard !UserDefaults.standard.bool(forKey: key) else { return }
    UserDefaults.standard.set(true, forKey: key)
    Task {
        let granted = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        if granted == true { UIApplication.shared.registerForRemoteNotifications() }
    }
}

@MainActor
final class GarageContext {
    let env: AppEnvironment
    let registry: FeatureRegistry
    init(env: AppEnvironment, registry: FeatureRegistry) { self.env = env; self.registry = registry }

    func url(_ bucket: MediaBucket, _ path: String?) -> URL? { path.map { env.media.publicURL(bucket: bucket, path: $0) } }
}

extension Car {
    var paint: Color { colorHex.flatMap { Color(paintHex: $0) } ?? .dust }
    var title: String { nickname ?? shortLabel }
}

// MARK: G1 Garage

struct GarageHome: View {
    let ctx: GarageContext
    @State private var me: UserID?

    var body: some View {
        Group {
            if let me { ProfileScreen(ctx: ctx, userID: me, isOwn: true) } else { SkeletonRow() }
        }
        .task { me = await ctx.env.auth.currentSession()?.userID }
    }
}

@MainActor
@Observable
final class ProfileModel {
    let ctx: GarageContext
    let userID: UserID
    var profile: Profile?
    var cars: [Car] = []
    var photos: [CarID: CarPhoto] = [:]
    var posts: [Post] = []
    var spots: [Spot] = []
    var earned: [String] = []
    var friendCount = 0
    var followingCount = 0
    var friendship: Friendship?
    var following = false
    var requests = 0
    var blocked = false
    var me: UserID?
    var failed = false
    var offline = false

    init(ctx: GarageContext, userID: UserID) { self.ctx = ctx; self.userID = userID }

    func load() async {
        let env = ctx.env
        me = await env.auth.currentSession()?.userID
        do {
            profile = try await env.profiles.profile(userID)
            failed = false
        } catch {
            failed = true
            offline = (error as? WaypointsError) == .offline
            return
        }
        cars = (try? await env.garage.cars(of: userID)) ?? []
        for car in cars { photos[car.id] = try? await env.garage.photos(of: car.id).first }
        posts = (try? await env.posts.posts(by: userID)) ?? []
        spots = (try? await env.spots.spots(by: userID)) ?? []
        earned = EarnedIcons.names((try? await env.progress.achievements(of: userID)) ?? [])
        if userID == me {
            friendCount = (try? await env.friends.friends().count) ?? 0
            requests = (try? await env.friends.incomingRequests().count) ?? 0
            followingCount = (try? await env.posts.followingCount()) ?? 0
        } else {
            friendship = try? await env.friends.friendship(with: userID)
            following = (try? await env.posts.isFollowing(userID)) ?? false
        }
    }

    func watchCars() async {
        for await list in await ctx.env.garage.carChanges(of: userID) {
            cars = list
            for car in list where photos[car.id] == nil { photos[car.id] = try? await ctx.env.garage.photos(of: car.id).first }
        }
    }
}

struct ProfileScreen: View {
    let ctx: GarageContext
    let userID: UserID
    var isOwn = false
    @State private var model: ProfileModel
    @State private var editing = false
    @State private var showFriends = false
    @State private var activityUnread = 0
    @State private var busy = false
    @State private var toast: ToastMessage?

    init(ctx: GarageContext, userID: UserID, isOwn: Bool = false) {
        self.ctx = ctx; self.userID = userID; self.isOwn = isOwn
        _model = State(initialValue: ProfileModel(ctx: ctx, userID: userID))
    }

    private var own: Bool { isOwn || model.me == userID }

    var body: some View {
        ScrollView {
            if model.failed {
                ErrorState(model.offline ? Text("Couldn't load this profile. Check your connection and try again.", bundle: .module)
                           : Text("This profile isn't available.", bundle: .module)) { Task { await model.load() } }
            } else if let p = model.profile {
                VStack(alignment: .leading, spacing: 0) {
                    header(p)
                    if !own { relationButtons(p) }
                    if !model.earned.isEmpty { EarnedIconStrip(names: model.earned, paint: iconPaint(p)) }
                    carsSection
                    if !model.spots.isEmpty { spottedSection }
                    if !model.posts.isEmpty { postsSection }
                }
                .padding(.bottom, Space.s48)
            } else {
                SkeletonRow(); SkeletonRow(); SkeletonBlock(height: Size.row * 3).padding(Space.margin)
            }
        }
        .background(Color.asphalt.ignoresSafeArea())
        .navigationTitle(isOwn ? "" : model.profile.map { "@\($0.handle)" } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isOwn, let p = model.profile {
                ToolbarItem(placement: .topBarLeading) {
                    Text(verbatim: "@\(p.handle)").typeStyle(.title).foregroundStyle(Color.chalk).lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            if own {
                if ctx.registry.canOpen(.activity) {
                    ToolbarItem(placement: .topBarTrailing) {
                        IconButton("bell", label: activityUnread > 0 ? LocalizedStringKey("Activity, new") : LocalizedStringKey("Activity")) { ctx.env.router.open(.activity) }
                            .overlay(alignment: .topTrailing) {
                                if activityUnread > 0 {
                                    Circle().fill(Color.sodium).frame(width: Space.s8, height: Space.s8).padding(Space.s8)
                                }
                            }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    IconButton("person.badge.plus", label: "Friend requests") { showFriends = true }
                        .overlay(alignment: .topTrailing) {
                            if model.requests > 0 {
                                Text(verbatim: "\(model.requests)").typeStyle(.readoutS).foregroundStyle(Color.chalk)
                                    .padding(.horizontal, Space.s4).background(Color.brake, in: Capsule())
                            }
                        }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    IconButton(Symbol.settings, label: "Settings") { ctx.env.router.open(.settings) }
                }
            } else if let p = model.profile {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if let url = Route.profile(p.userID).shareURL { ShareLink("Share profile", item: url) }
                        Button("Block", role: .destructive) {
                            Task {
                                do {
                                    try await ctx.env.safety.block(p.userID)
                                    model.offline = false
                                    model.failed = true
                                } catch { toast = ToastMessage(Text(GarageCopy.failed)) }
                            }
                        }
                        Button("Report") { ctx.env.router.open(.reportContent(.user(p.userID))) }
                    } label: { Image.symbol(Symbol.more).frame(minWidth: Size.hitTarget, minHeight: Size.hitTarget) }
                    .accessibilityLabel(Text("More options", bundle: .module))
                }
            }
        }
        .sheet(isPresented: $editing) { EditProfile(ctx: ctx) { Task { await model.load() } } }
        .sheet(isPresented: $showFriends) { FriendsScreen(ctx: ctx) }
        .task { await model.load() }
        .task { await model.watchCars() }
        .task(id: own) {
            guard own else { return }
            for await count in await ctx.env.activity.unreadCount() { activityUnread = count }
        }
        .refreshable { await model.load() }
        .toast($toast)
    }

    private func header(_ p: Profile) -> some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            Avatar(name: p.displayName, url: ctx.url(.avatars, p.avatarPath), size: .s96)
            Text(verbatim: p.displayName).typeStyle(.title).foregroundStyle(Color.chalk)
            if !p.bio.isEmpty { Text(verbatim: p.bio).typeStyle(.body).foregroundStyle(Color.chalk) }
            if let region = p.homeRegion { Text(verbatim: region).typeStyle(.sub).foregroundStyle(Color.dust) }
            HStack(spacing: Space.s24) {
                if own { count(model.friendCount, "friends") }
                if own { count(model.followingCount, "following") }
                count(model.cars.count, "cars")
                count(Set(model.spots.map(\.catalogModelID)).count, "spotted")
            }
            .padding(.vertical, Space.s8)
            if own { SecondaryButton("Edit profile") { editing = true } }
        }
        .padding(.horizontal, Space.margin)
        .padding(.top, Space.s16)
    }

    /// Earned icons draw in the owner's primary car paint, as on the map (plan 9.8).
    private func iconPaint(_ p: Profile) -> Color {
        (model.cars.first { $0.id == p.primaryCarID } ?? model.cars.first)?.paint ?? .chalk
    }

    private func count(_ n: Int, _ label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text(verbatim: "\(n)").typeStyle(.readoutM).foregroundStyle(Color.chalk)
            Text(label).typeStyle(.foot).foregroundStyle(Color.dust)
        }
    }

    @ViewBuilder private func relationButtons(_ p: Profile) -> some View {
        HStack(spacing: Space.s12) {
            let status = model.friendship
            let title: LocalizedStringKey = switch (status?.status, status?.requesterID == model.me) {
            case (.accepted?, _): "Friends"
            case (.pending?, true): "Requested"
            case (.pending?, false): "Accept"
            default: "Add friend"
            }
            PrimaryButton(title, isLoading: busy) {
                guard !busy else { return }
                busy = true
                Task {
                    defer { busy = false }
                    if status == nil {
                        askForNotifications()
                        do { try await ctx.env.friends.sendRequest(to: p.userID) } catch WaypointsError.rateLimited {
                            toast = ToastMessage(Text(GarageCopy.rateLimited))
                        } catch { toast = ToastMessage(Text(GarageCopy.failed)) }
                    }
                    else if status?.status == .pending, status?.requesterID != model.me {
                        do { try await ctx.env.friends.acceptRequest(from: p.userID) } catch { toast = ToastMessage(Text(GarageCopy.failed)) }
                    }
                    if let now = try? await ctx.env.friends.friendship(with: p.userID) { model.friendship = now }
                }
            }
            .disabled(status?.status == .accepted || (status?.status == .pending && status?.requesterID == model.me))
            SecondaryButton(model.following ? "Following" : "Follow") {
                Task {
                    do {
                        if model.following { try await ctx.env.posts.unfollow(p.userID) } else { try await ctx.env.posts.follow(p.userID) }
                        model.following.toggle()
                    } catch { toast = ToastMessage(Text(GarageCopy.failed)) }
                }
            }
            IconButton(Symbol.comment, label: "Message") {
                Task {
                    if let t = try? await ctx.env.messages.openThread(with: p.userID, listing: nil) { ctx.env.router.open(.thread(t.id)) } else {
                        toast = ToastMessage(Text(GarageCopy.failed))
                    }
                }
            }
        }
        .padding(.horizontal, Space.margin)
        .padding(.top, Space.s16)
    }

    /// GAR-10: the owner drags cards into order; `reorderCars` persists `cars.sort`.
    private var reorderable: Bool { own && model.cars.count > 1 }

    private func moveCar(from i: Int, to j: Int) {
        model.cars.move(fromOffsets: IndexSet(integer: i), toOffset: j)
        let ids = model.cars.map(\.id)
        Task {
            do { try await ctx.env.garage.reorderCars(ids) } catch { toast = ToastMessage(Text(GarageCopy.failed)) }
        }
    }

    @ViewBuilder private func carCard(_ i: Int, _ car: Car) -> some View {
        let card = Button { ctx.env.router.open(.car(car.id)) } label: {
            CarCard(ctx: ctx, car: car, photo: model.photos[car.id])
        }
        .buttonStyle(PressScaleStyle())
        if reorderable {
            card
                .draggable(String(i))
                .dropDestination(for: String.self) { dropped, _ in
                    guard let from = dropped.first.flatMap(Int.init), model.cars.indices.contains(from), from != i else { return false }
                    moveCar(from: from, to: from < i ? i + 1 : i)
                    return true
                }
                .accessibilityActions {
                    if i > 0 { Button("Move up") { moveCar(from: i, to: i - 1) } }
                    if i < model.cars.count - 1 { Button("Move down") { moveCar(from: i, to: i + 1) } }
                }
        } else {
            card
        }
    }

    @ViewBuilder private var carsSection: some View {
        SectionLabel("CARS")
        if model.cars.isEmpty && own {
            VStack(alignment: .leading, spacing: Space.s12) {
                Text("Your garage is empty.", bundle: .module).typeStyle(.body).foregroundStyle(Color.dust)
                PrimaryButton("Add your car") { ctx.env.router.open(.vehiclePicker(forCar: nil)) }
            }
            .padding(.horizontal, Space.margin)
        }
        VStack(spacing: Space.s24) {
            ForEach(Array(model.cars.enumerated()), id: \.element.id) { i, car in
                carCard(i, car)
            }
        }
        .padding(.horizontal, Space.margin)
        if reorderable {
            Text("Drag to reorder.", bundle: .module).typeStyle(.foot).foregroundStyle(Color.dust)
                .padding(.horizontal, Space.margin).padding(.top, Space.s8)
        }
        if own && !model.cars.isEmpty {
            SecondaryButton("Add a car") { ctx.env.router.open(.vehiclePicker(forCar: nil)) }
                .padding(.horizontal, Space.margin).padding(.top, Space.s16)
        }
    }

    @ViewBuilder private var spottedSection: some View {
        SectionLabel("SPOTTED")
        let byMake = Dictionary(grouping: model.spots, by: \.make).sorted { $0.value.count > $1.value.count }
        ForEach(byMake.prefix(5), id: \.key) { make, spots in
            Row(Text(verbatim: make), trailing: { Text(verbatim: "\(spots.count)").typeStyle(.readoutS) })
        }
        NavigationLink { SpottedView(ctx: ctx, spots: model.spots) } label: {
            Row(Text("See all", bundle: .module), showsDivider: false, trailing: { Disclosure() })
        }
        .buttonStyle(RowButtonStyle())
    }

    @ViewBuilder private var postsSection: some View {
        SectionLabel("POSTS")
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.s2), count: 3), spacing: Space.s2) {
            ForEach(model.posts) { post in
                Button { ctx.env.router.open(.post(post.id)) } label: {
                    MediaView(url: ctx.url(.posts, post.posterPath), aspectRatio: 9.0 / 16.0, cornerRadius: 0,
                              label: Text(verbatim: post.caption))
                }
                .buttonStyle(PressScaleStyle())
            }
        }
    }
}

struct CarCard: View {
    let ctx: GarageContext
    let car: Car
    let photo: CarPhoto?
    /// Est. power as a low–high range (plan 10.8 G1).
    @State private var hp: ClosedRange<Double>?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            ZStack(alignment: .bottom) {
                MediaView(url: ctx.url(.cars, photo?.path), aspectRatio: 16.0 / 9.0, cornerRadius: Radius.r20,
                          label: Text(verbatim: car.fullLabel))
                Rectangle().fill(car.paint).frame(height: Size.paintBar)
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.r20, style: .continuous))
            Text(verbatim: car.title).typeStyle(.title).foregroundStyle(Color.chalk)
            if car.nickname != nil || car.trim != nil {
                Text(verbatim: car.nickname != nil ? car.fullLabel : (car.trim ?? "")).typeStyle(.sub).foregroundStyle(Color.dust)
            }
            if let hp {
                HStack(alignment: .firstTextBaseline, spacing: Space.s4) {
                    Text("est.", bundle: .module).typeStyle(.foot).foregroundStyle(Color.dust)
                    Readout(Format.range(hp), unit: "hp")
                }
            }
        }
        .contentShape(Rectangle())
        .task(id: car.mods) {
            var variant: CatalogVariant?
            if let id = car.catalogVariantID { variant = try? await ctx.env.catalog.variant(id) }
            hp = VehicleSpec.from(variant: variant, car: car).map { PerformanceModel.estimate(base: $0, mods: car.mods.compactMap(ModCatalog.mod)).hp }
        }
    }
}

// MARK: G4 host

struct PickerSheet: View {
    let ctx: GarageContext
    let editing: CarID?
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var saving = false
    @State private var icon = "coupe"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error {
                    Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Space.margin)
                }
                VehiclePicker(catalog: ctx.env.catalog, markerIcon: icon,
                              actionTitle: editing == nil ? "Add to garage" : "Save car") { picked in
                    guard case let .car(new) = picked else { return }
                    Task { await save(new) }
                }
            }
            .navigationTitle(editing == nil ? "Add a car" : "Edit car")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { QuietButton("Cancel") { dismiss() } } }
        }
        .task { icon = (try? await ctx.env.profiles.myProfile().markerIcon) ?? "coupe" }
    }

    private func save(_ new: NewCar) async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            if let editing {
                var car = try await ctx.env.garage.car(editing)
                car.catalogVariantID = new.catalogVariantID; car.year = new.year; car.make = new.make; car.model = new.model
                car.trim = new.trim; car.colorFamily = new.colorFamily; car.colorHex = new.colorHex; car.paintName = new.paintName
                try await ctx.env.garage.updateCar(car)
            } else {
                let car = try await ctx.env.garage.createCar(new)
                if (try? await ctx.env.profiles.myProfile().primaryCarID) == nil {
                    _ = try? await ctx.env.profiles.updateMyProfile(ProfileUpdate(primaryCarID: car.id))
                }
            }
            dismiss()
        } catch WaypointsError.rateLimited {
            error = GarageCopy.rateLimited
        } catch {
            self.error = String(localized: "Couldn't save the car. Check your connection and try again.", bundle: .module)
        }
    }
}

/// The spotting collection (plan 10.3 M12): makes with counts, then models with photos.
struct SpottedView: View {
    let ctx: GarageContext
    let spots: [Spot]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Dictionary(grouping: spots, by: \.make).sorted { $0.key < $1.key }, id: \.key) { make, list in
                    NavigationLink { models(make, list) } label: {
                        Row(Text(verbatim: make), subtitle: Text("\(Set(list.map(\.catalogModelID)).count) models"),
                            trailing: { Text(verbatim: "\(list.count)").typeStyle(.readoutS) })
                    }
                    .buttonStyle(RowButtonStyle())
                }
            }
        }
        .background(Color.asphalt.ignoresSafeArea())
        .navigationTitle("Spotted")
    }

    private func models(_ make: String, _ list: [Spot]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Dictionary(grouping: list, by: \.model).sorted { $0.key < $1.key }, id: \.key) { model, shots in
                    SectionLabel(verbatim: model.uppercased())
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.s2), count: 3), spacing: Space.s2) {
                        ForEach(shots) { s in
                            MediaView(url: ctx.url(.spots, s.photoPath), aspectRatio: 1, cornerRadius: 0,
                                      label: Text(verbatim: "\(s.make) \(s.model), \(s.city)"))
                                .contextMenu {
                                    Button("Report") {
                                        ctx.env.router.open(.reportContent(ContentRef(kind: .spot, id: s.id.raw.uuidString)))
                                    }
                                }
                        }
                    }
                }
            }
        }
        .background(Color.asphalt.ignoresSafeArea())
        .navigationTitle(make)
    }
}
