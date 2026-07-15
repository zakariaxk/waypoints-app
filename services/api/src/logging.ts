// WP-104 — structured logging + request/connection correlation.
//
// A single Pino configuration underpins both HTTP (Fastify binds `reqId` per
// request) and WebSocket (each connection gets a child logger bound with
// `connId`). Given a connId or reqId from a bug report, grepping the logs
// reconstructs that connection/request's full message timeline.
//
// Privacy invariant (this is a location app): coordinates, chat message bodies,
// and emails must never appear in logs at info level or above. Two defenses:
//   1. Discipline — WS message logs carry only routing metadata (type, ids),
//      never the payload. See `wsMessageLogFields`.
//   2. Backstop — Pino `redact` censors known-sensitive field names in case a
//      payload is ever passed to a logger by mistake.

import pino, { type Logger, type LoggerOptions } from 'pino';
import type { ClientMessage, ErrorCode } from '@waypoints/shared';
import { config } from './config.js';

/** Field names that must never be logged in the clear. */
export const REDACT_PATHS = [
  // Coordinates / GPS payload fields, at any nesting depth.
  'lat',
  'lng',
  'accuracy',
  'heading',
  'speed',
  '*.lat',
  '*.lng',
  '*.accuracy',
  '*.heading',
  '*.speed',
  'payload.lat',
  'payload.lng',
  // Free-text that may contain PII.
  'text',
  'label',
  'email',
  '*.text',
  '*.label',
  '*.email',
  'payload.text',
  'payload.label',
];

/** Build Pino options from validated config: JSON in prod, pretty in dev. */
export function buildLoggerOptions(): LoggerOptions {
  return {
    level: config.logLevel,
    redact: { paths: REDACT_PATHS, censor: '[redacted]' },
    serializers: {
      err: pino.stdSerializers.err,
    },
    // Pretty logs in dev; JSON in prod. Skip the pretty-transport worker under
    // test (NODE_ENV=test) so it doesn't spawn a thread or spam test output.
    ...(config.isProduction || config.nodeEnv === 'test'
      ? {}
      : {
          transport: {
            target: 'pino-pretty',
            options: { colorize: true, translateTime: 'SYS:HH:MM:ss', ignore: 'pid,hostname' },
          },
        }),
  };
}

/** The root logger. Fastify and the WS server both derive children from it. */
export const logger: Logger = pino(buildLoggerOptions());

/**
 * The only fields logged for an inbound WS message: routing metadata, never the
 * payload. This is the primary guarantee that coordinates and chat bodies stay
 * out of the logs.
 */
export function wsMessageLogFields(
  conn: { sessionId: string | null; participantId: string | null },
  message: ClientMessage,
): { type: string; sessionId: string | null; participantId: string | null } {
  return {
    type: message.type,
    sessionId: conn.sessionId,
    participantId: conn.participantId,
  };
}

/** Log an inbound WS message at debug, with routing metadata only. */
export function logInboundMessage(
  log: Logger,
  conn: { sessionId: string | null; participantId: string | null },
  message: ClientMessage,
): void {
  log.debug(wsMessageLogFields(conn, message), 'ws message');
}

/** Log an ERROR sent to a client at warn, with the code and reason. */
export function logClientError(
  log: Logger,
  conn: { sessionId: string | null; participantId: string | null },
  code: ErrorCode,
  reason: string,
): void {
  log.warn(
    { code, reason, sessionId: conn.sessionId, participantId: conn.participantId },
    'ws error sent to client',
  );
}
