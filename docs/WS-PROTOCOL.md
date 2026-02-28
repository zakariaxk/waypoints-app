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
```json
{
  "type": "HELLO",
  "payload": {
    "sessionId": "string",
    "participantId": "string",
    "token": "string",
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
    "latestEventId": "number"
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
        "status": "online | stale | offline"
      }
    ]
  }
}
```

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
    "ts": "number (client epoch ms)"
  }
}
```
Server rate limits per participant (900ms min interval). Excess updates silently dropped.

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
Any participant can set a destination. Everyone sees it on the map.

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
`data: { participantId, lat, lng, speed, heading, accuracy, ts }`

### DESTINATION_SET
`data: { lat, lng, label }`

### CHAT_MESSAGE
`data: { participantId: string, displayName: string | null, text: string }`

## Error Handling
```json
{
  "type": "ERROR",
  "payload": {
    "code": "BAD_MESSAGE | UNAUTHORIZED | NOT_IN_SESSION | RATE_LIMITED",
    "message": "string"
  }
}
```
Client should show a friendly error and attempt reconnect if appropriate.

## Reconnect Rules
1. Client stores the last applied `eventId`.
2. On reconnect, client sends HELLO with `lastEventId`.
3. Server sends WELCOME → SNAPSHOT → EVENTS (for missed range) → PARTICIPANT_JOINED broadcast.
4. Client applies EVENTS in order; state after replay must match server.
5. If the event gap is too large (events evicted from ring buffer), client uses SNAPSHOT only.

## Validation
All client messages are validated with Zod schemas on the server.
Invalid messages receive an ERROR response with code `BAD_MESSAGE` and details.