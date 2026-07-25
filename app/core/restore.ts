/**
 * Restore selected paths from a snapshot into a fresh target directory.
 *
 * This is the ONLY operation in the core that writes anything. The target is
 * validated first (see validate.ts). Progress lines (restic writes them to
 * stderr) are delivered to `onLine` so an adapter can stream them to the user.
 *
 * `target` is today's only "sink" — a local directory restic writes to. The
 * cloud adapter will introduce alternate sinks (restore to /tmp then zip → S3 →
 * presigned URL); when it does, this function's shape (validated destination +
 * streamed progress) is the seam that generalizes.
 */
import { mkdirSync } from 'node:fs';
import { spawnResticLines, assertSnapshotId, assertSnapshotPath } from './restic';
import { validateRestoreTarget } from './validate';
import type { ResticEnv, RestoreRequest } from './types';

export interface RestoreResult {
  code: number;
  target: string;
}

export async function restoreToDirectory(
  env: ResticEnv,
  req: RestoreRequest,
  onLine: (line: string) => void,
): Promise<RestoreResult> {
  assertSnapshotId(req.snapshot);
  for (const inc of req.includes) assertSnapshotPath(inc);
  const target = validateRestoreTarget(req.target);

  const args = ['restore', req.snapshot, '--target', target];
  for (const inc of req.includes) args.push('--include', inc);

  mkdirSync(target, { recursive: true });
  onLine(`==> Restoring ${req.includes.length || 'all'} path(s) from ${req.snapshot} → ${target}`);
  const code = await spawnResticLines(args, env, onLine);
  return { code, target };
}
