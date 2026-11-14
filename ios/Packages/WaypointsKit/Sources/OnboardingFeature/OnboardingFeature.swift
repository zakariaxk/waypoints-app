import AuthenticationServices
import Core
import CryptoKit
import DesignSystem
import MapKit
import SafetyKit
import SwiftUI
import VehicleCatalog

/// O1–O4 and the X2 terms gate (plan 10.2). Registered as the signed-out root.
public enum OnboardingFeature: FeatureModule {
    public static let isAvailable = true

    @MainActor
    public static func register(in registry: FeatureRegistry, env: AppEnvironment) {
        registry.registerOnboarding { AnyView(OnboardingRoot(env: env)) }
    }
}

@MainActor
@Observable
final class OnboardingModel {
    enum Step: Hashable { case signIn, you, terms, car, location }
    let env: AppEnvironment
    var step: Step = .signIn
    var session: AuthSession?

    init(env: AppEnvironment) { self.env = env }

    func observe() async {
        for await s in await env.auth.sessions() {
            session = s
            if s == nil { step = .signIn } else if step == .signIn { step = .you }
        }
    }

    func finish() async { try? await env.auth.completeOnboarding() }
}

struct OnboardingRoot: View {
    @State private var model: OnboardingModel
    init(env: AppEnvironment) { _model = State(initialValue: OnboardingModel(env: env)) }

    var body: some View {
        NavigationStack {
            Group {
                switch model.step {
                case .signIn: SignInView(env: model.env)
                case .you: YouView(env: model.env) { model.step = .terms }
                case .terms: TermsGate(safety: model.env.safety) { model.step = .car }
                case .car: CarStepView(env: model.env) { model.step = .location }
                case .location: LocationStepView(env: model.env) { Task { await model.finish() } }
                }
            }
            .transition(.opacity)
        }
        .motion(.standard, value: model.step)
        .task { await model.observe() }
    }
}

// MARK: O1 Sign in

struct SignInView: View {
    let env: AppEnvironment
    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var sending = false
    @State private var error: String?
    @State private var canResend = false
    @State private var showEmail = false
    @State private var nonce = ""
    @State private var failed = 0

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: Space.s8) {
                Spacer().frame(height: proxy.size.height / 3 - Space.s48)
                Text("Waypoints").typeStyle(.display).foregroundStyle(Color.chalk).accessibilityAddTraits(.isHeader)
                Text("See who's out. Find the meet. Show the build.").typeStyle(.body).foregroundStyle(Color.dust)
                Spacer()
                if showEmail { emailForm } else { buttons }
                if let error { Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake) }
                Text("By continuing you agree to the [Terms](https://waypoints.app/terms) and [Privacy Policy](https://waypoints.app/privacy).")
                    .typeStyle(.foot).foregroundStyle(Color.gravel).tint(.sodium)
                    .padding(.top, Space.s8)
            }
            .padding(.horizontal, Space.margin)
            .padding(.bottom, Space.s16)
        }
        .background(Color.asphalt.ignoresSafeArea())
        .haptic(.fail, trigger: failed)
        .onAppear {
            // SAFE-7: the shell signed a suspended account out.
            if UserDefaults.standard.bool(forKey: AccountSuspension.defaultsKey) {
                UserDefaults.standard.removeObject(forKey: AccountSuspension.defaultsKey)
                error = AccountSuspension.message
            }
        }
    }

    private var buttons: some View {
        VStack(spacing: Space.s12) {
            SignInWithAppleButton(.signIn) { request in
                nonce = Self.randomNonce()
                request.requestedScopes = [.email]
                request.nonce = Self.sha256(nonce)
            } onCompletion: { result in
                guard case let .success(auth) = result,
                      let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                      let data = cred.identityToken, let token = String(data: data, encoding: .utf8) else { return }
                Task {
                    do { _ = try await env.auth.signInWithApple(idToken: token, nonce: nonce) } catch { show(error) }
                }
            }
            .signInWithAppleButtonStyle(.white)
            .frame(height: Size.control)
            .clipShape(RoundedRectangle(cornerRadius: Radius.r12))
            SecondaryButton("Continue with email") { showEmail = true }
        }
    }

    private var emailForm: some View {
        VStack(spacing: Space.s12) {
            if codeSent {
                Field("Code", text: $code, prompt: "6 digits")
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .onChange(of: code) {
                        code = String(code.filter(\.isNumber).prefix(6))
                        if code.count == 6 { verify() }
                    }
                if canResend { QuietButton("Send it again") { send() } }
            } else {
                Field("Email", text: $email, prompt: "you@example.com")
                    .keyboardType(.emailAddress).textContentType(.emailAddress).textInputAutocapitalization(.never)
                PrimaryButton("Send code", isLoading: sending) { send() }.disabled(!email.contains("@"))
            }
        }
    }

    private func send() {
        sending = true
        error = nil
        Task {
            do {
                try await env.auth.sendEmailCode(to: email)
                codeSent = true
                canResend = false
                Task { try? await Task.sleep(for: .seconds(30)); canResend = true }
            } catch { show(error) }
            sending = false
        }
    }

    private func verify() {
        Task {
            do { _ = try await env.auth.verifyEmailCode(code, email: email) } catch {
                code = ""
                show(error)
            }
        }
    }

    private func show(_ e: any Error) {
        failed += 1
        switch e as? WaypointsError {
        case .offline: error = "You're offline. Connect to sign in."
        case .invalid("code"): error = "That code didn't match. Check the email and try again."
        case .rateLimited: error = "Too many tries. Wait a minute and try again."
        case .suspended: error = AccountSuspension.message
        default: error = "Couldn't sign in. Check your connection and try again."
        }
    }

    static func randomNonce() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
    static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: O2 You

struct YouView: View {
    let env: AppEnvironment
    let next: () -> Void
    @State private var handle = ""
    @State private var name = ""
    @State private var birthYear = Calendar.current.component(.year, from: .now) - 25
    @State private var available: Bool?
    @State private var saving = false
    @State private var error: String?

    private var currentYear: Int { Calendar.current.component(.year, from: .now) }
    private var oldEnough: Bool { currentYear - birthYear >= Profile.minimumAge }
    private var valid: Bool { Profile.isValidHandle(handle) && available == true && !name.isEmpty && oldEnough }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s16) {
                Text("You").typeStyle(.display).foregroundStyle(Color.chalk).padding(.top, Space.s24)
                VStack(alignment: .leading, spacing: Space.s4) {
                    Field("Handle", text: $handle, prompt: "lowercase, numbers, _", limit: 20)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onChange(of: handle) { handle = handle.lowercased(); available = nil }
                    if let available {
                        if available {
                            Label("Available", systemImage: Symbol.confirm).typeStyle(.foot).foregroundStyle(Color.go)
                        } else {
                            Text("Taken").typeStyle(.foot).foregroundStyle(Color.brake)
                        }
                    }
                }
                Field("Name", text: $name, prompt: "What friends call you", limit: 30)
                VStack(alignment: .leading, spacing: Space.s8) {
                    Text("Birth year").typeStyle(.foot).foregroundStyle(Color.dust)
                    Picker("Birth year", selection: $birthYear) {
                        ForEach((1930...currentYear).reversed(), id: \.self) { Text(verbatim: String($0)).tag($0) }
                    }
                    .pickerStyle(.wheel)
                    .frame(maxHeight: Size.row * 2.5)
                    if !oldEnough {
                        Text("Waypoints is for drivers 17 and up.").typeStyle(.foot).foregroundStyle(Color.brake)
                    }
                }
                if let error { Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake) }
                PrimaryButton("Continue", isLoading: saving) { save() }.disabled(!valid)
            }
            .padding(.horizontal, Space.margin)
        }
        .background(Color.asphalt.ignoresSafeArea())
        .task(id: handle) {
            guard Profile.isValidHandle(handle) else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            available = try? await env.profiles.isHandleAvailable(handle)
        }
    }

    private func save() {
        saving = true
        Task {
            do {
                try await env.profiles.updateMyProfile(ProfileUpdate(handle: handle, displayName: name, birthYear: birthYear))
                next()
            } catch WaypointsError.conflict {
                available = false
            } catch {
                self.error = "Couldn't save. Check your connection and try again."
            }
            saving = false
        }
    }
}

// MARK: O3 Your car

struct CarStepView: View {
    let env: AppEnvironment
    let next: () -> Void
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What do you drive?").typeStyle(.title).foregroundStyle(Color.chalk)
                .padding(.horizontal, Space.margin)
            if let error { Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake).padding(.horizontal, Space.margin) }
            VehiclePicker(catalog: env.catalog) { picked in
                guard case let .car(newCar) = picked else { return }
                Task {
                    do {
                        let car = try await env.garage.createCar(newCar)
                        try await env.profiles.updateMyProfile(ProfileUpdate(primaryCarID: car.id))
                        next()
                    } catch {
                        self.error = "Couldn't add the car. Check your connection and try again."
                    }
                }
            }
        }
        .background(Color.asphalt.ignoresSafeArea())
        .toolbar { ToolbarItem(placement: .topBarTrailing) { QuietButton("Skip for now") { next() } } }
    }
}

// MARK: O4 Location

struct LocationStepView: View {
    let env: AppEnvironment
    let done: () -> Void
    @State private var showNearby = false
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s16) {
            ZStack {
                Map(initialPosition: .region(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: 39.93, longitude: -75.03),
                    span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08))), interactionModes: [])
                    .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
                HStack(spacing: Space.s32) {
                    sample(VehicleMarker(icon: "pony", paint: Color(rgb: 0x2B6CD1), role: .friend(name: "Precise")), "Friends")
                    sample(VehicleMarker(icon: "pony", paint: Color(rgb: 0x2B6CD1), role: .approximate), "Approximate")
                    sample(Color.clear.frame(width: Size.Marker.friend, height: Size.Marker.friend), "Nothing")
                }
            }
            .frame(maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Radius.r20))
            .environment(\.colorScheme, .dark)
            Text("Who sees you").typeStyle(.title).foregroundStyle(Color.chalk)
            Text("Friends see where you are. Everyone else sees nothing unless you say so. You can go ghost any time.")
                .typeStyle(.body).foregroundStyle(Color.dust)
            VStack(spacing: 0) {
                radio("Hide me from drivers nearby", selected: !showNearby) { showNearby = false }
                radio("Show drivers nearby roughly where I am (within half a mile)", selected: showNearby) { showNearby = true }
            }
            PrimaryButton("Turn on location", isLoading: working) { finish(requestLocation: true) }
            QuietButton("Not now") { finish(requestLocation: false) }.frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Space.margin)
        .padding(.bottom, Space.s16)
        .background(Color.asphalt.ignoresSafeArea())
    }

    private func sample(_ marker: some View, _ label: LocalizedStringKey) -> some View {
        VStack(spacing: Space.s4) {
            marker
            Text(label).typeStyle(.foot).foregroundStyle(Color.chalk)
        }
    }

    private func radio(_ title: LocalizedStringKey, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Row(Text(title), leading: {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.sodium : Color.gravel)
            })
        }
        .buttonStyle(RowButtonStyle())
    }

    private func finish(requestLocation: Bool) {
        working = true
        Task {
            var settings = (try? await env.profiles.myPrivacySettings()) ?? .defaults
            settings.nearbyLevel = showNearby ? .approx : .hidden
            try? await env.gateway.updatePrivacy(settings)
            if requestLocation {
                await env.location.requestWhenInUse()
                await env.location.setSharing(true)
            }
            working = false
            done()
        }
    }
}
