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
        registry.registerRoute(.profile) { route in
            guard case let .profile(id) = route else { return nil }
            return AnyView(ProfileScreen(ctx: ctx, userID: id))
        }
        registry.registerRoute(.car) { route in
            guard case let .car(id) = route else { return nil }
            return AnyView(CarScreen(ctx: ctx, carID: id))
        }
        registry.registerRoute(.vehiclePicker, presentation: .sheet) { route in
            guard case let .vehiclePicker(carID) = route else { return nil }
            return AnyView(PickerSheet(ctx: ctx, editing: carID))
        }
    }
}

/// Asks for notification permission once, at a moment that gives it a reason (plan 10.2).
@MainActor
func askForNotifications() {
    let key = "notifications.asked"
    guard !UserDefaults.standard.bool(forKey: key) else { return }
    UserDefaults.standard.set(true, forKey: key)
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
        if granted { Task { @MainActor in UIApplication.shared.registerForRemoteNotifications() } }
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
    var friendship: Friendship?
    var following = false
    var requests = 0
    var blocked = false
    var me: UserID?
    var failed = false

    init(ctx: GarageContext, userID: UserID) { self.ctx = ctx; self.userID = userID }

    func load() async {
        let env = ctx.env
        me = await env.auth.currentSession()?.userID
        do {
            profile = try await env.profiles.profile(userID)
            failed = false
        } catch {
            failed = true
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
        } else {
            friendship = try? await env.friends.friendship(with: userID)
            following = (try? await env.posts.isFollowing(userID)) ?? false
        }
    }

    func watchCars() async {
        for await list in await ctx.env.garage.carChanges(of: userID) { cars = list }
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

    init(ctx: GarageContext, userID: UserID, isOwn: Bool = false) {
        self.ctx = ctx; self.userID = userID; self.isOwn = isOwn
        _model = State(initialValue: ProfileModel(ctx: ctx, userID: userID))
    }

    private var own: Bool { isOwn || model.me == userID }

    var body: some View {
        ScrollView {
            if model.failed {
                ErrorState(Text("This profile isn't available.")) { Task { await model.load() } }
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
        .navigationTitle(model.profile.map { "@\($0.handle)" } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
                        if let url = URL(string: "waypoints://profile/\(p.userID)") { ShareLink("Share profile", item: url) }
                        Button("Block", role: .destructive) { Task { try? await ctx.env.safety.block(p.userID) } }
                        Button("Report") { ctx.env.router.open(.reportContent(.user(p.userID))) }
                    } label: { Image.symbol(Symbol.more) }
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
    }

    private func header(_ p: Profile) -> some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            Avatar(name: p.displayName, url: ctx.url(.avatars, p.avatarPath), size: .s96)
            Text(verbatim: p.displayName).typeStyle(.title).foregroundStyle(Color.chalk)
            if !p.bio.isEmpty { Text(verbatim: p.bio).typeStyle(.body).foregroundStyle(Color.chalk) }
            if let region = p.homeRegion { Text(verbatim: region).typeStyle(.sub).foregroundStyle(Color.dust) }
            HStack(spacing: Space.s24) {
                if own { count(model.friendCount, "friends") }
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
            PrimaryButton(title) {
                Task {
                    if status == nil { askForNotifications(); try? await ctx.env.friends.sendRequest(to: p.userID) }
                    else if status?.status == .pending, status?.requesterID != model.me { try? await ctx.env.friends.acceptRequest(from: p.userID) }
                    model.friendship = try? await ctx.env.friends.friendship(with: p.userID)
                }
            }
            .disabled(status?.status == .accepted || (status?.status == .pending && status?.requesterID == model.me))
            SecondaryButton(model.following ? "Following" : "Follow") {
                Task {
                    if model.following { try? await ctx.env.posts.unfollow(p.userID) } else { try? await ctx.env.posts.follow(p.userID) }
                    model.following.toggle()
                }
            }
            IconButton(Symbol.comment, label: "Message") {
                Task {
                    if let t = try? await ctx.env.messages.openThread(with: p.userID, listing: nil) { ctx.env.router.open(.thread(t.id)) }
                }
            }
        }
        .padding(.horizontal, Space.margin)
        .padding(.top, Space.s16)
    }

    @ViewBuilder private var carsSection: some View {
        SectionLabel("CARS")
        if model.cars.isEmpty && own {
            VStack(alignment: .leading, spacing: Space.s12) {
                Text("Your garage is empty.").typeStyle(.body).foregroundStyle(Color.dust)
                PrimaryButton("Add your car") { ctx.env.router.open(.vehiclePicker(forCar: nil)) }
            }
            .padding(.horizontal, Space.margin)
        }
        VStack(spacing: Space.s24) {
            ForEach(model.cars) { car in
                Button { ctx.env.router.open(.car(car.id)) } label: { CarCard(ctx: ctx, car: car, photo: model.photos[car.id]) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Space.margin)
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
            Row(Text("See all"), showsDivider: false, trailing: { Disclosure() })
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
            }
        }
    }
}

struct CarCard: View {
    let ctx: GarageContext
    let car: Car
    let photo: CarPhoto?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            ZStack(alignment: .bottom) {
                MediaView(url: ctx.url(.cars, photo?.path), aspectRatio: 16.0 / 9.0, cornerRadius: Radius.r20,
                          label: Text(verbatim: car.fullLabel))
                Rectangle().fill(car.paint).frame(height: Size.paintBar)
                    .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: Radius.r20, bottomTrailingRadius: Radius.r20))
            }
            Text(verbatim: car.title).typeStyle(.title).foregroundStyle(Color.chalk)
            if car.nickname != nil || car.trim != nil {
                Text(verbatim: car.nickname != nil ? car.fullLabel : (car.trim ?? "")).typeStyle(.sub).foregroundStyle(Color.dust)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: G4 host

struct PickerSheet: View {
    let ctx: GarageContext
    let editing: CarID?
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var icon = "coupe"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error { Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake) }
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
        do {
            if let editing {
                var car = try await ctx.env.garage.car(editing)
                car.catalogVariantID = new.catalogVariantID; car.year = new.year; car.make = new.make; car.model = new.model
                car.trim = new.trim; car.colorFamily = new.colorFamily; car.colorHex = new.colorHex; car.paintName = new.paintName
                try await ctx.env.garage.updateCar(car)
            } else {
                let car = try await ctx.env.garage.createCar(new)
                if (try? await ctx.env.profiles.myProfile().primaryCarID) == nil {
                    try? await ctx.env.profiles.updateMyProfile(ProfileUpdate(primaryCarID: car.id))
                }
            }
            dismiss()
        } catch {
            self.error = "Couldn't save the car. Check your connection and try again."
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
                        }
                    }
                }
            }
        }
        .background(Color.asphalt.ignoresSafeArea())
        .navigationTitle(make)
    }
}
