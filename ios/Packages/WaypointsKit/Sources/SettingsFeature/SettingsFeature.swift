import Core
import DesignSystem
import SafetyKit
import SwiftUI
import UserNotifications

/// S1–S6 (plan 10.9) and the X1 report route.
public enum SettingsFeature: FeatureModule {
    public static let isAvailable = true

    @MainActor
    public static func register(in registry: FeatureRegistry, env: AppEnvironment) {
        registry.registerRoute(.settings) { _ in AnyView(SettingsView(env: env)) }
        registry.registerRoute(.settingsPrivacy) { _ in AnyView(PrivacyView(env: env)) }
        registry.registerRoute(.reportContent, presentation: .sheet) { route in
            guard case let .reportContent(ref) = route else { return nil }
            let user = ref.kind == .user ? UserID(string: ref.id) : nil
            return AnyView(ReportSheet(target: ref, thing: ref.kind.rawValue, blockUser: user, safety: env.safety))
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

/// Shared list chrome: rows on asphalt, never a grouped Form.
struct SettingsList<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 0) { content } }
            .background(Color.asphalt.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.tarmac, for: .navigationBar)
    }
}

struct NavRow: View {
    let title: LocalizedStringKey
    let destination: () -> AnyView
    var body: some View {
        NavigationLink { destination() } label: { Row(Text(title), trailing: { Disclosure() }) }
            .buttonStyle(RowButtonStyle())
    }
}

// MARK: S1

struct SettingsView: View {
    let env: AppEnvironment
    var body: some View {
        SettingsList(title: "Settings") {
            NavRow(title: "Privacy and location") { AnyView(PrivacyView(env: env)) }
            NavRow(title: "Notifications") { AnyView(NotificationsView(env: env)) }
            NavRow(title: "Blocked people") { AnyView(BlockedView(env: env)) }
            NavRow(title: "Account") { AnyView(AccountView(env: env)) }
            NavRow(title: "About") { AnyView(AboutView()) }
        }
    }
}

// MARK: S2 Privacy and location

@MainActor
@Observable
final class PrivacyModel {
    let env: AppEnvironment
    var settings = PrivacySettings.defaults
    var zones: [HomeZone] = []
    var error: String?
    var background = false

    init(env: AppEnvironment) { self.env = env }

    func load() async {
        settings = (try? await env.profiles.myPrivacySettings()) ?? .defaults
        for await z in await env.location.homeZones() { zones = z }
    }

    func save(_ new: PrivacySettings) {
        let old = settings
        settings = new
        Task {
            do { try await env.gateway.updatePrivacy(new) } catch {
                settings = old
                self.error = "Couldn't save. Try again."
            }
        }
    }

    func saveZones(_ new: [HomeZone]) {
        Task {
            do { try await env.location.setHomeZones(new) } catch { self.error = "Couldn't save. Try again." }
        }
    }
}

struct PrivacyView: View {
    @State private var model: PrivacyModel
    @State private var askGhost = false
    @State private var addZone = false
    @State private var askBackground = false
    @AppStorage("recordDrives") private var recordDrives = false

    init(env: AppEnvironment) { _model = State(initialValue: PrivacyModel(env: env)) }

    var body: some View {
        SettingsList(title: "Privacy and location") {
            previews
            Row(Text("Ghost mode"), subtitle: ghostLine, trailing: {
                Toggle("", isOn: Binding(get: { model.settings.isGhost() }, set: { on in
                    if on { askGhost = true } else {
                        var s = model.settings; s.ghostUntil = nil; model.save(s)
                    }
                })).labelsHidden().tint(.sodium)
            })
            SectionLabel("WHO SEES YOU")
            levelRow("Friends", \.friendsLevel, options: [.precise, .approx, .hidden])
            levelRow("Teams", \.teamLevel, options: [.precise, .approx, .hidden])
            levelRow("Drivers nearby", \.nearbyLevel, options: [.approx, .hidden])
            SectionLabel("HOME ZONES")
            ForEach(model.zones) { zone in
                Row(Text(verbatim: zone.name), trailing: {
                    Text(verbatim: "\(zone.radiusMeters)\(thinSpace)m").typeStyle(.readoutS)
                })
                .contextMenu {
                    Button("Remove", role: .destructive) { model.saveZones(model.zones.filter { $0.id != zone.id }) }
                }
            }
            if model.zones.count < HomeZone.maximumCount {
                Button { addZone = true } label: { Row(Text("Add a zone"), trailing: { Disclosure() }) }
                    .buttonStyle(RowButtonStyle())
            }
            Text("Inside a zone, nobody gets your exact position. Zones are stored on this phone.")
                .typeStyle(.foot).foregroundStyle(Color.dust).padding(.horizontal, Space.margin).padding(.top, Space.s8)
            SectionLabel("BACKGROUND")
            Row(Text("Keep sharing when the app is closed"), trailing: {
                Toggle("", isOn: Binding(get: { model.background }, set: { on in
                    if on { askBackground = true } else { model.background = false }
                })).labelsHidden().tint(.sodium)
            })
            Row(Text("Record my drives on this phone"), showsDivider: false, trailing: {
                Toggle("", isOn: $recordDrives).labelsHidden().tint(.sodium)
            })
            if let error = model.error {
                Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake).padding(Space.margin)
            }
        }
        .task { await model.load() }
        .confirmationDialog("Go ghost", isPresented: $askGhost) {
            Button("For 1 hour") { ghost(until: .now.addingTimeInterval(3600)) }
            Button("Until tomorrow") { ghost(until: Self.tomorrowSix) }
            Button("Until I turn it off") { ghost(until: .distantFuture) }
        }
        .alert("Keep sharing when the app is closed", isPresented: $askBackground) {
            Button("Turn on") {
                model.background = true
                Task { await model.env.location.requestAlways() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This uses more battery. Sharing stops by itself after 5 minutes parked.")
        }
        .sheet(isPresented: $addZone) {
            HomeZoneEditor { zone in model.saveZones(model.zones + [zone]) }
        }
    }

    static var tomorrowSix: Date {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: .now) ?? .now
        return cal.date(bySettingHour: 6, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    private func ghost(until: Date) {
        var s = model.settings
        s.ghostUntil = until
        model.save(s)
    }

    private var ghostLine: Text? {
        guard let until = model.settings.ghostUntil, model.settings.isGhost() else { return nil }
        if until == .distantFuture { return Text("Ghost until you turn it off. Nobody sees you.") }
        return Text("Ghost until \(until.formatted(date: .omitted, time: .shortened)). Nobody sees you.")
    }

    private func levelRow(_ title: LocalizedStringKey, _ key: WritableKeyPath<PrivacySettings, PrivacyLevel>,
                          options: [PrivacyLevel]) -> some View {
        Menu {
            ForEach(options, id: \.self) { level in
                Button {
                    var s = model.settings
                    s[keyPath: key] = level
                    model.save(s)
                } label: {
                    Text(Self.name(level))
                    Text(Self.blurb(level))
                }
            }
        } label: {
            Row(Text(title), trailing: {
                Text(Self.name(model.settings[keyPath: key])).typeStyle(.sub)
            })
        }
    }

    static func name(_ l: PrivacyLevel) -> LocalizedStringKey {
        switch l { case .precise: "Precise"; case .approx: "Approximate"; case .hidden: "Hidden" }
    }
    static func blurb(_ l: PrivacyLevel) -> LocalizedStringKey {
        switch l {
        case .precise: "Your exact position, live."
        case .approx: "A half-mile area, updated every 15 seconds."
        case .hidden: "Nothing. You look offline."
        }
    }

    private var previews: some View {
        let s = model.settings
        let ghost = s.isGhost()
        return HStack(spacing: Space.s12) {
            preview("Friends see", ghost ? .hidden : s.friendsLevel)
            preview("Teams see", ghost ? .hidden : s.teamLevel)
            preview("Drivers nearby see", ghost ? .hidden : s.nearbyLevel)
        }
        .padding(Space.margin)
        .motion(.standard, value: s)
    }

    private func preview(_ title: LocalizedStringKey, _ level: PrivacyLevel) -> some View {
        VStack(spacing: Space.s8) {
            ZStack {
                switch level {
                case .precise: VehicleMarker(icon: "coupe", paint: .sodium, role: .friend(name: ""))
                case .approx: VehicleMarker(icon: "coupe", paint: .sodium, role: .approximate)
                case .hidden: Text("Nothing").typeStyle(.foot).foregroundStyle(Color.gravel)
                }
            }
            .frame(maxWidth: .infinity, minHeight: Size.Marker.approximateRing + Space.s16)
            .background(Color.tarmac, in: RoundedRectangle(cornerRadius: Radius.r12))
            Text(title).typeStyle(.foot).foregroundStyle(Color.dust).multilineTextAlignment(.center)
        }
    }
}

// MARK: S3 Notifications

struct NotificationsView: View {
    let env: AppEnvironment
    @State private var prefs = NotificationPrefs()
    @State private var privacy = PrivacySettings.defaults
    @State private var systemOff = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        SettingsList(title: "Notifications") {
            if systemOff {
                VStack(alignment: .leading, spacing: Space.s8) {
                    Text("Notifications are off for Waypoints.").typeStyle(.body).foregroundStyle(Color.chalk)
                    QuietButton("Open Settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                }
                .padding(Space.margin)
            }
            toggle("Meets near me", Binding(get: { privacy.notifyMeetsNearby }, set: { v in
                privacy.notifyMeetsNearby = v
                if v { askForNotifications() }
                let p = privacy
                Task { try? await env.gateway.updatePrivacy(p) }
            }))
            if privacy.notifyMeetsNearby {
                Row(Text("Radius"), trailing: {
                    Stepper(value: Binding(get: { privacy.notifyRadiusKm }, set: { v in
                        privacy.notifyRadiusKm = v
                        let p = privacy
                        Task { try? await env.gateway.updatePrivacy(p) }
                    }), in: 5...50, step: 5) {
                        Text(verbatim: "\(privacy.notifyRadiusKm)\(thinSpace)km").typeStyle(.readoutS)
                    }
                })
            }
            toggle("Friend requests", pref(\.friendRequests))
            toggle("Messages", pref(\.messages))
            toggle("Mentions", pref(\.mentions))
            toggle("Convoy invites", pref(\.convoyInvites))
            toggle("Meet reminders", pref(\.meetReminders))
        }
        .task {
            prefs = (try? await env.profiles.notificationPrefs()) ?? NotificationPrefs()
            privacy = (try? await env.profiles.myPrivacySettings()) ?? .defaults
            systemOff = await withCheckedContinuation { c in
                UNUserNotificationCenter.current().getNotificationSettings { c.resume(returning: $0.authorizationStatus == .denied) }
            }
        }
    }

    private func pref(_ key: WritableKeyPath<NotificationPrefs, Bool>) -> Binding<Bool> {
        Binding(get: { prefs[keyPath: key] }, set: { v in
            prefs[keyPath: key] = v
            let p = prefs
            Task { try? await env.profiles.setNotificationPrefs(p) }
        })
    }

    private func toggle(_ title: LocalizedStringKey, _ value: Binding<Bool>) -> some View {
        Row(Text(title), trailing: { Toggle("", isOn: value).labelsHidden().tint(.sodium) })
    }
}

// MARK: S4 Blocked people

struct BlockedView: View {
    let env: AppEnvironment
    @State private var people: [Profile]?

    var body: some View {
        SettingsList(title: "Blocked people") {
            if let people {
                if people.isEmpty {
                    Text("You haven't blocked anyone.").typeStyle(.body).foregroundStyle(Color.dust).padding(Space.margin)
                }
                ForEach(people) { p in
                    Row(Text(verbatim: p.displayName), subtitle: Text(verbatim: "@\(p.handle)"), leading: {
                        Avatar(name: p.displayName, size: .s40)
                    }, trailing: {
                        QuietButton("Unblock") {
                            Task {
                                try? await env.safety.unblock(p.userID)
                                self.people = try? await env.safety.blockedUsers()
                            }
                        }
                    })
                }
            } else {
                SkeletonRow(); SkeletonRow()
            }
        }
        .task { people = (try? await env.safety.blockedUsers()) ?? [] }
    }
}

// MARK: S5 Account

struct AccountView: View {
    let env: AppEnvironment
    @State private var email: String?
    @State private var handle = ""
    @State private var typed = ""
    @State private var confirming = false
    @State private var error: String?

    var body: some View {
        SettingsList(title: "Account") {
            Row(Text("Email"), trailing: { Text(verbatim: email ?? "Apple ID").typeStyle(.sub) })
            Button { Task { try? await env.auth.signOut() } } label: { Row(Text("Sign out")) }
                .buttonStyle(RowButtonStyle())
            VStack(alignment: .leading, spacing: Space.s12) {
                if confirming {
                    Text("This deletes your profile, cars, posts, messages you sent, and listings. Type your handle to confirm.")
                        .typeStyle(.sub).foregroundStyle(Color.dust)
                    Field("Handle", text: $typed, prompt: "\(handle)").textInputAutocapitalization(.never)
                    DestructiveButton("Delete account", confirmTitle: "Delete account",
                                      consequence: "Everything you own in Waypoints is deleted now.") {
                        Task {
                            do { try await env.auth.deleteAccount() } catch {
                                self.error = "Couldn't delete the account. Check your connection and try again."
                            }
                        }
                    }
                    .disabled(typed.lowercased() != handle.lowercased() || handle.isEmpty)
                } else {
                    SecondaryButton("Delete account") { confirming = true }
                }
                if let error { Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake) }
            }
            .padding(Space.margin)
        }
        .task {
            email = await env.auth.currentSession()?.email
            handle = (try? await env.profiles.myProfile().handle) ?? ""
        }
    }
}

// MARK: S6 About

struct AboutView: View {
    var body: some View {
        SettingsList(title: "About") {
            Row(Text("Version"), trailing: {
                Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    .typeStyle(.readoutS)
            })
            link("Terms", "https://waypoints.app/terms")
            link("Privacy Policy", "https://waypoints.app/privacy")
            link("Contact", "mailto:support@waypoints.app")
            NavigationLink {
                ScrollView {
                    Text(Self.licences).typeStyle(.foot).foregroundStyle(Color.dust).padding(Space.margin)
                }
                .background(Color.asphalt.ignoresSafeArea())
                .navigationTitle("Licences")
            } label: { Row(Text("Open-source licences"), showsDivider: false, trailing: { Disclosure() }) }
                .buttonStyle(RowButtonStyle())
        }
    }

    private func link(_ title: LocalizedStringKey, _ url: String) -> some View {
        Link(destination: URL(string: url)!) { Row(Text(title), trailing: { Disclosure() }) }
    }

    static let licences: LocalizedStringKey = """
    B612 Mono: SIL Open Font License 1.1. Copyright 2012 The B612 Project Authors.
    supabase-swift: MIT License.
    swift-protobuf: Apache License 2.0.
    """
}
