import Fastify from 'fastify';
import cors from '@fastify/cors';
import { config } from './config.js';
import { buildLoggerOptions } from './logging.js';
import { registerRoutes, sweepJoinRateLimits } from './http/routes.js';
import { setupWebSocket, stopHeartbeat } from './ws/handler.js';
import { sessionStore } from './state/session-store.js';

async function main() {
  // Fastify builds its own Pino from these options and binds a `reqId` per
  // request. The WS server derives per-connection children bound with `connId`
  // from the standalone logger in logging.ts, built from the same options.
  const app = Fastify({ logger: buildLoggerOptions() });

  // CORS — allow all origins in dev, restrict in production
  await app.register(cors, {
    origin: config.corsOrigin,
    methods: ['GET', 'POST'],
  });

  // Register HTTP routes
  await registerRoutes(app);

  // Attach the WebSocket server to the underlying Node HTTP server BEFORE
  // listening. Attaching after listen() leaves a window in which the socket
  // accepts upgrades that no handler is registered for.
  setupWebSocket(app.server);

  // Start listening
  await app.listen({ port: config.port, host: config.host });

  // Periodic presence sweep (update stale/offline statuses)
  const presenceTimer = setInterval(() => {
    sessionStore.sweepPresence();
  }, 5000);

  // Periodic session cleanup
  const cleanupTimer = setInterval(() => {
    sweepJoinRateLimits();
    const removed = sessionStore.cleanup();
    if (removed > 0) {
      app.log.info({ removed }, 'Session cleanup sweep');
    }
  }, config.cleanupIntervalMs);

  // Graceful shutdown
  const shutdown = async () => {
    clearInterval(cleanupTimer);
    clearInterval(presenceTimer);
    stopHeartbeat();
    await app.close();
    process.exit(0);
  };

  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
