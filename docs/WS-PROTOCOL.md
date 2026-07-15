# Waypoints – WebSocket Protocol

## Transport
- WebSocket JSON messages
- All messages have shape:
```json
{
  "type": "STRING",
  "payload": { ... }
}
```

## IDs
- participantId: stable per user session (generated server-side at create/join)
- connId: generated per websocket connection
- eventId: server-assigned, monotonic per session (1,2,3...)
- token: opaque auth token issued at create/join

## Handshake

### Client -> Server: HELLO

> **Auth upgrade (Phase 3)**: `participantId` is removed from the HELLO payload.
> The `token` field now carries a Supabase JWT instead of a random UUID.
> The server extracts `userId` from the JWT `sub` claim and resolves the participant
> by looking up `(userId, sessionId)` in the session state.
>
> **Migration period**: If the `token` is not a valid JWT (e.g., a UUID), the server
> falls back to legacy token matching (requires `participantId` to be present).

```json
{
  "type": "HELLO",
  "payload": {
    "sessionId": "string",
    "participantId": "string (OPTIONAL — omit for JWT auth, required for legacy auth)",
    "token": "string (Supabase JWT or legacy random token)",
    "lastEventId": "number | null"
  }
}
```

### Server -> Client: WELCOME
```json
{
  "type": "WELCOME",
  "payload": {
    "connId": "string",
    "sessionId": "string",
    "participantId": "string",
    "latestEventId": "number",
    "hostParticipantId": "string"
  }
}
```

### Server -> Client: SNAPSHOT
Sent right after WELCOME.
```json
{
  "type": "SNAPSHOT",
  "payload": {
    "latestEventId": "number",
    "destination": "{ lat, lng, label } | null",
    "participants": [
      {
        "participantId": "string",
        "displayName": "string | null",
        "lastLocation": "{ lat, lng, speed, heading, accuracy, ts } | null",
        "lastSeenTs": "number",
        "status": "online | stale | offline",
        "battery": "number (0..1) | null",
        "charging": "boolean | null",
        "arrived": "boolean",
        "sos": "{ note: string | null, ts: number } | null"
      }
    ],
    "activeSos": [
      {
        "participantId": "string",
        "note": "string | null",
        "lat": "number | null",
        "lng": "number | null",
        "ts": "number"
      }
    ]
  }
}
```
`activeSos` and per-row `sos`/`arrived`/`battery`/`charging` make safety state replayable on reconnect (Phase 3).

### Server -> Client: EVENTS
If `lastEventId` is behind, server sends missed events.
```json
{
  "type": "EVENTS",
  "payload": {
    "fromEventId": "number",
    "toEventId": "number",
    "events": ["...array of SessionEvent objects"]
  }
}
```
Client must apply events in order and ignore duplicates by eventId.

## Client -> Server Messages

### LOC_UPDATE
```json
{
  "type": "LOC_UPDATE",
  "payload": {
    "seq": "number (monotonic per client)",
    "lat": "number (-90 to 90)",
    "lng": "number (-180 to 180)",
    "speed": "number | null",
    "heading": "number | null",
    "accuracy": "number | null",
    "ts": "number (client epoch ms)",
    "battery": "number (0..1) | null  (optional, Phase 3)",
    "charging": "boolean | null  (optional, Phase 3)"
  }
}
```
Server rate limits per participant (900ms min interval). Excess updates silently dropped.
`battery`/`charging` are presence enrichment — stored on participant state, echoed in `SNAPSHOT` rows and `LOCATION_UPDATED` data. They are **not** a durable event kind (see DECISIONS: battery-not-an-event).

### SET_DESTINATION
```json
{
  "type": "SET_DESTINATION",
  "payload": {
    "lat": "number",
    "lng": "number",
    "label": "string | null"
  }
}
```
**Host-only.** Only the session creator (host) can set a destination. Non-host participants receive a `FORBIDDEN` error.

### CLEAR_DESTINATION
```json
{
  "type": "CLEAR_DESTINATION",
  "payload": {}
}
```
**Host-only.** Clears the current destination. Broadcasts `DESTINATION_CLEARED` event.

### CHAT_MESSAGE
```json
{
  "type": "CHAT_MESSAGE",
  "payload": {
    "text": "string (1-500 chars)"
  }
}
```
Server broadcasts with participantId and displayName attached.

### RAISE_SOS
```json
{
  "type": "RAISE_SOS",
  "payload": {
    "note": "string (≤140 chars, optional)"
  }
}
```
**Any participant.** Server sources the sender's last known location (does not trust a client-supplied position), assigns an `eventId`, records active SOS on session state, and broadcasts `SOS_RAISED`. Durable/replayable; included in `SNAPSHOT.activeSos`.

### CLEAR_SOS
```json
{
  "type": "CLEAR_SOS",
  "payload": {}
}
```
Clears **only the sender's own** SOS. Broadcasts `SOS_CLEARED`.

### ARRIVAL_PING
```json
{
  "type": "ARRIVAL_PING",
  "payload": {}
}
```
Server validates the sender is within `ARRIVAL_RADIUS_M` (default 50m) of the destination; if outside, replies `ERROR` with code `NOT_ARRIVED`. On success, marks arrival in session state and broadcasts `ARRIVAL_PINGED`.

### LEAVE_SESSION
```json
{
  "type": "LEAVE_SESSION",
  "payload": {}
}
```
Server broadcasts PARTICIPANT_LEFT event, then closes the WebSocket connection.

## Server -> Client Event Types (broadcast)

All events are delivered as:
```json
{
  "type": "EVENT",
  "payload": {
    "eventId": "number",
    "ts": "number (server epoch ms)",
    "kind": "string",
    "data": { "..." }
  }
}
```

### PARTICIPANT_JOINED
`data: { participantId: string, displayName: string | null }`

### PARTICIPANT_LEFT
`data: { participantId: string }`

### LOCATION_UPDATED
`data: { participantId, lat, lng, speed, heading, accuracy, ts, battery: number|null, charging: boolean|null }`

### DESTINATION_SET
`data: { lat, lng, label, setBy: participantId }`

### DESTINATION_CLEARED
`data: { clearedBy: participantId }`

### CHAT_MESSAGE
`data: { participantId: string, displayName: string | null, text: string }`

### SOS_RAISED
`data: { participantId: string, note: string | null, lat: number | null, lng: number | null, ts: number }`
Durable/replayable. `lat`/`lng` are the sender's last server-known location, or `null` if none yet (no camera-snap in that case). Active SOS is reflected in `SNAPSHOT.activeSos` + the participant row `sos`.

### SOS_CLEARED
`data: { participantId: string }`
Only the SOS owner can clear their own.

### ARRIVAL_PINGED
`data: { participantId: string, ts: number }`
Marks the participant as arrived (durable in `SNAPSHOT` row `arrived: true`); feeds Session Summary arrival order.

## Error Handling
```json
{
  "type": "ERROR",
  "payload": {
    "code": "BAD_MESSAGE | UNAUTHORIZED | NOT_IN_SESSION | RATE_LIMITED | FORBIDDEN | AUTH_EXPIRED | NOT_ARRIVED",
    "message": "string"
  }
}
```
- `FORBIDDEN` — returned when a non-host attempts a host-only action (e.g., SET_DESTINATION, CLEAR_DESTINATION).
- `AUTH_EXPIRED` — returned when the JWT token has expired. Client should refresh the token via Supabase Auth and reconnect.
- `NOT_ARRIVED` — returned when `ARRIVAL_PING` is sent from outside the arrival radius (dedicated code, not `BAD_MESSAGE` — see DECISIONS).
- Client should show a friendly error and attempt reconnect if appropriate.

## Authentication (Phase 3 — Supabase JWT)

### REST Endpoints
All mutating HTTP endpoints (`POST /sessions`, `POST /sessions/join`, friends API, profile API) require:
```
Authorization: Bearer <supabase_jwt>
```
The server verifies the JWT signature locally using `SUPABASE_JWT_SECRET` and extracts the `userId` from the `sub` claim. Read-only endpoints (`GET /health`, `GET /sessions/:id`) may remain public or be optionally authenticated.

### WebSocket Handshake
The `token` field in the HELLO message carries a Supabase JWT. The server:
1. Verifies JWT signature and expiry locally (no network call)
2. Extracts `userId` from the `sub` claim
3. Looks up the participant in the session by `userId`
4. If the JWT is expired → `ERROR { code: "AUTH_EXPIRED" }`
5. If no participant found for this user → `ERROR { code: "UNAUTHORIZED" }`

### Dual-Mode (Migration Period)
During migration, the server detects the token type:
- If `token` starts with `eyJ` (JWT header) → JWT verification flow
- Otherwise → legacy random token verification (requires `participantId` in payload)

Legacy mode will be removed after all clients are updated.

## Reconnect Rules
1. Client stores the last applied `eventId`.
2. On reconnect, client sends HELLO with `lastEventId`.
3. Server sends WELCOME → SNAPSHOT → EVENTS (for missed range) → PARTICIPANT_JOINED broadcast.
4. Client applies EVENTS in order; state after replay must match server.
5. If the event gap is too large (events evicted from ring buffer), client uses SNAPSHOT only.
6. **Voice is ephemeral**: VOICE_* messages are NOT emitted as type EVENT, NOT stored in the event ring buffer, and NOT replayed on reconnect. After reconnect, clients must re-join voice by sending `VOICE_JOIN` after receiving WELCOME/SNAPSHOT.

## Validation
All client messages are validated with Zod schemas on the server.
Invalid messages receive an ERROR response with code `BAD_MESSAGE` and details.

## Voice Chat Messages (Phase 2 — Ephemeral)

Voice signaling messages are **not** part of the ordered event stream. They are ephemeral peer-to-peer signaling relayed through the server. Voice membership is tracked in-memory per session via a `voiceMembers` set.

**Important**: Voice messages are NEVER emitted as `EVENT`, NEVER assigned an `eventId`, and NEVER stored in the replay ring buffer. On reconnect, clients must re-join voice by sending `VOICE_JOIN` after the WELCOME/SNAPSHOT sequence completes.

### Client → Server: VOICE_JOIN
```json
{
  "type": "VOICE_JOIN",
  "payload": {}
}
```
Adds sender to `voiceMembers` set. Broadcasts `VOICE_STATE` with `state: "joined"` to all session participants.

### Client → Server: VOICE_LEAVE
```json
{
  "type": "VOICE_LEAVE",
  "payload": {}
}
```
Removes sender from `voiceMembers` set. Broadcasts `VOICE_STATE` with `state: "left"` to all session participants. Also triggered automatically on disconnect or LEAVE_SESSION.

### Client → Server: VOICE_SIGNAL
```json
{
  "type": "VOICE_SIGNAL",
  "payload": {
    "toParticipantId": "string",
    "signalType": "offer | answer | ice",
    "data": { "..." }
  }
}
```
Relays WebRTC signaling data to a specific participant. Requirements:
- Sender must be in `voiceMembers` (must have sent VOICE_JOIN).
- `toParticipantId` must exist in the same session AND be in `voiceMembers`.
- SDP payloads (offer/answer) must be ≤ 40KB.
- ICE candidate payloads must be ≤ 8KB.
- SDP/ICE contents are NOT logged by the server.

### Server → Client: VOICE_SIGNAL
```json
{
  "type": "VOICE_SIGNAL",
  "payload": {
    "fromParticipantId": "string",
    "signalType": "offer | answer | ice",
    "data": { "..." }
  }
}
```
Forwarded to only the intended recipient. `fromParticipantId` is set by the server (sender's participantId).

### Server → Client: VOICE_STATE
```json
{
  "type": "VOICE_STATE",
  "payload": {
    "participantId": "string",
    "state": "joined | left"
  }
}
```
Broadcast to all session participants when a participant joins or leaves voice chat (including on disconnect/leave cleanup).