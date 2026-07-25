/**
 * Lazy directory listing for the browse tree.
 *
 * `restic ls --json <snap> <dir>` WITHOUT --recursive lists only the immediate
 * children of <dir> (verified against restic 0.19), so expanding one folder is
 * cheap and touches only that folder's tree blob. `restic ls` prints the
 * snapshot header object first; we drop it and defensively re-filter to true
 * immediate children in case restic emits ancestor nodes.
 *
 * The snapshot's ROOT entries are its backed-up paths (`snapshot.paths`); the UI
 * renders those directly, so this only handles descending into a real directory.
 */
import { runResticNdjson, assertSnapshotId, assertSnapshotPath } from './restic';
import type { DirEntry, ResticEnv } from './types';

interface ResticNode {
  struct_type?: string;
  name?: string;
  type?: string;
  path?: string;
  size?: number;
  mtime?: string;
}

export async function listDir(env: ResticEnv, snap: string, dir: string): Promise<DirEntry[]> {
  assertSnapshotId(snap);
  assertSnapshotPath(dir);
  const parent = dir.replace(/\/+$/, ''); // normalize: no trailing slash
  const rows = (await runResticNdjson(['ls', '--json', snap, dir], env)) as ResticNode[];

  const entries: DirEntry[] = [];
  for (const n of rows) {
    if (n.struct_type === 'snapshot' || !n.path || !n.type) continue; // header line
    const p = n.path;
    const idx = p.lastIndexOf('/');
    const nodeParent = idx <= 0 ? '/' : p.slice(0, idx);
    if (nodeParent !== parent) continue; // keep only immediate children
    entries.push({
      name: n.name ?? p.slice(idx + 1),
      type: n.type,
      path: p,
      size: n.size,
      mtime: n.mtime,
    });
  }
  // Directories first, then alphabetical — the usual file-browser order.
  entries.sort((a, b) => {
    if ((a.type === 'dir') !== (b.type === 'dir')) return a.type === 'dir' ? -1 : 1;
    return a.name.localeCompare(b.name);
  });
  return entries;
}
