import AVFoundation
import AVKit
import Core
import DesignSystem
import LiveKit
import SwiftUI

/// Voice over LiveKit (plan 10.7 T3): team voice channels (route `voice`) and every
/// convoy's own room (route `convoyVoice`, CNV-11). One session at a time; joining
/// another room leaves the current one.
public enum VoiceFeature: FeatureModule {
    public static let isAvailable = true

    @MainActor
    public static func register(in registry: FeatureRegistry, env: AppEnvironment) {
        let session = VoiceSession(env: env)
        registry.registerRoute(.voice, presentation: .sheet) { route in
            guard case let .voice(id) = route else { return nil }
            return AnyView(VoiceSheet(session: session, room: .channel(id)))
        }
        registry.registerRoute(.convoyVoice, presentation: .sheet) { route in
            guard case let .convoyVoice(id) = route else { return nil }
            return AnyView(VoiceSheet(session: session, room: .convoy(id)))
        }
    }
}

enum VoiceRoom: Hashable, Sendable {
    case channel(ChannelID)
    case convoy(ConvoyID)
}

struct Speaker: Identifiable, Hashable {
    var id: String
    var name: String
    var speaking: Bool
    var muted: Bool
}

@MainActor
@Observable
final class VoiceSession {
    enum Phase: Equatable { case idle, connecting, live, reconnecting, failed(String) }
    let env: AppEnvironment
    var phase: Phase = .idle
    var current: VoiceRoom?
    var title = ""
    var muted = true
    var speakers: [Speaker] = []
    var micDenied = false
    var toast: ToastMessage?
    /// Bumped when the session ends on its own (room closed, convoy ended, connection lost); the sheet dismisses.
    var closed = 0
    @ObservationIgnored private var room: Room?
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var watch: Task<Void, Never>?
    @ObservationIgnored private var lostSince: Date?
    @ObservationIgnored private var closing = false

    init(env: AppEnvironment) { self.env = env }

    func join(_ target: VoiceRoom) async {
        if current == target, phase == .live || phase == .reconnecting { return }
        await leave()
        current = target
        phase = .connecting
        closing = false
        do {
            let creds: VoiceCredentials
            switch target {
            case let .channel(id):
                title = (try? await env.teams.channel(id))?.name ?? String(localized: "Voice", bundle: .module)
                creds = try await env.gateway.voiceToken(for: id)
            case let .convoy(id):
                title = String(localized: "Convoy", bundle: .module)
                creds = try await env.gateway.voiceToken(forConvoy: id)
            }
            let room = Room()
            try await room.connect(url: creds.url.absoluteString, token: creds.token)
            guard current == target, !Task.isCancelled else {
                await room.disconnect()
                if current == target { phase = .idle }
                return
            }
            self.room = room
            muted = true
            micDenied = false
            phase = .live
            if case let .convoy(id) = target { watchConvoy(id) }
            startPolling()
        } catch WaypointsError.forbidden {
            if case .convoy = target { phase = .failed(String(localized: "You're not in this convoy.", bundle: .module)) }
            else { phase = .failed(String(localized: "You're not in this team.", bundle: .module)) }
        } catch {
            phase = Task.isCancelled ? .idle : .failed(String(localized: "Voice is unavailable right now. Try again later.", bundle: .module))
        }
    }

    /// The convoy room is left when the convoy ends (CNV-11). A member who leaves the
    /// convoy is removed from the room by the gateway, which lands in `.disconnected`.
    private func watchConvoy(_ id: ConvoyID) {
        watch?.cancel()
        let env = self.env
        watch = Task { [weak self] in
            for await event in await env.realtime.events() {
                guard case let .convoy(s) = event, s.id == id, s.ended else { continue }
                await self?.close(lost: false)
                return
            }
        }
    }

    /// Ends the session without the user asking: VOX-5 shows "Voice disconnected." when the connection was lost.
    private func close(lost: Bool) async {
        guard !closing else { return }
        closing = true
        await leave()
        if lost {
            toast = ToastMessage(Text("Voice disconnected.", bundle: .module))
            try? await Task.sleep(for: .seconds(Timing.toast))
        }
        closed += 1
    }

    private func startPolling() {
        poll = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    private func refresh() {
        guard let room else { return }
        var list: [Speaker] = []
        let local = room.localParticipant
        list.append(Speaker(id: "me", name: String(localized: "You", bundle: .module), speaking: local.isSpeaking, muted: muted))
        for (sid, p) in room.remoteParticipants {
            list.append(Speaker(id: p.identity?.stringValue ?? sid.stringValue, name: p.name ?? "Driver",
                                speaking: p.isSpeaking, muted: !p.isMicrophoneEnabled()))
        }
        speakers = list
        switch room.connectionState {
        case .connected:
            phase = .live
            lostSince = nil
        case .reconnecting:
            phase = .reconnecting
            lostSince = lostSince ?? .now
            if let since = lostSince, Date.now.timeIntervalSince(since) > 15 { Task { await close(lost: true) } }
        case .disconnected:
            let wasLost = lostSince != nil
            Task { await close(lost: wasLost) }
        default:
            break
        }
    }

    /// SAFE-1: participants are reportable. A channel identity is the user id; a convoy
    /// identity is the realtime uid, resolved through the profile (server/internal/voice).
    func report(_ s: Speaker) async {
        let user: UserID?
        switch current {
        case .channel:
            user = UserID(string: s.id)
        case .convoy:
            guard let uid = RealtimeUID(s.id) else { return }
            user = (try? await env.profiles.profile(uid: uid))?.userID
        case nil:
            user = nil
        }
        guard let user else { return }
        env.router.open(.reportContent(.user(user)))
    }

    func toggleMute() async {
        guard let room else { return }
        if muted {
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted else { micDenied = true; return }
        }
        let enable = muted
        do {
            try await room.localParticipant.setMicrophone(enabled: enable)
            muted = !enable
            micDenied = false
        } catch {
            micDenied = true
        }
    }

    func leave() async {
        poll?.cancel()
        poll = nil
        watch?.cancel()
        watch = nil
        lostSince = nil
        if let room { await room.disconnect() }
        room = nil
        speakers = []
        if phase != .idle, case .failed = phase {} else { phase = .idle }
    }
}

struct VoiceSheet: View {
    @Bindable var session: VoiceSession
    let room: VoiceRoom
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var detent: PresentationDetent = .height(320)
    /// The collapsed strip (plan T3: 44 pt).
    private let stripDetent = PresentationDetent.height(Size.hitTarget)

    private var isConvoy: Bool {
        if case .convoy = room { true } else { false }
    }

    var body: some View {
        Group {
            if detent == stripDetent { strip } else { full }
        }
        .presentationDetents([stripDetent, .height(320)], selection: $detent)
        .presentationBackgroundInteraction(.enabled)
        .interactiveDismissDisabled(session.phase == .live || session.phase == .reconnecting)
        .sheetChrome()
        .toast($session.toast)
        .task(id: room) { await session.join(room) }
        .onChange(of: session.closed) { dismiss() }
    }

    private var strip: some View {
        HStack(spacing: Space.s12) {
            let speaking = session.speakers.contains(where: \.speaking)
            Image.symbol(Symbol.speaker).symbolVariant(speaking ? .fill : .none)
                .foregroundStyle(speaking ? Color.xenon : Color.gravel)
                .accessibilityLabel(Text("Speaking", bundle: .module))
                .accessibilityHidden(!speaking)
            Text(verbatim: session.title).typeStyle(.bodyStrong).foregroundStyle(Color.chalk).lineLimit(1)
            Spacer(minLength: 0)
            IconButton(session.muted ? Symbol.micOff : Symbol.micOn, label: session.muted ? "Unmute" : "Mute") {
                Task { await session.toggleMute() }
            }
            IconButton(Symbol.close, label: "Leave") { Task { await session.leave(); dismiss() } }
        }
        .padding(.horizontal, Space.margin)
    }

    private var full: some View {
        VStack(alignment: .leading, spacing: Space.s16) {
            Text(verbatim: session.title).typeStyle(.title).foregroundStyle(Color.chalk)
            switch session.phase {
            case let .failed(message):
                Text(verbatim: message).typeStyle(.body).foregroundStyle(Color.dust)
            case .connecting:
                Text("Connecting", bundle: .module).typeStyle(.sub).foregroundStyle(Color.dust)
            case .reconnecting:
                Text("Reconnecting", bundle: .module).typeStyle(.sub).foregroundStyle(Color.sodium)
            default:
                if session.muted { Text("You're muted. Tap to talk.", bundle: .module).typeStyle(.sub).foregroundStyle(Color.dust) }
            }
            if session.micDenied {
                HStack {
                    Text("Microphone is off for Waypoints.", bundle: .module).typeStyle(.sub).foregroundStyle(Color.chalk)
                    QuietButton("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: Space.s12) {
                ForEach(session.speakers) { s in
                    VStack(spacing: Space.s4) {
                        Avatar(name: s.name, size: .s64)
                            .overlay(Circle().strokeBorder(s.speaking ? Color.xenon : .clear, lineWidth: Size.Marker.ring))
                            .motion(.quick, value: s.speaking)
                            .opacity(session.phase == .connecting ? Opacity.trail : 1)
                        Text(verbatim: s.name).typeStyle(.foot).foregroundStyle(Color.chalk).lineLimit(1)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(s.speaking ? Text("\(s.name), speaking", bundle: .module)
                                        : s.muted ? Text("\(s.name), muted", bundle: .module) : Text(verbatim: s.name))
                    .contextMenu {
                        if s.id != "me" {
                            Button("Report") { Task { await session.report(s) } }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            if case .failed = session.phase {
                // Nothing to mute, route, or leave: the room was never joined.
                SecondaryButton("Close") { Task { await session.leave(); dismiss() } }
            } else {
                HStack(spacing: Space.s16) {
                    IconButton(session.muted ? Symbol.micOff : Symbol.micOn, label: session.muted ? "Unmute" : "Mute") {
                        Task { await session.toggleMute() }
                    }
                    RoutePicker().frame(width: Size.hitTarget, height: Size.hitTarget)
                    DestructiveButton("Leave", confirmTitle: "Leave voice", consequence: isConvoy ? "You'll stop hearing the convoy." : "You'll stop hearing the channel.") {
                        Task { await session.leave(); dismiss() }
                    }
                }
            }
        }
        .padding(.horizontal, Space.margin)
        .padding(.top, Space.s24)
        .padding(.bottom, Space.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The system audio route picker (speaker, car, headphones).
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = UIColor(Color.chalk)
        v.activeTintColor = UIColor(Color.sodium)
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
