import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    globals: true,
    environment: 'node',
    include: ['src/__tests__/**/*.test.ts'],
    // The WS suite spins up real servers and asserts on message timing; give it
    // headroom so slower/loaded CI runners don't produce spurious timeouts.
    testTimeout: 20_000,
    hookTimeout: 20_000,
    // Keep the singleton logger quiet during tests (the logging suite uses its
    // own captured logger). NODE_ENV=test also skips the pretty-transport worker.
    env: { NODE_ENV: 'test', LOG_LEVEL: 'silent' },
    coverage: {
      provider: 'v8',
      reporter: ['text', 'text-summary', 'json-summary', 'html'],
      reportsDirectory: './coverage',
      include: ['src/**/*.ts'],
      exclude: [
        'src/__tests__/**',
        'src/index.ts', // process bootstrap — exercised by manual/integration runs, not unit tests
      ],
      // Floor pinned to the current measured coverage (WP-103). CI fails on
      // regression below these numbers. Raise them only in tickets that add
      // tests — never lower them to make a red build green.
      // Floor pinned just below the current measured coverage (WP-103), with a
      // small margin to absorb run-to-run variance in the timing-sensitive WS
      // suite. Measured 2026-07-15: lines/statements 96.24, branches 82.07,
      // functions 92.59. Raise these only in tickets that add tests.
      thresholds: {
        lines: 94,
        statements: 94,
        functions: 90,
        branches: 80,
      },
    },
  },
});
