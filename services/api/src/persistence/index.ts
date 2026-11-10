import { config } from '../config.js';
import { PersistenceQueue, SupabaseRestTransport } from './event-queue.js';

export const persistenceQueue = new PersistenceQueue(
  config.supabaseUrl && config.supabaseServiceRoleKey
    ? new SupabaseRestTransport(config.supabaseUrl, config.supabaseServiceRoleKey)
    : null,
  config.persistenceBatchSize,
  config.persistenceFlushMs,
);
