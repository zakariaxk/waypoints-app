// Fail if the config Zod schema and .env.example drift apart.
//
// The schema in src/config.ts is the source of truth for which environment
// variables the backend reads. This script asserts a two-way match against
// .env.example so a newly-added var can never silently escape documentation
// (and a removed one can't linger). Wired into CI (WP-101 / WP-105).

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { CONFIG_ENV_KEYS } from '../src/config.js';

const here = dirname(fileURLToPath(import.meta.url));
const envExamplePath = resolve(here, '..', '.env.example');

/** Keys of the form `KEY=...` (ignoring comments/blank lines) in .env.example. */
function parseEnvExampleKeys(text: string): string[] {
  const keys: string[] = [];
  for (const line of text.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eq = trimmed.indexOf('=');
    if (eq === -1) continue;
    keys.push(trimmed.slice(0, eq).trim());
  }
  return keys;
}

const schemaKeys = new Set(CONFIG_ENV_KEYS);
const exampleKeys = new Set(parseEnvExampleKeys(readFileSync(envExamplePath, 'utf-8')));

const missingFromExample = [...schemaKeys].filter((k) => !exampleKeys.has(k)).sort();
const extraInExample = [...exampleKeys].filter((k) => !schemaKeys.has(k)).sort();

if (missingFromExample.length === 0 && extraInExample.length === 0) {
  // eslint-disable-next-line no-console
  console.log(`✓ .env.example is in sync with the config schema (${schemaKeys.size} keys).`);
  process.exit(0);
}

const report: string[] = ['✗ .env.example is out of sync with src/config.ts:'];
if (missingFromExample.length > 0) {
  report.push(`  In schema but missing from .env.example: ${missingFromExample.join(', ')}`);
}
if (extraInExample.length > 0) {
  report.push(`  In .env.example but not in schema:        ${extraInExample.join(', ')}`);
}
// eslint-disable-next-line no-console
console.error(report.join('\n'));
process.exit(1);
