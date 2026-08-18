// Buffered WebSocket test client.
//
// The original per-file helpers attached `ws.once('message', ...)` at the
// moment a test wanted to read. Anything the server pushed between two awaits
// landed while no listener was attached and was lost forever, so the next read
// blocked until the test timed out. That made every test implicitly dependent
// on the exact number of messages the server happened to send, and turned any
// change in broadcast behaviour into a pile of unrelated-looking timeouts.
//
// This attaches one permanent listener at connect time and queues everything.
// Reads drain the queue, so a message is never missed regardless of when the
// test gets around to asking for it.

import { WebSocket } from 'ws';

/**
 * Server messages are asserted structurally by tests, so this is deliberately
 * loose: an index signature rather than the full ServerMessage union, which
 * would force a cast at every call site.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export type InboundMessage = { type: string; payload?: any };

interface Inbox {
  queue: unknown[];
  waiters: ((msg: unknown) => void)[];
}

const inboxes = new WeakMap<WebSocket, Inbox>();

/** Connect and start buffering inbound messages immediately. */
export function connectWs(port: number): Promise<WebSocket> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}`);
    const inbox: Inbox = { queue: [], waiters: [] };
    inboxes.set(ws, inbox);

    ws.on('message', (data: Buffer | string) => {
      const msg = JSON.parse(data.toString());
      const waiter = inbox.waiters.shift();
      if (waiter) waiter(msg);
      else inbox.queue.push(msg);
    });

    ws.on('open', () => resolve(ws));
    ws.on('error', reject);
  });
}

/** Next message, from the buffer if one is already waiting. */
export function receiveJson(ws: WebSocket): Promise<unknown> {
  const inbox = inboxes.get(ws);
  if (!inbox) throw new Error('socket was not created by connectWs()');
  const buffered = inbox.queue.shift();
  if (buffered !== undefined) return Promise.resolve(buffered);
  return new Promise((resolve) => inbox.waiters.push(resolve));
}

/** The next `count` messages, in order. */
export async function collectMessages(ws: WebSocket, count: number): Promise<unknown[]> {
  const msgs: unknown[] = [];
  for (let i = 0; i < count; i++) msgs.push(await receiveJson(ws));
  return msgs;
}

/**
 * Up to `count` messages, giving up after `timeoutMs` and returning whatever
 * arrived. Used by tests that assert on "at most N broadcasts".
 */
export async function collectMessagesWithTimeout(
  ws: WebSocket,
  count: number,
  timeoutMs = 2000,
): Promise<unknown[]> {
  const msgs: unknown[] = [];
  const deadline = Date.now() + timeoutMs;
  while (msgs.length < count) {
    const remaining = deadline - Date.now();
    if (remaining <= 0) break;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const timeout = new Promise<typeof SENTINEL>((resolve) => {
      timer = setTimeout(() => resolve(SENTINEL), remaining);
    });
    const msg = await Promise.race([receiveJson(ws), timeout]);
    if (timer) clearTimeout(timer);
    if (msg === SENTINEL) break;
    msgs.push(msg);
  }
  return msgs;
}

const SENTINEL = Symbol('timeout');

/**
 * Drain messages until `predicate` matches, or reject after `timeoutMs`.
 * Use when a test cares that a *particular* message arrives and not about how
 * many unrelated broadcasts precede it.
 */
export async function receiveUntil(
  ws: WebSocket,
  predicate: (msg: InboundMessage) => boolean,
  timeoutMs = 2000,
): Promise<InboundMessage> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const remaining = deadline - Date.now();
    if (remaining <= 0) throw new Error('receiveUntil: timed out');
    const msg = await Promise.race([
      receiveJson(ws),
      new Promise((_, rej) => setTimeout(() => rej(new Error('receiveUntil: timed out')), remaining)),
    ]);
    if (predicate(msg)) return msg;
  }
}

/** True when no buffered message is pending. */
export function inboxEmpty(ws: WebSocket): boolean {
  return (inboxes.get(ws)?.queue.length ?? 0) === 0;
}
