/**
 * Filename search within a snapshot (`restic find --json --snapshot <id> <pat>`).
 *
 * restic emits a JSON array; each element carries a `matches` array of nodes for
 * one snapshot. We flatten to the matching paths so the UI can jump to a file.
 */
import { runResticJson, assertSnapshotId, assertNotFlag } from './restic';
import type { DirEntry, ResticEnv } from './types';

interface FindMatch {
  path?: string;
  type?: string;
  size?: number;
  mtime?: string;
}
interface FindGroup {
  matches?: FindMatch[];
}

export async function findInSnapshot(
  env: ResticEnv,
  snap: string,
  pattern: string,
): Promise<DirEntry[]> {
  assertSnapshotId(snap);
  assertNotFlag(pattern, 'search pattern');
  // `restic find` matches its pattern as a glob against the whole filename, so a
  // bare "gitconfig" won't find ".gitconfig". Wrap plain queries as *query* for
  // the substring search a search box implies; leave explicit globs untouched.
  const glob = /[*?[\]]/.test(pattern) ? pattern : `*${pattern}*`;
  const groups = await runResticJson<FindGroup[]>(
    ['find', '--json', '--snapshot', snap, glob],
    env,
  );
  const out: DirEntry[] = [];
  for (const g of groups) {
    for (const m of g.matches ?? []) {
      if (!m.path) continue;
      out.push({
        name: m.path.slice(m.path.lastIndexOf('/') + 1),
        type: m.type ?? 'file',
        path: m.path,
        size: m.size,
        mtime: m.mtime,
      });
    }
  }
  return out;
}
