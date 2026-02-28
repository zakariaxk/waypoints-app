import Fastify from 'fastify';
import { config } from './config.js';
import { registerRoutes } from './http/routes.js';
import { setupWebSocket } from './ws/handler.js';
import { sessionStore } from './state/session-store.js';

async function main() {
  const app = Fastify({ logger: true });

  // Register HTTP routes
  await registerRoutes(app);

  // Start listening
  await app.listen({ port: config.port, host: config.host });

  // Attach WebSocket server to the underlying Node HTTP server
  const server = app.server;
  setupWebSocket(server);

  // Periodic presence sweep (update stale/offline statuses)
  const presenceTimer = setInterval(() => {
    sessionStore.sweepPresence();
  }, 5000);

  // Periodic session cleanup
  const cleanupTimer = setInterval(() => {
    const removed = sessionStore.cleanup();
    if (removed > 0) {
      app.log.info({ removed }, 'Session cleanup sweep');
    }
  }, config.cleanupIntervalMs);

  // Graceful shutdown
  const shutdown = async () => {
    clearInterval(cleanupTimer);
    clearInterval(presenceTimer);
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
