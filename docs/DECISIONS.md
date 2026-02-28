# Decisions

- WebSockets: ws (custom JSON protocol)
- MVP: single backend instance, in-memory state
- Update rate: 1/sec per client
- No Redis until scaling

## 2026-02-28 — Voice events are ephemeral and not replayed

**Context**: Adding Phase 2 Voice Chat with WebRTC signaling relayed through the WebSocket server.

**Decision**: VOICE_* messages (VOICE_JOIN, VOICE_LEAVE, VOICE_SIGNAL, VOICE_STATE) are NOT emitted as type `EVENT`, NOT assigned an `eventId`, and NOT stored in the replay ring buffer.

**Rationale**:
- Voice signaling data (SDP offers/answers, ICE candidates) is connection-specific and meaningless after the original peer connection is gone.
- Replaying voice join/leave states on reconnect would create stale/incorrect voice membership state.
- Voice membership is inherently tied to an active WebSocket connection — if the connection drops, the peer connections are already dead.
- Keeping voice ephemeral keeps the event buffer clean and focused on session state that can be meaningfully replayed.

**Rule**: On reconnect, clients must re-join voice by sending `VOICE_JOIN` after receiving WELCOME/SNAPSHOT. The server cleans up voice membership automatically on disconnect or LEAVE_SESSION.