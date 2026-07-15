// WP-104 — structured logging + privacy guarantees.

import { describe, it, expect } from 'vitest';
import pino from 'pino';
import type { ClientMessage } from '@waypoints/shared';
import {
  buildLoggerOptions,
  wsMessageLogFields,
  logInboundMessage,
  logClientError,
  REDACT_PATHS,
} from '../logging.js';

/** A Pino logger writing NDJSON lines into an in-memory array. */
function captureLogger(): { log: pino.Logger; lines: () => Record<string, unknown>[] } {
  const chunks: string[] = [];
  const stream = {
    write(s: string) {
      chunks.push(s);
    },
  };
  const log = pino({ level: 'debug', redact: { paths: REDACT_PATHS, censor: '[redacted]' } }, stream);
  return {
    log,
    lines: () => chunks.join('').trim().split('\n').filter(Boolean).map((l) => JSON.parse(l)),
  };
}

const conn = { sessionId: 'sess-1', participantId: 'part-1' };

describe('wsMessageLogFields', () => {
  it('returns only routing metadata, never the payload', () => {
    const msg: ClientMessage = {
      type: 'LOC_UPDATE',
      payload: { lat: 40.7128, lng: -74.006, accuracy: 12, ts: 1_710_000_000_000 },
    } as ClientMessage;
    const fields = wsMessageLogFields(conn, msg);
    expect(fields).toEqual({ type: 'LOC_UPDATE', sessionId: 'sess-1', participantId: 'part-1' });
    // The coordinate values must not be present anywhere in the returned object.
    const serialized = JSON.stringify(fields);
    expect(serialized).not.toContain('40.7128');
    expect(serialized).not.toContain('-74.006');
  });
});

describe('logInboundMessage — no PII at info+', () => {
  it('does not log coordinates for LOC_UPDATE', () => {
    const { log, lines } = captureLogger();
    const msg: ClientMessage = {
      type: 'LOC_UPDATE',
      payload: { lat: 40.7128, lng: -74.006, accuracy: 12, ts: 1_710_000_000_000 },
    } as ClientMessage;
    logInboundMessage(log, conn, msg);
    const out = JSON.stringify(lines());
    expect(out).toContain('LOC_UPDATE');
    expect(out).not.toContain('40.7128');
    expect(out).not.toContain('-74.006');
  });

  it('does not log chat message bodies', () => {
    const { log, lines } = captureLogger();
    const msg: ClientMessage = {
      type: 'CHAT_MESSAGE',
      payload: { text: 'meet me at 123 Main St, secret@example.com' },
    } as ClientMessage;
    logInboundMessage(log, conn, msg);
    const out = JSON.stringify(lines());
    expect(out).toContain('CHAT_MESSAGE');
    expect(out).not.toContain('123 Main St');
    expect(out).not.toContain('secret@example.com');
  });

  it('logs at debug level', () => {
    const { log, lines } = captureLogger();
    logInboundMessage(log, conn, { type: 'CLEAR_DESTINATION' } as ClientMessage);
    const entry = lines()[0];
    expect(entry.level).toBe(20); // pino: debug
    expect(entry.type).toBe('CLEAR_DESTINATION');
  });
});

describe('logClientError', () => {
  it('logs the code and reason at warn', () => {
    const { log, lines } = captureLogger();
    logClientError(log, conn, 'UNAUTHORIZED', 'Invalid credentials');
    const entry = lines()[0];
    expect(entry.level).toBe(40); // pino: warn
    expect(entry.code).toBe('UNAUTHORIZED');
    expect(entry.reason).toBe('Invalid credentials');
  });
});

describe('redaction backstop', () => {
  it('censors sensitive fields even if a payload is logged by mistake', () => {
    const { log, lines } = captureLogger();
    // Simulate a careless caller passing the full payload.
    log.info({ payload: { lat: 40.7128, lng: -74.006, text: 'hello' } }, 'oops');
    const out = JSON.stringify(lines());
    expect(out).not.toContain('40.7128');
    expect(out).not.toContain('hello');
    expect(out).toContain('[redacted]');
  });
});

describe('buildLoggerOptions', () => {
  it('applies the configured level and redaction paths', () => {
    const opts = buildLoggerOptions();
    expect(opts.level).toBeDefined();
    expect(opts.redact).toMatchObject({ censor: '[redacted]' });
  });
});
