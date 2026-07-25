/**
 * Stream a single file out of a snapshot (`restic dump <snap> <path>`).
 *
 * Used for both inline preview and download. Streaming keeps memory flat for
 * large files and preserves exact bytes (no re-encoding). The sink is any
 * Writable: an HTTP response locally, or an S3 upload / presigned target in the
 * cloud adapter.
 */
import type { Writable } from 'node:stream';
import { streamRestic, assertSnapshotId, assertSnapshotPath } from './restic';
import type { ResticEnv } from './types';

export function dumpToStream(
  env: ResticEnv,
  snap: string,
  path: string,
  sink: Writable,
  maxBytes?: number,
): Promise<number> {
  assertSnapshotId(snap);
  assertSnapshotPath(path);
  return streamRestic(['dump', snap, path], env, sink, maxBytes);
}
