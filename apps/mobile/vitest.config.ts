import { defineConfig } from 'vitest/config';

// Only the framework-free modules are tested: the Zustand store's event
// application, and the pure geo/routing math. Component and map rendering are
// deliberately out of scope — high cost, low signal, and a map cannot be
// meaningfully asserted in CI.
export default defineConfig({
  test: {
    environment: 'node',
    include: ['src/**/*.test.ts'],
  },
});
