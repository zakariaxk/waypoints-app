import { createHmac, createPublicKey, verify as verifySignature, type KeyObject } from 'node:crypto';

export interface AuthIdentity {
  userId: string;
  email: string | null;
}

interface JwtHeader { alg: string; kid?: string }
interface JwtClaims { sub?: string; exp?: number; nbf?: number; iss?: string; aud?: string | string[]; email?: string }
interface Jwk { kid?: string; kty: string; alg?: string; use?: string; [key: string]: unknown }

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const JWKS_TTL_MS = 10 * 60_000;

function fromBase64Url(value: string): Buffer {
  return Buffer.from(value.replace(/-/g, '+').replace(/_/g, '/'), 'base64');
}

function parseJson<T>(value: string): T | null {
  try { return JSON.parse(value) as T; } catch { return null; }
}

/** Verifies Supabase access-token signatures against the project JWKS (or an explicit legacy secret). */
export class SupabaseJwtVerifier {
  private jwks: Jwk[] = [];
  private jwksExpiresAt = 0;

  constructor(
    private readonly supabaseUrl: string | undefined,
    private readonly legacyJwtSecret: string | undefined,
    private readonly fetchImpl: typeof fetch = fetch,
  ) {}

  get enabled(): boolean { return Boolean(this.supabaseUrl); }

  async verify(accessToken: string): Promise<AuthIdentity | null> {
    if (!this.supabaseUrl) return null;
    const parts = accessToken.split('.');
    if (parts.length !== 3) return null;
    const header = parseJson<JwtHeader>(fromBase64Url(parts[0]).toString('utf8'));
    const claims = parseJson<JwtClaims>(fromBase64Url(parts[1]).toString('utf8'));
    if (!header || !claims || !this.validClaims(claims)) return null;
    const input = Buffer.from(`${parts[0]}.${parts[1]}`);
    const signature = fromBase64Url(parts[2]);
    const valid = await this.verifySignature(header, input, signature);
    return valid ? { userId: claims.sub!, email: claims.email ?? null } : null;
  }

  private validClaims(claims: JwtClaims): boolean {
    const now = Math.floor(Date.now() / 1000);
    const issuer = this.supabaseUrl!.replace(/\/$/, '') + '/auth/v1';
    const audiences = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
    return UUID.test(claims.sub ?? '') && typeof claims.exp === 'number' && claims.exp > now
      && (claims.nbf === undefined || claims.nbf <= now)
      && claims.iss === issuer && audiences.includes('authenticated');
  }

  private async verifySignature(header: JwtHeader, input: Buffer, signature: Buffer): Promise<boolean> {
    if (header.alg === 'HS256' && this.legacyJwtSecret) {
      const expected = createHmac('sha256', this.legacyJwtSecret).update(input).digest();
      return expected.length === signature.length && expected.equals(signature);
    }
    if (!['RS256', 'ES256', 'EdDSA'].includes(header.alg)) return false;
    const key = await this.getKey(header.kid, header.alg);
    if (!key) return false;
    if (header.alg === 'EdDSA') return verifySignature(null, input, key, signature);
    return verifySignature(header.alg === 'RS256' ? 'RSA-SHA256' : 'sha256', input, { key, dsaEncoding: 'ieee-p1363' }, signature);
  }

  private async getKey(kid: string | undefined, algorithm: string): Promise<KeyObject | null> {
    if (Date.now() >= this.jwksExpiresAt) await this.refreshJwks();
    const jwk = this.jwks.find((candidate) => candidate.kid === kid && candidate.alg === algorithm);
    if (!jwk) return null;
    try { return createPublicKey({ key: jwk, format: 'jwk' }); } catch { return null; }
  }

  private async refreshJwks(): Promise<void> {
    try {
      const response = await this.fetchImpl(`${this.supabaseUrl!.replace(/\/$/, '')}/auth/v1/.well-known/jwks.json`);
      const body = (await response.json()) as { keys?: Jwk[] };
      if (!response.ok || !Array.isArray(body.keys)) return;
      this.jwks = body.keys.filter((key) => key.use === undefined || key.use === 'sig');
      this.jwksExpiresAt = Date.now() + JWKS_TTL_MS;
    } catch {
      // Authentication fails closed when keys cannot be fetched.
    }
  }
}

export function bearerToken(header: string | undefined): string | null {
  const match = header?.match(/^Bearer\s+(.+)$/i);
  return match?.[1] ?? null;
}
