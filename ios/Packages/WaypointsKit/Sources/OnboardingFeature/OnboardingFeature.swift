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
        #if DEBUG
        // O3 and O4 sit past the terms gate, which `waypoints://debug/` links cannot reach
        // without a tap; these let `make shot` see them (PRD 7.1).
        registry.registerDebugScreen("onboarding-car") { AnyView(NavigationStack { CarStepView(env: env) {} }) }
        registry.registerDebugScreen("onboarding-location") { AnyView(NavigationStack { LocationStepView(env: env) {} }) }
        #endif
    }
}

@MainActor
@Observable
final class OnboardingModel {
    enum Step: Hashable { case signIn, you, terms, car, location }
    let env: AppEnvironment
    var step: Step = .signIn
    var session: AuthSession?
    /// ACC-6: the gate is the only step left — a re-prompt after the terms changed, not
    /// first-run onboarding.
    var termsOnly = false

    init(env: AppEnvironment) { self.env = env }

    func observe() async {
        for await s in await env.auth.sessions() {
            session = s
            if s == nil {
                step = .signIn
                termsOnly = false
            } else if step == .signIn {
                step = await landingStep()
            }
        }
    }

    /// Where a signed-in user lands: O2 until the profile has a handle, then the gate until
    /// the terms in force are agreed (`Profile.acceptedCurrentTerms`, X2). Anything later
    /// resumes at O3.
    private func landingStep() async -> Step {
        guard let profile = try? await env.profiles.myProfile(), !profile.handle.isEmpty else { return .you }
        guard !profile.acceptedCurrentTerms else { return .car }
        // ACC-6: an agreed-then-stale `acceptedTermsAt` is a re-prompt — the gate is the
        // only step. Never agreed means a first run resumed mid-flow; it continues to O3.
        termsOnly = profile.acceptedTermsAt != nil
        return .terms
    }

    /// After "Agree": onboarding continues to O3; a re-prompt (ACC-6) is done.
    func afterTerms() {
        if termsOnly {
            Task { try? await finish() }
        } else {
            step = .car
        }
    }

    func finish() async throws { try await env.auth.completeOnboarding() }
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
                case .terms: TermsGate(safety: model.env.safety) { model.afterTerms() }
                case .car: CarStepView(env: model.env) { model.step = .location }
                case .location: LocationStepView(env: model.env) { try await model.finish() }
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
    /// SAFE-7: raised by the shell when the gateway reports a suspension, and by a suspended
    /// sign-in. Observed, not read once, so it also shows if it flips while this view is up.
    @AppStorage(AccountSuspension.defaultsKey) private var suspended = false
    @FocusState private var codeFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: Space.s8) {
                Spacer().frame(height: proxy.size.height / 3 - Space.s48)
                Text("Waypoints", bundle: .module).typeStyle(.display).foregroundStyle(Color.chalk).accessibilityAddTraits(.isHeader)
                Text("See who's out. Find the meet. Show the build.", bundle: .module).typeStyle(.body).foregroundStyle(Color.dust)
                Spacer()
                if showEmail { emailForm } else { buttons }
                if let error { Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake) }
                Text("By continuing you agree to the [Terms](\(termsURL)) and [Privacy Policy](\(privacyURL)).", bundle: .module)
                    .typeStyle(.foot).foregroundStyle(Color.gravel).tint(.xenon)
                    .padding(.top, Space.s8)
            }
            .padding(.horizontal, Space.margin)
            .padding(.bottom, Space.s16)
        }
        .background(Color.asphalt.ignoresSafeArea())
        .haptic(.fail, trigger: failed)
        .onAppear { showSuspension() }
        .onChange(of: suspended) { showSuspension() }
    }

    /// LINK-4: the site's legal pages on the shared link host (`AppConfig.siteHost`).
    private var termsURL: String { "https://\(AppConfig.siteHost)/terms" }
    private var privacyURL: String { "https://\(AppConfig.siteHost)/privacy" }

    private func showSuspension() {
        guard suspended else { return }
        suspended = false
        error = AccountSuspension.message
    }

    private var buttons: some View {
        VStack(spacing: Space.s12) {
            SignInWithAppleButton(.signIn) { request in
                nonce = Self.randomNonce()
                request.requestedScopes = [.email]
                request.nonce = Self.sha256(nonce)
            } onCompletion: { result in
                switch result {
                case let .success(auth):
                    guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                          let data = cred.identityToken, let token = String(data: data, encoding: .utf8) else {
                        return show(ASAuthorizationError(.invalidResponse))
                    }
                    Task {
                        do { _ = try await env.auth.signInWithApple(idToken: token, nonce: nonce) } catch { show(error) }
                    }
                case let .failure(failure):
                    if (failure as? ASAuthorizationError)?.code != .canceled { show(failure) }
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
                    .focused($codeFocused)
                    .onAppear { codeFocused = true }
                    .onChange(of: code) {
                        code = String(code.filter(\.isNumber).prefix(6))
                        if code.count == 6 { verify() }
                    }
                if canResend { QuietButton("Send it again") { send() } }
                QuietButton("Use a different email") {
                    codeSent = false
                    code = ""
                    error = nil
                }
            } else {
                Field("Email", text: $email, prompt: "you@example.com")
                    .keyboardType(.emailAddress).textContentType(.emailAddress).textInputAutocapitalization(.never)
                PrimaryButton("Send code", isLoading: sending) { send() }.disabled(!email.contains("@"))
            }
        }
    }

    private func send() {
        guard !sending else { return }
        sending = true
        error = nil
        email = email.trimmingCharacters(in: .whitespacesAndNewlines)
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
        case .offline: error = String(localized: "You're offline. Connect to sign in.", bundle: .module)
        case .invalid("code"): error = String(localized: "That code didn't match. Check the email and try again.", bundle: .module)
        case .rateLimited: error = String(localized: "Too many tries. Wait a minute and try again.", bundle: .module)
        case .suspended: error = AccountSuspension.message
        default: error = String(localized: "Couldn't sign in. Check your connection and try again.", bundle: .module)
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
                Text("You", bundle: .module).typeStyle(.display).foregroundStyle(Color.chalk).padding(.top, Space.s24)
                VStack(alignment: .leading, spacing: Space.s4) {
                    Field("Handle", text: $handle, prompt: "lowercase, numbers, _", limit: 20)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onChange(of: handle) { handle = handle.lowercased(); available = nil }
                    if let available {
                        if available {
                            Label { Text("Available", bundle: .module) } icon: { Image.symbol(Symbol.confirm) }
                                .typeStyle(.foot).foregroundStyle(Color.go)
                        } else {
                            Text("Taken", bundle: .module).typeStyle(.foot).foregroundStyle(Color.brake)
                        }
                    }
                }
                Field("Name", text: $name, prompt: "What friends call you", limit: 30)
                VStack(alignment: .leading, spacing: Space.s8) {
                    Text("Birth year", bundle: .module).typeStyle(.foot).foregroundStyle(Color.dust)
                    Picker("Birth year", selection: $birthYear) {
                        ForEach((1930...currentYear).reversed(), id: \.self) { Text(verbatim: String($0)).tag($0) }
                    }
                    .pickerStyle(.wheel)
                    .frame(maxHeight: Size.row * 2.5)
                    if !oldEnough {
                        Text("Waypoints is for drivers 17 and up.", bundle: .module).typeStyle(.foot).foregroundStyle(Color.brake)
                    }
                }
                if let error { Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake) }
                PrimaryButton("Continue", isLoading: saving) { save() }.disabled(!valid)
            }
            .padding(.horizontal, Space.margin)
            .padding(.bottom, Space.s16)
        }
        .background(Color.asphalt.ignoresSafeArea())
        .haptic(.tick, trigger: birthYear)
        .task(id: handle) {
            guard Profile.isValidHandle(handle) else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            do {
                let free = try await env.profiles.isHandleAvailable(handle)
                guard !Task.isCancelled else { return }
                available = free
                error = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.error = String(localized: "Couldn't check that handle. Check your connection and try again.", bundle: .module)
            }
        }
    }

    private func save() {
        saving = true
        error = nil
        Task {
            if case .blocked = await env.safety.check(handle + " " + name) {
                error = String(localized: "That handle or name can't be used. Try another.", bundle: .module)
                saving = false
                return
            }
            do {
                try await env.profiles.updateMyProfile(ProfileUpdate(handle: handle, displayName: name, birthYear: birthYear))
                next()
            } catch WaypointsError.conflict {
                available = false
            } catch {
                self.error = String(localized: "Couldn't save. Check your connection and try again.", bundle: .module)
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
            Text("What do you drive?", bundle: .module).typeStyle(.title).foregroundStyle(Color.chalk)
                .padding(.horizontal, Space.margin).padding(.vertical, Space.s8)
            if let error { Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake).padding(.horizontal, Space.margin) }
            VehiclePicker(catalog: env.catalog, garage: env.garage) { picked in
                guard case let .car(newCar) = picked else { return }
                Task {
                    do {
                        let car = try await env.garage.createCar(newCar)
                        try await env.profiles.updateMyProfile(ProfileUpdate(primaryCarID: car.id))
                        next()
                    } catch {
                        self.error = String(localized: "Couldn't add the car. Check your connection and try again.", bundle: .module)
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
    let done: () async throws -> Void
    @State private var showNearby = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s16) {
            ZStack {
                Map(initialPosition: .region(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: 39.93, longitude: -75.03),
                    span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08))), interactionModes: [])
                    .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
                HStack(spacing: Space.s32) {
                    sample(VehicleMarker(icon: "pony", paint: .sodium, role: .friend(name: "")), "Precise")
                    sample(VehicleMarker(icon: "pony", paint: .sodium, role: .approximate), "Approximate")
                    sample(Color.clear.frame(width: Size.Marker.friend, height: Size.Marker.friend), "Nothing")
                }
            }
            .frame(maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Radius.r20))
            .environment(\.colorScheme, .dark)
            Text("Who sees you", bundle: .module).typeStyle(.title).foregroundStyle(Color.chalk)
            Text("Friends see where you are. Everyone else sees nothing unless you say so. You can go ghost any time.", bundle: .module)
                .typeStyle(.body).foregroundStyle(Color.dust)
            VStack(spacing: 0) {
                radio("Hide me from drivers nearby", selected: !showNearby) { showNearby = false }
                radio("Show drivers nearby roughly where I am (within half a mile)", selected: showNearby) { showNearby = true }
            }
            // Rows carry their own side margin; let them run full width (plan 9.4).
            .padding(.horizontal, -Space.margin)
            if let error { Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake) }
            PrimaryButton("Turn on location", isLoading: working) { finish(requestLocation: true) }
            QuietButton("Not now") { finish(requestLocation: false) }.frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Space.margin)
        .padding(.bottom, Space.s16)
        .background(Color.asphalt.ignoresSafeArea())
    }

    private func sample(_ marker: some View, _ label: LocalizedStringKey) -> some View {
        VStack(spacing: Space.s4) {
            marker.accessibilityHidden(true)
            Text(label, bundle: .module).typeStyle(.foot).foregroundStyle(Color.chalk)
        }
    }

    private func radio(_ title: LocalizedStringKey, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Row(Text(title, bundle: .module), leading: {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.sodium : Color.gravel)
                    .accessibilityHidden(true)
            })
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func finish(requestLocation: Bool) {
        guard !working else { return }
        working = true
        error = nil
        Task {
            do {
                var settings = (try? await env.profiles.myPrivacySettings()) ?? .defaults
                settings.nearbyLevel = showNearby ? .approx : .hidden
                if showNearby { try await env.gateway.updatePrivacy(settings) } else { try? await env.gateway.updatePrivacy(settings) }
                if requestLocation {
                    await env.location.requestWhenInUse()
                    await env.location.setSharing(true)
                }
                try await done()
            } catch {
                self.error = String(localized: "Couldn't save. Check your connection and try again.", bundle: .module)
            }
            working = false
        }
    }
}
