import Foundation

/// W10-8 preview state: seeded reactions and stored mutes.
enum PreviewW10Reactions {
    /// A mute row: `until` nil means until turned back on.
    struct StoredMute: Sendable, Hashable { var until: Date? }

    /// MSG-11: Maya has already reacted in the seeded channel and Devon DM.
    static let seeded: [MessageID: [ReactionCount]] = [
        MessageID(raw: 1): [
            ReactionCount(reaction: .fire, count: 2, mine: true),
            ReactionCount(reaction: .thumbsUp, count: 1, mine: false),
        ],
        MessageID(raw: 6): [ReactionCount(reaction: .heart, count: 1, mine: true)],
    ]
}

extension PreviewStore {
    /// `mutes` keys are "kind:uuid" (kind: user, thread, channel, team).
    static func muteKey(_ target: MuteTarget) -> String {
        let pair: (String, UUID) = switch target {
        case let .user(id): ("user", id.raw)
        case let .thread(id): ("thread", id.raw)
        case let .channel(id): ("channel", id.raw)
        case let .team(id): ("team", id.raw)
        }
        return "\(pair.0):\(pair.1.uuidString.lowercased())"
    }

    static func muteTarget(_ key: String) -> MuteTarget? {
        let parts = key.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let id = UUID(uuidString: String(parts[1])) else { return nil }
        switch parts[0] {
        case "user": return .user(UserID(raw: id))
        case "thread": return .thread(ThreadID(raw: id))
        case "channel": return .channel(ChannelID(raw: id))
        case "team": return .team(TeamID(raw: id))
        default: return nil
        }
    }
}

extension PreviewStore {
    public func reactions(for ids: [MessageID]) async throws -> [MessageID: [ReactionCount]] {
        _ = try me()
        let wanted = Set(ids)
        return reactions.filter { wanted.contains($0.key) }
    }

    public func setReaction(_ reaction: Reaction, on message: MessageID, to on: Bool) async throws {
        let me = try me()
        guard let m = messages.first(where: { $0.id == message }), canRead(m.target, as: me), m.deletedAt == nil
        else { throw WaypointsError.notFound }
        var counts = reactions[message] ?? []
        if let i = counts.firstIndex(where: { $0.reaction == reaction }) {
            if on {
                if !counts[i].mine { counts[i].count += 1; counts[i].mine = true }
            } else if counts[i].mine {
                counts[i].count -= 1
                counts[i].mine = false
                if counts[i].count == 0 { counts.remove(at: i) }
            }
        } else if on {
            counts.append(ReactionCount(reaction: reaction, count: 1, mine: true))
        }
        reactions[message] = counts.isEmpty ? nil : counts
    }

    public func mutes() async throws -> Set<MuteTarget> {
        _ = try me()
        var out = Set<MuteTarget>()
        for (key, mute) in mutes where mute.until.map({ $0 > .now }) ?? true {
            if let target = PreviewStore.muteTarget(key) { out.insert(target) }
        }
        return out
    }

    public func setMute(_ target: MuteTarget, for duration: MuteDuration?) async throws {
        _ = try me()
        let key = PreviewStore.muteKey(target)
        if let duration { mutes[key] = PreviewW10Reactions.StoredMute(until: duration.end()) }
        else { mutes[key] = nil }
    }

    /// W10-8: per-channel unread, matching `LiveMessages.unreadCounts`.
    public func unreadCounts(in channels: [ChannelID]) async throws -> [ChannelID: Int] {
        let me = try me()
        var out: [ChannelID: Int] = [:]
        for c in channels where canRead(.channel(c), as: me) {
            let read = readMarkers[.channel(c)] ?? MessageID(raw: 0)
            let n = messages.filter {
                guard case .channel(let ch) = $0.target, ch == c, $0.authorID != me, $0.deletedAt == nil
                else { return false }
                return $0.id > read
            }.count
            if n > 0 { out[c] = min(n, 99) }
        }
        return out
    }
}
