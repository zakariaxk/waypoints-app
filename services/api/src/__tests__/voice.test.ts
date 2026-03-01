import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import Fastify, { type FastifyInstance } from 'fastify';
import { WebSocket } from 'ws';
import { registerRoutes } from '../http/routes.js';
import { setupWebSocket } from '../ws/handler.js';

let app: FastifyInstance;
let port: number;

async function startServer(): Promise<void> {
  app = Fastify({ logger: false });
  await registerRoutes(app);
  await app.listen({ port: 0, host: '127.0.0.1' });
  setupWebSocket(app.server);
  const addr = app.server.address();
  port = typeof addr === 'object' && addr ? addr.port : 0;
}

async function stopServer(): Promise<void> {
  await app?.close();
}

function connectWs(): Promise<WebSocket> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}`);
    ws.on('open', () => resolve(ws));
    ws.on('error', reject);
  });
}

function receiveJson(ws: WebSocket): Promise<unknown> {
  return new Promise((resolve) => {
    ws.once('message', (data) => {
      resolve(JSON.parse(data.toString()));
    });
  });
}

function collectMessages(ws: WebSocket, count: number, timeoutMs = 2000): Promise<unknown[]> {
  return new Promise((resolve, reject) => {
    const msgs: unknown[] = [];
    const timer = setTimeout(() => {
      ws.off('message', handler);
      resolve(msgs); // return whatever we have
    }, timeoutMs);
    const handler = (data: Buffer | string) => {
      msgs.push(JSON.parse(data.toString()));
      if (msgs.length >= count) {
        clearTimeout(timer);
        ws.off('message', handler);
        resolve(msgs);
      }
    };
    ws.on('message', handler);
  });
}

async function createAndJoin(displayName = 'TestUser'): Promise<{
  sessionId: string;
  participantId: string;
  token: string;
  joinCode: string;
}> {
  const res = await app.inject({
    method: 'POST',
    url: '/sessions',
    payload: { displayName },
  });
  return res.json();
}

async function joinWithCode(
  joinCode: string,
  displayName = 'Joiner',
): Promise<{ sessionId: string; participantId: string; token: string }> {
  const res = await app.inject({
    method: 'POST',
    url: '/sessions/join',
    payload: { joinCode, displayName },
  });
  return res.json();
}

async function doHello(
  ws: WebSocket,
  sessionId: string,
  participantId: string,
  token: string,
): Promise<unknown[]> {
  ws.send(
    JSON.stringify({
      type: 'HELLO',
      payload: { sessionId, participantId, token, lastEventId: null },
    }),
  );
  return collectMessages(ws, 3); // WELCOME, SNAPSHOT, PARTICIPANT_JOINED
}

function send(ws: WebSocket, type: string, payload: unknown): void {
  ws.send(JSON.stringify({ type, payload }));
}

describe('Voice Chat', () => {
  beforeEach(async () => {
    await startServer();
  });
  afterEach(async () => {
    await stopServer();
  });

  // ─── VOICE_JOIN ───

  it('VOICE_JOIN adds participant to voiceMembers and broadcasts VOICE_STATE joined', async () => {
    const alice = await createAndJoin('Alice');
    const bob = await joinWithCode(alice.joinCode, 'Bob');

    const wsA = await connectWs();
    const wsB = await connectWs();
    await doHello(wsA, alice.sessionId, alice.participantId, alice.token);
    // Bob's HELLO triggers PARTICIPANT_JOINED on Alice's socket too
    const bobHelloMsgs = collectMessages(wsA, 1); // will receive Bob's PARTICIPANT_JOINED
    await doHello(wsB, alice.sessionId, bob.participantId, bob.token);
    await bobHelloMsgs;

    // Alice joins voice
    const bobReceives = collectMessages(wsB, 1);
    send(wsA, 'VOICE_JOIN', {});

    // Alice also receives her own VOICE_STATE
    const aliceVoiceState = (await receiveJson(wsA)) as {
      type: string;
      payload: { participantId: string; state: string };
    };
    expect(aliceVoiceState.type).toBe('VOICE_STATE');
    expect(aliceVoiceState.payload.participantId).toBe(alice.participantId);
    expect(aliceVoiceState.payload.state).toBe('joined');

    // Bob receives VOICE_STATE for Alice
    const bobMsgs = await bobReceives;
    const bobVoiceState = bobMsgs[0] as {
      type: string;
      payload: { participantId: string; state: string };
    };
    expect(bobVoiceState.type).toBe('VOICE_STATE');
    expect(bobVoiceState.payload.participantId).toBe(alice.participantId);
    expect(bobVoiceState.payload.state).toBe('joined');

    wsA.close();
    wsB.close();
  });

  // ─── VOICE_LEAVE ───

  it('VOICE_LEAVE removes participant from voiceMembers and broadcasts VOICE_STATE left', async () => {
    const alice = await createAndJoin('Alice');
    const wsA = await connectWs();
    await doHello(wsA, alice.sessionId, alice.participantId, alice.token);

    // Join then leave voice
    send(wsA, 'VOICE_JOIN', {});
    await receiveJson(wsA); // VOICE_STATE joined

    send(wsA, 'VOICE_LEAVE', {});
    const leftState = (await receiveJson(wsA)) as {
      type: string;
      payload: { participantId: string; state: string };
    };
    expect(leftState.type).toBe('VOICE_STATE');
    expect(leftState.payload.state).toBe('left');

    // Verify: trying to signal after leave should fail
    send(wsA, 'VOICE_SIGNAL', {
      toParticipantId: 'nobody',
      signalType: 'offer',
      data: { sdp: 'test' },
    });
    const err = (await receiveJson(wsA)) as {
      type: string;
      payload: { code: string; message: string };
    };
    expect(err.type).toBe('ERROR');
    expect(err.payload.code).toBe('BAD_MESSAGE');
    expect(err.payload.message).toContain('VOICE_JOIN');

    wsA.close();
  });

  // ─── VOICE_SIGNAL rejected if sender not in voiceMembers ───

  it('VOICE_SIGNAL rejected if sender not in voiceMembers', async () => {
    const alice = await createAndJoin('Alice');
    const wsA = await connectWs();
    await doHello(wsA, alice.sessionId, alice.participantId, alice.token);

    send(wsA, 'VOICE_SIGNAL', {
      toParticipantId: 'some-id',
      signalType: 'offer',
      data: { sdp: 'test' },
    });

    const err = (await receiveJson(wsA)) as {
      type: string;
      payload: { code: string; message: string };
    };
    expect(err.type).toBe('ERROR');
    expect(err.payload.code).toBe('BAD_MESSAGE');
    expect(err.payload.message).toContain('VOICE_JOIN');

    wsA.close();
  });

  // ─── VOICE_SIGNAL rejected if recipient not in session ───

  it('VOICE_SIGNAL rejected if recipient not in same session', async () => {
    const alice = await createAndJoin('Alice');
    const wsA = await connectWs();
    await doHello(wsA, alice.sessionId, alice.participantId, alice.token);

    send(wsA, 'VOICE_JOIN', {});
    await receiveJson(wsA); // VOICE_STATE joined

    send(wsA, 'VOICE_SIGNAL', {
      toParticipantId: 'nonexistent-participant',
      signalType: 'offer',
      data: { sdp: 'test' },
    });

    const err = (await receiveJson(wsA)) as {
      type: string;
      payload: { code: string; message: string };
    };
    expect(err.type).toBe('ERROR');
    expect(err.payload.code).toBe('BAD_MESSAGE');
    expect(err.payload.message).toContain('not found');

    wsA.close();
  });

  // ─── VOICE_SIGNAL rejected if recipient not in voiceMembers ───

  it('VOICE_SIGNAL rejected if recipient not in voiceMembers', async () => {
    const alice = await createAndJoin('Alice');
    const bob = await joinWithCode(alice.joinCode, 'Bob');

    const wsA = await connectWs();
    const wsB = await connectWs();
    await doHello(wsA, alice.sessionId, alice.participantId, alice.token);
    const _bobJoinMsg = collectMessages(wsA, 1);
    await doHello(wsB, alice.sessionId, bob.participantId, bob.token);
    await _bobJoinMsg;

    // Alice joins voice, but Bob does NOT join voice
    send(wsA, 'VOICE_JOIN', {});
    await receiveJson(wsA); // VOICE_STATE joined (on wsA)
    await receiveJson(wsB); // VOICE_STATE joined (on wsB)

    // Alice tries to send a signal to Bob (who is not in voice)
    send(wsA, 'VOICE_SIGNAL', {
      toParticipantId: bob.participantId,
      signalType: 'offer',
      data: { sdp: 'test' },
    });

    const err = (await receiveJson(wsA)) as {
      type: string;
      payload: { code: string; message: string };
    };
    expect(err.type).toBe('ERROR');
    expect(err.payload.code).toBe('BAD_MESSAGE');
    expect(err.payload.message).toContain('not in voice');

    wsA.close();
    wsB.close();
  });

  // ─── VOICE_SIGNAL forwarded to intended recipient with fromParticipantId ───

  it('VOICE_SIGNAL forwarded only to intended recipient with fromParticipantId', async () => {
    const alice = await createAndJoin('Alice');
    const bob = await joinWithCode(alice.joinCode, 'Bob');
    const charlie = await joinWithCode(alice.joinCode, 'Charlie');

    const wsA = await connectWs();
    const wsB = await connectWs();
    const wsC = await connectWs();
    await doHello(wsA, alice.sessionId, alice.participantId, alice.token);
    await collectMessages(wsA, 1); // Bob PARTICIPANT_JOINED
    await doHello(wsB, alice.sessionId, bob.participantId, bob.token);
    await collectMessages(wsA, 1); // Charlie PARTICIPANT_JOINED
    await collectMessages(wsB, 1); // Charlie PARTICIPANT_JOINED
    await doHello(wsC, alice.sessionId, charlie.participantId, charlie.token);

    // All three join voice
    send(wsA, 'VOICE_JOIN', {});
    // Drain VOICE_STATE from all sockets
    await collectMessages(wsA, 1);
    await collectMessages(wsB, 1);
    await collectMessages(wsC, 1);

    send(wsB, 'VOICE_JOIN', {});
    await collectMessages(wsA, 1);
    await collectMessages(wsB, 1);
    await collectMessages(wsC, 1);

    send(wsC, 'VOICE_JOIN', {});
    await collectMessages(wsA, 1);
    await collectMessages(wsB, 1);
    await collectMessages(wsC, 1);

    // Alice sends signal to Bob only
    const charlieWatch = collectMessages(wsC, 1, 500); // short timeout — Charlie should NOT receive
    send(wsA, 'VOICE_SIGNAL', {
      toParticipantId: bob.participantId,
      signalType: 'offer',
      data: { sdp: 'v=0\r\n...' },
    });

    const bobSignal = (await receiveJson(wsB)) as {
      type: string;
      payload: { fromParticipantId: string; signalType: string; data: unknown };
    };
    expect(bobSignal.type).toBe('VOICE_SIGNAL');
    expect(bobSignal.payload.fromParticipantId).toBe(alice.participantId);
    expect(bobSignal.payload.signalType).toBe('offer');
    expect(bobSignal.payload.data).toEqual({ sdp: 'v=0\r\n...' });

    // Charlie should NOT have received the signal
    const charlieMsgs = await charlieWatch;
    const voiceSignals = (charlieMsgs as Array<{ type: string }>).filter(
      (m) => m.type === 'VOICE_SIGNAL',
    );
    expect(voiceSignals.length).toBe(0);

    wsA.close();
    wsB.close();
    wsC.close();
  });

  // ─── BAD payloads return ERROR BAD_MESSAGE ───

  it('rejects invalid VOICE_SIGNAL payload (missing toParticipantId)', async () => {
    const ws = await connectWs();
    ws.send(
      JSON.stringify({
        type: 'VOICE_SIGNAL',
        payload: { signalType: 'offer', data: {} },
      }),
    );

    const err = (await receiveJson(ws)) as {
      type: string;
      payload: { code: string };
    };
    expect(err.type).toBe('ERROR');
    expect(err.payload.code).toBe('BAD_MESSAGE');

    ws.close();
  });

  it('rejects invalid VOICE_SIGNAL payload (bad signalType)', async () => {
    const ws = await connectWs();
    ws.send(
      JSON.stringify({
        type: 'VOICE_SIGNAL',
        payload: { toParticipantId: 'x', signalType: 'invalid', data: {} },
      }),
    );

    const err = (await receiveJson(ws)) as {
      type: string;
      payload: { code: string };
    };
    expect(err.type).toBe('ERROR');
    expect(err.payload.code).toBe('BAD_MESSAGE');

    ws.close();
  });

  // ─── SDP payload size limit ───

  it('rejects SDP offer exceeding 40KB', async () => {
    const alice = await createAndJoin('Alice');
    const bob = await joinWithCode(alice.joinCode, 'Bob');

    const wsA = await connectWs();
    const wsB = await connectWs();
    await doHello(wsA, alice.sessionId, alice.participantId, alice.token);
    const _bobJoinMsg = collectMessages(wsA, 1);
    await doHello(wsB, alice.sessionId, bob.participantId, bob.token);
    await _bobJoinMsg;

    // Both join voice
    send(wsA, 'VOICE_JOIN', {});
    send(wsB, 'VOICE_JOIN', {});
    await collectMessages(wsA, 2); // 2 VOICE_STATE messages
    await collectMessages(wsB, 2);

    // Send oversized SDP
    const bigSdp = 'x'.repeat(50_000); // > 40KB
    send(wsA, 'VOICE_SIGNAL', {
      toParticipantId: bob.participantId,
      signalType: 'offer',
      data: { sdp: bigSdp },
    });

    const err = (await receiveJson(wsA)) as {
      type: string;
      payload: { code: string; message: string };
    };
    expect(err.type).toBe('ERROR');
    expect(err.payload.code).toBe('BAD_MESSAGE');
    expect(err.payload.message).toContain('40KB');

    wsA.close();
    wsB.close();
  });

  // ─── ICE payload size limit ───

  it('rejects ICE candidate exceeding 8KB', async () => {
    const alice = await createAndJoin('Alice');
    const bob = await joinWithCode(alice.joinCode, 'Bob');

    const wsA = await connectWs();
    const wsB = await connectWs();
    await doHello(wsA, alice.sessionId, alice.participantId, alice.token);
    const _bobJoinMsg = collectMessages(wsA, 1);
    await doHello(wsB, alice.sessionId, bob.participantId, bob.token);
    await _bobJoinMsg;

    send(wsA, 'VOICE_JOIN', {});
    send(wsB, 'VOICE_JOIN', {});
    await collectMessages(wsA, 2);
    await collectMessages(wsB, 2);

    const bigIce = 'y'.repeat(10_000); // > 8KB
    send(wsA, 'VOICE_SIGNAL', {
      toParticipantId: bob.participantId,
      signalType: 'ice',
      data: { candidate: bigIce },
    });

    const err = (await receiveJson(wsA)) as {
      type: string;
      payload: { code: string; message: string };
    };
    expect(err.type).toBe('ERROR');
    expect(err.payload.code).toBe('BAD_MESSAGE');
    expect(err.payload.message).toContain('8KB');

    wsA.close();
    wsB.close();
  });

  // ─── No voice messages emitted as EVENT or stored in ring buffer ───

  it('voice messages are NOT emitted as EVENT or stored in replay ring buffer', async () => {
    const alice = await createAndJoin('Alice');
    const bob = await joinWithCode(alice.joinCode, 'Bob');

    const wsA = await connectWs();
    const wsB = await connectWs();
    await doHello(wsA, alice.sessionId, alice.participantId, alice.token);
    const _bobJoinMsg = collectMessages(wsA, 1);
    await doHello(wsB, alice.sessionId, bob.participantId, bob.token);
    await _bobJoinMsg;

    // Both join voice and do some signaling
    send(wsA, 'VOICE_JOIN', {});
    send(wsB, 'VOICE_JOIN', {});
    await collectMessages(wsA, 2); // 2 VOICE_STATE
    await collectMessages(wsB, 2);

    send(wsA, 'VOICE_SIGNAL', {
      toParticipantId: bob.participantId,
      signalType: 'offer',
      data: { sdp: 'test' },
    });
    await receiveJson(wsB); // Bob receives the forwarded signal

    // Now reconnect Bob — he should only get WELCOME + SNAPSHOT + EVENTS
    // and NO VOICE_* messages in the replay
    wsB.close();
    await new Promise((r) => setTimeout(r, 100));

    const wsB2 = await connectWs();
    wsB2.send(
      JSON.stringify({
        type: 'HELLO',
        payload: {
          sessionId: alice.sessionId,
          participantId: bob.participantId,
          token: bob.token,
          lastEventId: 0, // replay from beginning
        },
      }),
    );

    // Collect all messages sent during reconnect
    const reconnectMsgs = await collectMessages(wsB2, 5, 1000);

    // None of them should be VOICE_STATE or VOICE_SIGNAL
    for (const msg of reconnectMsgs) {
      const m = msg as { type: string; payload?: { kind?: string } };
      expect(m.type).not.toBe('VOICE_STATE');
      expect(m.type).not.toBe('VOICE_SIGNAL');
      // Also check that no EVENT has a voice-related kind
      if (m.type === 'EVENT' && m.payload?.kind) {
        expect(m.payload.kind).not.toContain('VOICE');
      }
    }

    wsA.close();
    wsB2.close();
  });

  // ─── Voice cleanup on disconnect ───

  it('voice membership is cleaned up on WebSocket disconnect', async () => {
    const alice = await createAndJoin('Alice');
    const bob = await joinWithCode(alice.joinCode, 'Bob');

    const wsA = await connectWs();
    const wsB = await connectWs();
    await doHello(wsA, alice.sessionId, alice.participantId, alice.token);
    const _bobJoinMsg = collectMessages(wsA, 1);
    await doHello(wsB, alice.sessionId, bob.participantId, bob.token);
    await _bobJoinMsg;

    // Bob joins voice
    send(wsB, 'VOICE_JOIN', {});
    await receiveJson(wsA); // VOICE_STATE joined on Alice
    await receiveJson(wsB); // VOICE_STATE joined on Bob

    // Now simulate Bob disconnecting
    const aliceReceives = collectMessages(wsA, 2, 2000); // VOICE_STATE left + PARTICIPANT_LEFT EVENT
    wsB.close();

    const msgs = await aliceReceives;
    const voiceLeft = msgs.find(
      (m) => (m as { type: string }).type === 'VOICE_STATE',
    ) as { type: string; payload: { participantId: string; state: string } } | undefined;

    expect(voiceLeft).toBeDefined();
    expect(voiceLeft!.payload.participantId).toBe(bob.participantId);
    expect(voiceLeft!.payload.state).toBe('left');

    wsA.close();
  });

  // ─── Voice cleanup on LEAVE_SESSION ───

  it('voice membership is cleaned up on LEAVE_SESSION', async () => {
    const alice = await createAndJoin('Alice');
    const bob = await joinWithCode(alice.joinCode, 'Bob');

    const wsA = await connectWs();
    const wsB = await connectWs();
    await doHello(wsA, alice.sessionId, alice.participantId, alice.token);
    const _bobJoinMsg = collectMessages(wsA, 1);
    await doHello(wsB, alice.sessionId, bob.participantId, bob.token);
    await _bobJoinMsg;

    // Bob joins voice
    send(wsB, 'VOICE_JOIN', {});
    await receiveJson(wsA); // VOICE_STATE joined
    await receiveJson(wsB); // VOICE_STATE joined

    // Bob leaves session explicitly
    const aliceReceives = collectMessages(wsA, 2, 2000); // VOICE_STATE left + PARTICIPANT_LEFT EVENT
    send(wsB, 'LEAVE_SESSION', {});

    const msgs = await aliceReceives;
    const voiceLeft = msgs.find(
      (m) => (m as { type: string }).type === 'VOICE_STATE',
    ) as { type: string; payload: { participantId: string; state: string } } | undefined;

    expect(voiceLeft).toBeDefined();
    expect(voiceLeft!.payload.participantId).toBe(bob.participantId);
    expect(voiceLeft!.payload.state).toBe('left');

    wsA.close();
  });

  // ─── VOICE_JOIN before HELLO ───

  it('rejects VOICE_JOIN before HELLO', async () => {
    const ws = await connectWs();
    send(ws, 'VOICE_JOIN', {});

    const err = (await receiveJson(ws)) as {
      type: string;
      payload: { code: string };
    };
    expect(err.type).toBe('ERROR');
    expect(err.payload.code).toBe('UNAUTHORIZED');

    ws.close();
  });
});
