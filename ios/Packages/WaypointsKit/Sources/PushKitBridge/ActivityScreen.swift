import Core
import DesignSystem
import Foundation
import Observation
import SwiftUI

/// Activity (NTF-6): what happened to you in the last 90 days, newest first. Opening the list
/// marks everything read, which clears the bell's dot; rows read before stay without "New".
@MainActor
@Observable
final class ActivityModel {
    enum Phase { case loading, loaded, failed }

    private let env: AppEnvironment
    var items: [ActivityItem] = []
    var phase: Phase = .loading

    init(env: AppEnvironment) { self.env = env }

    func load() async {
        do {
            items = try await env.activity.recent(limit: 100)
            phase = .loaded
            if items.contains(where: \.isUnread) { try? await env.activity.markAllRead() }
        } catch {
            if items.isEmpty { phase = .failed }
        }
    }

    func open(_ item: ActivityItem) {
        guard let url = item.subjectURL, let route = ActivityLink.route(from: url) else { return }
        env.router.open(route)
    }
}

struct ActivityScreen: View {
    @State private var model: ActivityModel

    init(env: AppEnvironment) { _model = State(initialValue: ActivityModel(env: env)) }

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                ScrollView {
                    VStack(spacing: 0) { ForEach(0..<6, id: \.self) { _ in SkeletonRow() } }
                }
            case .failed:
                ErrorState(Text("Couldn't load activity. Check your connection and try again.")) {
                    Task { await model.load() }
                }
            case .loaded where model.items.isEmpty:
                Text("Nothing yet. Friend requests, likes, comments, and RSVPs to your meets show up here.")
                    .typeStyle(.body)
                    .foregroundStyle(Color.dust)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.margin)
                    .frame(maxHeight: .infinity, alignment: .top)
            case .loaded:
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.items) { item in
                            Button { model.open(item) } label: { ActivityRow(item: item) }
                                .buttonStyle(RowButtonStyle())
                                .disabled(item.subjectURL == nil)
                        }
                    }
                }
            }
        }
        .background(Color.asphalt.ignoresSafeArea())
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load() }
    }
}

private struct ActivityRow: View {
    let item: ActivityItem

    var body: some View {
        Row(Text(verbatim: item.title), subtitle: subtitle, leading: {
            Image.symbol(symbol)
                .foregroundStyle(item.isUnread ? Color.sodium : Color.dust)
                .frame(width: Size.hitTarget, height: Size.hitTarget)
                .background(Color.concrete, in: Circle())
        }, trailing: {
            VStack(alignment: .trailing, spacing: Space.s4) {
                Text(verbatim: item.createdAt.formatted(.relative(presentation: .numeric))).typeStyle(.readoutS)
                if item.isUnread {
                    Text("New").typeStyle(.label).foregroundStyle(Color.sodium)
                }
            }
        })
    }

    private var subtitle: Text? { item.body.map { Text(verbatim: $0) } }

    private var symbol: String {
        switch item.kind {
        case .friendRequest: Symbol.invite
        case .friendAccepted: "person.2"
        case .like: Symbol.like
        case .comment: Symbol.comment
        case .mention: "at"
        case .rsvp: "calendar"
        case .meetChanged: Symbol.time
        case .meetNearby: Symbol.place
        case .convoyInvite: "car.2"
        case .unlock: "seal"
        case .helpResponse: "wrench.and.screwdriver"
        case .other: "bell"
        }
    }
}

/// The `waypoints://` (and universal-link) paths the gateway and triggers write (plan 10.10,
/// X3). Parsed by Core's `Route(url:host:)`, the same parser `AppShell`'s `DeepLink` uses, so
/// every route a link can open (help, meet, profile, post, listing, team, thread, channel,
/// invites) opens from Activity too.
enum ActivityLink {
    static func route(from url: URL) -> Route? { Route(url: url, host: Route.linkHost) }
}
