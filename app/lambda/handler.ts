/**
 * Zuruck Recovery UI — CLOUD adapter (SCAFFOLD, not yet deployed).
 *
 * A Lambda behind an IAM-authenticated Function URL that reuses the SAME
 * provider-agnostic core (app/core) as the local server. It proves the "core +
 * adapters" seam: the only differences from the local adapter are where restic
 * lives (a Lambda layer at /opt/bin/restic) and where credentials come from
 * (SSM + the Lambda role — no static AWS keys; restic's S3 backend picks up the
 * role via the container credential provider).
 *
 * Status of routes in this scaffold:
 *   - browse (snapshots / ls / find) and single-file dump  → implemented
 *   - restore  → 501. Cloud restore can't write "a local folder"; it must restore
 *     to /tmp then zip → S3 → presigned URL, bounded by Lambda 15min/10GB, with
 *     large restores handled by Fargate. That plugs into core/restore.ts's sink
 *     seam and is deliberately left as a follow-up.
 *
 * NOTE: auth is enforced by the Function URL (AWS_IAM); the browser must SigV4-sign
 * (Cognito Identity Pool or similar). Wiring that is the documented auth TODO — do
 * not switch the Function URL to NONE.
 */
import { Writable } from 'node:stream';
import { SSMClient, GetParameterCommand } from '@aws-sdk/client-ssm';
import { listSnapshots } from '../core/snapshots';
import { listDir } from '../core/tree';
import { findInSnapshot } from '../core/find';
import { dumpToStream } from '../core/dump';
import type { ResticEnv } from '../core/types';

interface FnUrlEvent {
  requestContext?: { http?: { method?: string; path?: string } };
  rawPath?: string;
  queryStringParameters?: Record<string, string | undefined>;
}
interface FnUrlResult {
  statusCode: number;
  headers?: Record<string, string>;
  body?: string;
  isBase64Encoded?: boolean;
}

// Base64 inflates ~4/3, and a Function URL response caps at 6 MB — keep the raw
// dump under ~4 MiB so the encoded body stays within that limit. Larger files
// need the presigned-URL path (see the restore/sink follow-up in the header).
const PREVIEW_CAP = 4 * 1024 * 1024;

let cachedEnv: ResticEnv | null = null;

async function resticEnv(): Promise<ResticEnv> {
  if (cachedEnv) return cachedEnv;
  const repo = requireEnv('RESTIC_REPOSITORY');
  const pwParam = requireEnv('RESTIC_PW_PARAM');
  const region = process.env.AWS_REGION || 'us-west-2';
  const ssm = new SSMClient({ region });
  const out = await ssm.send(new GetParameterCommand({ Name: pwParam, WithDecryption: true }));
  const password = out.Parameter?.Value;
  if (!password) throw new Error(`SSM parameter ${pwParam} has no value`);
  cachedEnv = {
    RESTIC_REPOSITORY: repo,
    RESTIC_PASSWORD: password,
    AWS_REGION: region,
    // Lambda-writable cache; restic's S3 backend uses the role via the default
    // AWS credential chain (AWS_CONTAINER_CREDENTIALS_*), so no static keys here.
    RESTIC_CACHE_DIR: '/tmp/restic-cache',
  };
  return cachedEnv;
}

function requireEnv(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing required env var: ${name}`);
  return v;
}

function json(statusCode: number, body: unknown): FnUrlResult {
  return { statusCode, headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) };
}

/** Collect a bounded amount of dump output into a Buffer (scaffold: base64 body). */
class BufferSink extends Writable {
  chunks: Buffer[] = [];
  _write(chunk: Buffer, _enc: string, cb: (e?: Error) => void): void {
    this.chunks.push(chunk);
    cb();
  }
  get buffer(): Buffer {
    return Buffer.concat(this.chunks);
  }
}

export async function handler(event: FnUrlEvent): Promise<FnUrlResult> {
  const path = event.requestContext?.http?.path || event.rawPath || '/';
  const method = event.requestContext?.http?.method || 'GET';
  const q = event.queryStringParameters || {};
  try {
    const env = await resticEnv();

    if (path.endsWith('/api/snapshots')) return json(200, await listSnapshots(env));
    if (path.endsWith('/api/ls')) return json(200, await listDir(env, q.snap || '', q.path || ''));
    if (path.endsWith('/api/find')) return json(200, await findInSnapshot(env, q.snap || '', q.q || ''));

    if (path.endsWith('/api/dump')) {
      const sink = new BufferSink();
      await dumpToStream(env, q.snap || '', q.path || '', sink, PREVIEW_CAP);
      return {
        statusCode: 200,
        headers: { 'content-type': 'application/octet-stream' },
        body: sink.buffer.toString('base64'),
        isBase64Encoded: true,
      };
    }

    if (path.endsWith('/api/restore') && method === 'POST') {
      return json(501, {
        error:
          'Cloud restore is not implemented in this scaffold. Restore to /tmp then ' +
          'zip → S3 → presigned URL (Fargate for large restores). See core/restore.ts sink seam.',
      });
    }

    return json(404, { error: 'not found' });
  } catch (err) {
    return json(500, { error: (err as Error).message });
  }
}
