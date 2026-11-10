/**
 * Fan-out microbenchmark: serialization once, then write to N open recipients.
 * It intentionally has no persistence adapter/database calls.
 */
const recipients = Number(process.argv[2] ?? 50);
const rounds = Number(process.argv[3] ?? 20_000);
const message = JSON.stringify({ type: 'EVENT', payload: { eventId: 1, ts: Date.now(), kind: 'LOCATION_UPDATED', data: { participantId: 'p', lat: 40.7, lng: -74, speed: 5, heading: 90, accuracy: 8, ts: Date.now() } } });
let bytesWritten = 0;
const sockets = Array.from({ length: recipients }, () => ({ send: (payload: string) => { bytesWritten += payload.length; } }));
const start = performance.now();
for (let round = 0; round < rounds; round++) for (const socket of sockets) socket.send(message);
const elapsedMs = performance.now() - start;
const deliveries = recipients * rounds;
console.log(JSON.stringify({ recipients, rounds, deliveries, bytesWritten, elapsedMs: Number(elapsedMs.toFixed(2)), deliveriesPerSecond: Math.round(deliveries / (elapsedMs / 1000)), databaseCalls: 0 }));
