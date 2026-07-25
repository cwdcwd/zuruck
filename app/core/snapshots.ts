/** List snapshots (`restic snapshots --json`). Newest last, as restic returns. */
import { runResticJson } from './restic';
import type { ResticEnv, Snapshot } from './types';

export function listSnapshots(env: ResticEnv): Promise<Snapshot[]> {
  return runResticJson<Snapshot[]>(['snapshots', '--json'], env);
}
