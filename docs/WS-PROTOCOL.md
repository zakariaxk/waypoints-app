# Waypoints – WebSocket Protocol (MVP)

## Transport
- WebSocket JSON messages
- All messages have shape:
{
  "type": "STRING",
  "payload": { ... }
}

## IDs
- participantId: stable per user session (generated client-side or server-side at join)
- connId: generated per websocket connection
- eventId: server-assigned, monotonic per session (1,2,3...)

## Handshake

### Client -> Server: HELLO
type: "HELLO"
payload:
- sessionId: string
- participantId: string
- token: string (MVP: join token from /sessions/join)
- lastEventId: number | null (last event client applied)

### Server -> Client: WELCOME
type: "WELCOME"
payload:
- connId: string
- sessionId: string
- participantId: string
- latestEventId: number

### Server -> Client: SNAPSHOT
Sent right after WELCOME.
type: "SNAPSHOT"
payload:
- latestEventId: number
- destination: { lat, lng, label } | null
- participants: array of
  - participantId
  - lastLocation (optional)
  - lastSeenTs
  - status

### Server -> Client: EVENTS
If lastEventId is behind, server sends missed events.
type: "EVENTS"
payload:
- fromEventId: number
- toEventId: number
- events: array of event objects (see Event Types)

Client must apply events in order and ignore duplicates.

## Core Client -> Server Messages

### LOC_UPDATE
type: "LOC_UPDATE"
payload:
- seq: number (monotonic per client)
- lat: number
- lng: number
- speed: number | null
- heading: number | null
- accuracy: number | null
- ts: number (client epoch ms)

Server should rate limit per client (MVP: drop if too fast).

### SET_DESTINATION (host only in phase 1)
type: "SET_DESTINATION"
payload:
- lat: number
- lng: number
- label: string | null

### CHAT_SEND (optional)
type: "CHAT_SEND"
payload:
- messageId: string
- text: string
- ts: number

## Server -> Client Event Types (broadcast)
All events include:
- eventId: number
- ts: number (server epoch ms)
- kind: string
- data: object

### PARTICIPANT_JOINED
data: { participantId }

### PARTICIPANT_LEFT
data: { participantId }

### LOCATION_UPDATED
data: { participantId, lat, lng, speed, heading, accuracy, ts }

### DESTINATION_SET
data: { lat, lng, label }

### CHAT_MESSAGE (optional)
data: { participantId, messageId, text, ts }

## Error Handling
Server -> Client:
type: "ERROR"
payload:
- code: string (e.g., "BAD_MESSAGE", "UNAUTHORIZED", "NOT_IN_SESSION")
- message: string

Client should show a friendly error and attempt reconnect if appropriate.

## Reconnect Rules
- Client stores last applied eventId.
- On reconnect, client sends HELLO with lastEventId.
- Server sends SNAPSHOT then EVENTS for missed range.
- Client applies EVENTS in order; state after replay must match server.