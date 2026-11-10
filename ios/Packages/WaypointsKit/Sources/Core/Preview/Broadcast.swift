import Foundation

/// Fan-out of values to any number of `AsyncStream` consumers. Owned by an actor.
struct Broadcast<Value: Sendable> {
    private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]

    mutating func subscribe(initial: Value? = nil) -> AsyncStream<Value> {
        let (stream, continuation) = AsyncStream<Value>.makeStream(bufferingPolicy: .bufferingNewest(16))
        if let initial { continuation.yield(initial) }
        continuations[UUID()] = continuation
        return stream
    }

    mutating func send(_ value: Value) {
        for (id, continuation) in continuations {
            if case .terminated = continuation.yield(value) { continuations[id] = nil }
        }
    }
}
