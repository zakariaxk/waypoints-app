import Foundation

/// Fans one value out to any number of `AsyncStream` consumers. Each `subscribe` gets its own
/// stream; terminated streams are dropped on the next `send`.
actor Fanout<Value: Sendable> {
    private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]
    private(set) var latest: Value?

    func subscribe(initial: Value? = nil) -> AsyncStream<Value> {
        let (stream, continuation) = AsyncStream<Value>.makeStream(bufferingPolicy: .bufferingNewest(16))
        if let first = initial ?? latest { continuation.yield(first) }
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.drop(id) }
        }
        return stream
    }

    var hasSubscribers: Bool { !continuations.isEmpty }

    func send(_ value: Value) {
        latest = value
        for (id, continuation) in continuations {
            if case .terminated = continuation.yield(value) { continuations[id] = nil }
        }
    }

    private func drop(_ id: UUID) { continuations[id] = nil }
}

/// Keyed fan-outs, for streams scoped to one owner or one conversation.
actor FanoutTable<Key: Hashable & Sendable, Value: Sendable> {
    private var table: [Key: Fanout<Value>] = [:]

    func fanout(for key: Key) -> Fanout<Value> {
        if let existing = table[key] { return existing }
        let made = Fanout<Value>()
        table[key] = made
        return made
    }

    func existing(for key: Key) -> Fanout<Value>? { table[key] }
}
