import Core
import Foundation
import Supabase

// W10-8: reactions (MSG-11) and mute (SAFE-12).

extension LiveMessages {
    func reactions(for messages: [MessageID]) async throws -> [MessageID: [ReactionCount]] {
        guard !messages.isEmpty else { return [:] }
        struct Params: Encodable { let pMessages: [Int64] }
        struct Row: Decodable { let messageId: Int64; let reaction: String; let total: Int; let mine: Bool }
        let rows: [Row] = try await ctx.run {
            try await ctx.client.rpc("message_reaction_counts", params: Params(pMessages: messages.map(\.raw))).execute().value
        }
        var out: [MessageID: [ReactionCount]] = [:]
        for r in rows {
            guard let reaction = Reaction(rawValue: r.reaction) else { continue }
            out[MessageID(raw: r.messageId), default: []].append(ReactionCount(reaction: reaction, count: r.total, mine: r.mine))
        }
        return out
    }

    func setReaction(_ reaction: Reaction, on message: MessageID, to on: Bool) async throws {
        let me = try ctx.me()
        struct Body: Encodable { let messageId: Int64; let userId: UUID; let reaction: String }
        try await ctx.run {
            if on {
                _ = try await ctx.table("message_reactions")
                    .upsert(Body(messageId: message.raw, userId: me.raw, reaction: reaction.rawValue),
                            onConflict: "message_id,user_id,reaction", returning: .minimal, ignoreDuplicates: true)
                    .execute()
            } else {
                _ = try await ctx.table("message_reactions").delete(returning: .minimal)
                    .eq("message_id", value: String(message.raw)).eq("user_id", value: me.key)
                    .eq("reaction", value: reaction.rawValue).execute()
            }
        }
    }

    private func column(_ target: MuteTarget) -> (kind: String, id: UUID) {
        switch target {
        case let .user(id): ("user", id.raw)
        case let .thread(id): ("thread", id.raw)
        case let .channel(id): ("channel", id.raw)
        case let .team(id): ("team", id.raw)
        }
    }

    func mutes() async throws -> Set<MuteTarget> {
        let me = try ctx.me()
        struct Row: Decodable { let targetKind: String; let targetId: UUID; let until: Date? }
        let rows: [Row] = try await ctx.run {
            try await ctx.table("mutes").select("target_kind,target_id,until").eq("owner_id", value: me.key).execute().value
        }
        var out: Set<MuteTarget> = []
        for r in rows where r.until.map({ $0 > .now }) ?? true {
            switch r.targetKind {
            case "user": out.insert(.user(UserID(raw: r.targetId)))
            case "thread": out.insert(.thread(ThreadID(raw: r.targetId)))
            case "channel": out.insert(.channel(ChannelID(raw: r.targetId)))
            case "team": out.insert(.team(TeamID(raw: r.targetId)))
            default: break
            }
        }
        return out
    }

    func setMute(_ target: MuteTarget, for duration: MuteDuration?) async throws {
        let me = try ctx.me()
        let (kind, id) = column(target)
        struct Body: Encodable {
            let ownerId: UUID; let targetKind: String; let targetId: UUID; let until: Date?
            // `until` is written even when nil, so "until turned back on" replaces a timed mute.
            func encode(to encoder: any Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(ownerId, forKey: .ownerId); try c.encode(targetKind, forKey: .targetKind)
                try c.encode(targetId, forKey: .targetId); try c.encode(until, forKey: .until)
            }
            // Column names are literal: a custom encode bypasses snake_case conversion.
            enum CodingKeys: String, CodingKey {
                case ownerId = "owner_id", targetKind = "target_kind", targetId = "target_id", until
            }
        }
        try await ctx.run {
            if let duration {
                _ = try await ctx.table("mutes")
                    .upsert(Body(ownerId: me.raw, targetKind: kind, targetId: id, until: duration.end()),
                            onConflict: "owner_id,target_kind,target_id", returning: .minimal)
                    .execute()
            } else {
                _ = try await ctx.table("mutes").delete(returning: .minimal)
                    .eq("owner_id", value: me.key).eq("target_kind", value: kind)
                    .eq("target_id", value: id.uuidString.lowercased()).execute()
            }
        }
    }
}
