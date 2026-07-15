// WP-105 — config validation at boot.

import { describe, it, expect } from 'vitest';
import { loadConfig, ConfigError, CONFIG_ENV_KEYS } from '../config.js';

describe('loadConfig', () => {
  it('applies defaults for an empty environment', () => {
    const c = loadConfig({});
    expect(c.port).toBe(3000);
    expect(c.host).toBe('0.0.0.0');
    expect(c.locUpdateMinIntervalMs).toBe(900);
    expect(c.eventBufferCapacity).toBe(1000);
    expect(c.maxParticipantsPerSession).toBe(50);
    expect(c.logLevel).toBe('info');
    expect(c.nodeEnv).toBe('development');
    expect(c.isProduction).toBe(false);
    // CORS unset → reflect request origin
    expect(c.corsOrigin).toBe(true);
  });

  it('coerces valid overrides', () => {
    const c = loadConfig({
      PORT: '8080',
      MAX_PARTICIPANTS: '12',
      LOG_LEVEL: 'debug',
      NODE_ENV: 'production',
    });
    expect(c.port).toBe(8080);
    expect(c.maxParticipantsPerSession).toBe(12);
    expect(c.logLevel).toBe('debug');
    expect(c.isProduction).toBe(true);
  });

  it('parses CORS_ORIGIN as single value or comma list', () => {
    expect(loadConfig({ CORS_ORIGIN: 'https://a.com' }).corsOrigin).toBe('https://a.com');
    expect(loadConfig({ CORS_ORIGIN: 'https://a.com, https://b.com' }).corsOrigin).toEqual([
      'https://a.com',
      'https://b.com',
    ]);
    expect(loadConfig({ CORS_ORIGIN: '' }).corsOrigin).toBe(true);
  });

  it('throws ConfigError naming a malformed variable', () => {
    let err: unknown;
    try {
      loadConfig({ PORT: 'not-a-number' });
    } catch (e) {
      err = e;
    }
    expect(err).toBeInstanceOf(ConfigError);
    expect((err as ConfigError).message).toContain('PORT');
  });

  it('reports EVERY problem at once, not just the first', () => {
    let err: unknown;
    try {
      loadConfig({ PORT: 'abc', MAX_PARTICIPANTS: 'xyz', LOG_LEVEL: 'loud' });
    } catch (e) {
      err = e;
    }
    expect(err).toBeInstanceOf(ConfigError);
    const msg = (err as ConfigError).message;
    expect(msg).toContain('PORT');
    expect(msg).toContain('MAX_PARTICIPANTS');
    expect(msg).toContain('LOG_LEVEL');
  });

  it('rejects out-of-range integers', () => {
    expect(() => loadConfig({ PORT: '0' })).toThrow(ConfigError);
    expect(() => loadConfig({ PORT: '70000' })).toThrow(ConfigError);
    expect(() => loadConfig({ MAX_PARTICIPANTS: '0' })).toThrow(ConfigError);
  });

  it('rejects a non-integer numeric value', () => {
    expect(() => loadConfig({ EVENT_BUFFER_CAPACITY: '10.5' })).toThrow(ConfigError);
  });

  it('exposes the full env-key list for the .env.example sync check', () => {
    expect(CONFIG_ENV_KEYS).toContain('PORT');
    expect(CONFIG_ENV_KEYS).toContain('CORS_ORIGIN');
    expect(CONFIG_ENV_KEYS).toContain('LOG_LEVEL');
    expect(CONFIG_ENV_KEYS.length).toBeGreaterThanOrEqual(13);
  });
});
