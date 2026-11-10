import AVFoundation
import AVKit
import Core
import DesignSystem
import LiveKit
import SwiftUI

/// Team voice channels over LiveKit (plan 10.7 T3). Route `voice`.
public enum VoiceFeature: FeatureModule {
    public static let isAvailable = true

    @MainActor
    public static func register(in registry: FeatureRegistry, env: AppEnvironment) {
        let session = VoiceSession(env: env)
        registry.registerRoute(.voice, presentation: .sheet) { route in
            guard case let .voice(id) = route else { return nil }
            return AnyView(VoiceSheet(session: session, channelID: id))
        }
    }
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
    var channel: Channel?
    var muted = true
    var speakers: [Speaker] = []
    var micDenied = false
    @ObservationIgnored private var room: Room?
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var lostSince: Date?

    init(env: AppEnvironment) { self.env = env }

    func join(_ id: ChannelID) async {
        if channel?.id == id, phase == .live { return }
        await leave()
        phase = .connecting
        channel = try? await env.teams.channel(id)
        do {
            let creds = try await env.gateway.voiceToken(for: id)
            let room = Room()
            try await room.connect(url: creds.url.absoluteString, token: creds.token)
            self.room = room
            muted = true
            phase = .live
            startPolling()
        } catch WaypointsError.forbidden {
            phase = .failed("You're not in this team.")
        } catch {
            phase = .failed("Voice is unavailable right now. Try again later.")
        }
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
        list.append(Speaker(id: "me", name: String(localized: "You"), speaking: local.isSpeaking, muted: muted))
        for (_, p) in room.remoteParticipants {
            list.append(Speaker(id: p.identity?.stringValue ?? UUID().uuidString, name: p.name ?? "Driver",
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
            if let since = lostSince, Date.now.timeIntervalSince(since) > 15 { Task { await leave() } }
        case .disconnected:
            Task { await leave() }
        default:
            break
        }
    }

    func toggleMute() async {
        guard let room else { return }
        if muted {
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted else { micDenied = true; return }
        }
        do {
            try await room.localParticipant.setMicrophone(enabled: muted)
            muted.toggle()
        } catch {
            micDenied = true
        }
    }

    func leave() async {
        poll?.cancel()
        poll = nil
        if let room { await room.disconnect() }
        room = nil
        speakers = []
        if phase != .idle, case .failed = phase {} else { phase = .idle }
    }
}

struct VoiceSheet: View {
    @Bindable var session: VoiceSession
    let channelID: ChannelID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var detent: PresentationDetent = .height(320)

    var body: some View {
        Group {
            if detent == .height(64) { strip } else { full }
        }
        .presentationDetents([.height(64), .height(320)], selection: $detent)
        .presentationBackgroundInteraction(.enabled)
        .interactiveDismissDisabled(session.phase == .live)
        .sheetChrome()
        .task { await session.join(channelID) }
    }

    private var strip: some View {
        HStack(spacing: Space.s12) {
            Circle().fill(session.speakers.contains(where: \.speaking) ? Color.xenon : Color.gravel).frame(width: Space.s8, height: Space.s8)
            Text(verbatim: session.channel?.name ?? "Voice").typeStyle(.bodyStrong).foregroundStyle(Color.chalk)
            Spacer()
            IconButton(session.muted ? Symbol.micOff : Symbol.micOn, label: session.muted ? "Unmute" : "Mute") {
                Task { await session.toggleMute() }
            }
            IconButton(Symbol.close, label: "Leave") { Task { await session.leave(); dismiss() } }
        }
        .padding(.horizontal, Space.margin)
    }

    private var full: some View {
        VStack(alignment: .leading, spacing: Space.s16) {
            Text(verbatim: session.channel?.name ?? "Voice").typeStyle(.title).foregroundStyle(Color.chalk)
            switch session.phase {
            case let .failed(message):
                Text(verbatim: message).typeStyle(.body).foregroundStyle(Color.dust)
            case .connecting:
                Text("Connecting").typeStyle(.sub).foregroundStyle(Color.dust)
            case .reconnecting:
                Text("Reconnecting").typeStyle(.sub).foregroundStyle(Color.sodium)
            default:
                if session.muted { Text("You're muted. Tap to talk.").typeStyle(.sub).foregroundStyle(Color.dust) }
            }
            if session.micDenied {
                HStack {
                    Text("Microphone is off for Waypoints.").typeStyle(.sub).foregroundStyle(Color.chalk)
                    QuietButton("Open Settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: Space.s12) {
                ForEach(session.speakers) { s in
                    VStack(spacing: Space.s4) {
                        Avatar(name: s.name, size: .s64)
                            .overlay(Circle().strokeBorder(s.speaking ? Color.xenon : .clear, lineWidth: Size.Marker.ring))
                            .opacity(session.phase == .connecting ? 0.5 : 1)
                        Text(verbatim: s.name).typeStyle(.foot).foregroundStyle(Color.chalk).lineLimit(1)
                    }
                }
            }
            HStack(spacing: Space.s16) {
                IconButton(session.muted ? Symbol.micOff : Symbol.micOn, label: session.muted ? "Unmute" : "Mute") {
                    Task { await session.toggleMute() }
                }
                RoutePicker().frame(width: Size.hitTarget, height: Size.hitTarget)
                DestructiveButton("Leave", confirmTitle: "Leave voice", consequence: "You'll stop hearing the channel.") {
                    Task { await session.leave(); dismiss() }
                }
            }
        }
        .padding(Space.margin)
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
