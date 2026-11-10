import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    globals: true,
    environment: 'node',
    include: ['src/__tests__/**/*.test.ts'],
    testTimeout: 10_000,
    // The existing WebSocket suites share a singleton session store; isolate files to prevent cross-file races.
    pool: 'forks',
    fileParallelism: false,
  },
});
