/**
 * Environment loading — the LOCAL adapter's source of restic credentials.
 *
 * Mirrors how scripts/backup.sh and scripts/restore.sh consume /etc/restic/env,
 * but parses the file safely (no `source`/eval): we read `KEY=VALUE` /
 * `export KEY=VALUE` lines directly. The cloud adapter does NOT use this — it
 * builds a ResticEnv from SSM + the Lambda role instead.
 */
import { readFileSync } from 'node:fs';
import type { RepoUrl, ResticEnv } from './types';

/** Default env file, matching the bash scripts. Override with $RESTIC_ENV_FILE. */
export const DEFAULT_ENV_FILE = process.env.RESTIC_ENV_FILE || '/etc/restic/env';

/**
 * Parse an /etc/restic/env-style file into a plain object. Handles optional
 * `export ` prefixes, `#` comments, blank lines, and single/double quotes.
 */
export function parseEnvFile(path: string): ResticEnv {
  const text = readFileSync(path, 'utf8');
  const env: ResticEnv = {};
  for (const raw of text.split('\n')) {
    let line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    if (line.startsWith('export ')) line = line.slice('export '.length).trim();
    const eq = line.indexOf('=');
    if (eq < 0) continue;
    const key = line.slice(0, eq).trim();
    let val = line.slice(eq + 1).trim();
    if (
      (val.startsWith('"') && val.endsWith('"')) ||
      (val.startsWith("'") && val.endsWith("'"))
    ) {
      val = val.slice(1, -1);
    }
    if (key) env[key] = val;
  }
  if (!env.RESTIC_REPOSITORY) {
    throw new Error(`RESTIC_REPOSITORY not set in ${path} — is this a Zuruck client?`);
  }
  return env;
}

/**
 * Parse an S3 repo URL into region/bucket/prefix, mirroring restore.sh:50-58.
 * Form: `s3:s3.<region>.amazonaws.com/<bucket>/<prefix...>`.
 */
export function parseRepoUrl(repo: string, fallbackRegion = 'us-east-1'): RepoUrl | null {
  if (!repo.startsWith('s3:')) return null;
  const body = repo.slice('s3:'.length);
  const host = body.split('/')[0];
  const rest = body.slice(host.length + 1);
  const bucket = rest.split('/')[0];
  const prefix = rest.slice(bucket.length + 1);
  let region = fallbackRegion;
  const m = host.match(/^s3[.-]([a-z0-9-]+)\.amazonaws\.com$/);
  if (m) region = m[1];
  return { host, bucket, prefix, region };
}
