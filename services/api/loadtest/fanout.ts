// WebSocket fan-out benchmark.
//
// Measures the thing the architecture actually claims: how long it takes an
// event sent by one participant to reach the others in the same session, at a
// given number of concurrent sessions and participants.
//
// Deliberately small — plain Node plus the `ws` dependency the server already
// has. No k6, no Artillery, no dashboards. The point is a number you can
// defend, not a load-testing platform.
//
// Usage (server must already be running):
//   npx tsx loadtest/fanout.ts --sessions 5 --participants 10 --seconds 60
//   npx tsx loadtest/fanout.ts --url ws://127.0.0.1:3000 --http http://127.0.0.1:3000

import { WebSocket } from 'ws';

interface Options {
  http: string;
  url: string;
  sessions: number;
  participants: number;
  seconds: number;
  /** Fraction of participants that drop and reconnect per minute. */
  churn: number;
}

function parseArgs(argv: string[]): Options {
  const get = (name: string, fallback: string): string => {
    const i = argv.indexOf(`--${name}`);
    return i !== -1 && argv[i + 1] ? argv[i + 1] : fallback;
  };
  return {
    http: get('http', 'http://127.0.0.1:3000'),
    url: get('url', 'ws://127.0.0.1:3000'),
    sessions: Number(get('sessions', '1')),
    participants: Number(get('participants', '20')),
    seconds: Number(get('seconds', '30')),
    churn: Number(get('churn', '0.05')),
  };
}

interface Client {
  ws: WebSocket;
  sessionId: string;
  participantId: string;
  token: string;
  lastEventId: number;
}

const latencies: number[] = [];
/** sendKey -> send timestamp, for matching a broadcast back to its origin. */
const sentAt = new Map<string, number>();
let received = 0;
let reconnects = 0;

async function postJson<T>(url: string, body: unknown): Promise<T> {
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`${url} -> ${res.status} ${await res.text()}`);
  return (await res.json()) as T;
}

function connect(opts: Options, client: Client): Promise<void> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(opts.url);
    client.ws = ws;

    ws.on('open', () => {
      ws.send(
        JSON.stringify({
          type: 'HELLO',
          payload: {
            sessionId: client.sessionId,
            participantId: client.participantId,
            token: client.token,
            lastEventId: client.lastEventId || null,
          },
        }),
      );
    });

    ws.on('message', (raw) => {
      const msg = JSON.parse(raw.toString());
      if (msg.type === 'WELCOME') resolve();
      if (msg.type === 'SNAPSHOT') client.lastEventId = msg.payload.latestEventId;

      if (msg.type === 'EVENT' && msg.payload?.kind === 'LOCATION_UPDATED') {
        client.lastEventId = msg.payload.eventId;
        // The sender encodes its send time in `ts`, so any receiver can
        // compute fan-out latency without cross-process clock sync (single
        // host). Skip our own echo — we want cross-participant delivery.
        const data = msg.payload.data;
        if (data.participantId !== client.participantId) {
          const key = `${data.participantId}:${data.ts}`;
          const t0 = sentAt.get(key);
          if (t0 !== undefined) {
            latencies.push(performance.now() - t0);
            received++;
          }
        }
      }
    });

    ws.on('error', reject);
  });
}

function percentile(sorted: number[], p: number): number {
  if (sorted.length === 0) return 0;
  const i = Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length));
  return sorted[i];
}

async function main(): Promise<void> {
  const opts = parseArgs(process.argv.slice(2));
  console.log(
    `fan-out benchmark: ${opts.sessions} sessions x ${opts.participants} participants, ` +
      `${opts.seconds}s, 1 loc-update/sec, ${(opts.churn * 100).toFixed(0)}%/min churn`,
  );

  const clients: Client[] = [];

  for (let s = 0; s < opts.sessions; s++) {
    const host = await postJson<{
      sessionId: string;
      joinCode: string;
      participantId: string;
      token: string;
    }>(`${opts.http}/sessions`, { displayName: `host-${s}` });

    clients.push({
      ws: null as unknown as WebSocket,
      sessionId: host.sessionId,
      participantId: host.participantId,
      token: host.token,
      lastEventId: 0,
    });

    for (let p = 1; p < opts.participants; p++) {
      const joined = await postJson<{
        sessionId: string;
        participantId: string;
        token: string;
      }>(`${opts.http}/sessions/join`, {
        joinCode: host.joinCode,
        displayName: `p-${s}-${p}`,
      });
      clients.push({
        ws: null as unknown as WebSocket,
        sessionId: joined.sessionId,
        participantId: joined.participantId,
        token: joined.token,
        lastEventId: 0,
      });
    }
  }

  await Promise.all(clients.map((c) => connect(opts, c)));
  console.log(`connected ${clients.length} clients`);

  let seq = 0;
  const startedAt = performance.now();

  const ticker = setInterval(() => {
    seq++;
    for (const c of clients) {
      if (c.ws.readyState !== WebSocket.OPEN) continue;
      const ts = Date.now() + seq; // unique per participant per tick
      sentAt.set(`${c.participantId}:${ts}`, performance.now());
      c.ws.send(
        JSON.stringify({
          type: 'LOC_UPDATE',
          payload: {
            seq,
            lat: 40 + Math.sin(seq / 10) / 100,
            lng: -74 + Math.cos(seq / 10) / 100,
            speed: 1.4,
            heading: 90,
            accuracy: 5,
            ts,
          },
        }),
      );
    }
  }, 1000);

  // Reconnect churn: a fraction of clients drop and come back each minute,
  // exercising the snapshot/replay path under load rather than only steady state.
  const churnTimer = setInterval(() => {
    const n = Math.max(1, Math.round(clients.length * opts.churn));
    for (let i = 0; i < n; i++) {
      const c = clients[Math.floor(Math.random() * clients.length)];
      if (c.ws.readyState === WebSocket.OPEN) {
        c.ws.close();
        reconnects++;
        setTimeout(() => void connect(opts, c).catch(() => {}), 500);
      }
    }
  }, 60_000);

  await new Promise((r) => setTimeout(r, opts.seconds * 1000));
  clearInterval(ticker);
  clearInterval(churnTimer);
  for (const c of clients) c.ws.close();

  const elapsed = (performance.now() - startedAt) / 1000;
  const sorted = [...latencies].sort((a, b) => a - b);
  const mem = process.memoryUsage();

  console.log('');
  console.log(`clients            ${clients.length}`);
  console.log(`duration           ${elapsed.toFixed(1)}s`);
  console.log(`deliveries matched ${received}`);
  console.log(`reconnects         ${reconnects}`);
  console.log(`events/sec (recv)  ${(received / elapsed).toFixed(0)}`);
  console.log(`p50 fan-out        ${percentile(sorted, 50).toFixed(1)} ms`);
  console.log(`p95 fan-out        ${percentile(sorted, 95).toFixed(1)} ms`);
  console.log(`p99 fan-out        ${percentile(sorted, 99).toFixed(1)} ms`);
  console.log(`max fan-out        ${(sorted[sorted.length - 1] ?? 0).toFixed(1)} ms`);
  console.log(`client RSS         ${(mem.rss / 1024 / 1024).toFixed(0)} MB`);
  console.log('');
  console.log('NOTE: client and server share a host here, so these numbers');
  console.log('exclude real network latency. They measure server fan-out cost.');

  // Non-zero exit if a p99 budget was given and missed — lets CI assert.
  const budget = Number(
    process.argv.includes('--p99-budget-ms')
      ? process.argv[process.argv.indexOf('--p99-budget-ms') + 1]
      : NaN,
  );
  if (!Number.isNaN(budget) && percentile(sorted, 99) > budget) {
    console.error(`FAIL: p99 ${percentile(sorted, 99).toFixed(1)}ms exceeds budget ${budget}ms`);
    process.exit(1);
  }
  process.exit(0);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
