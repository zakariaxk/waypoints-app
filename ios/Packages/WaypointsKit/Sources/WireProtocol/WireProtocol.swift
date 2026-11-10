// The wire contract's Swift types live in realtime.pb.swift, generated from
// proto/waypoints/v1/realtime.proto by `make proto` (tools/proto.sh). Never edit
// the generated file; change the .proto and docs/PLAN.md section 6 together.

/// Constants of the wire contract that are not expressed in the .proto.
public enum WireProtocol {
    /// `Hello.protocol`: bumped on any breaking change to the wire contract.
    public static let protocolVersion: UInt32 = 1
    /// WebSocket path on the gateway.
    public static let path = "/v1/rt"
    /// Close code sent when the reliable lane overflows (`Error.Code.slowConsumer`).
    public static let slowConsumerCloseCode: UInt16 = 4008
}
