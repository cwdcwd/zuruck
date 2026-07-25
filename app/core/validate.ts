/**
 * Restore-target safety guards, ported from scripts/restore.sh:123-129.
 *
 * A restore writes to the local filesystem, so this is the one place the UI can
 * do damage. We refuse to splat a restore over $HOME, `/`, or any existing
 * non-empty directory — the same rules the CLI enforces.
 */
import { existsSync, readdirSync } from 'node:fs';
import { resolve } from 'node:path';
import { homedir } from 'node:os';

export function validateRestoreTarget(target: string, home = homedir()): string {
  if (!target || !target.trim()) {
    throw new Error('Restore target is required.');
  }
  const abs = resolve(target.replace(/^~(?=\/|$)/, home));
  if (abs === resolve(home) || abs === '/') {
    throw new Error(`Refusing to restore directly into '${abs}'. Choose a fresh target directory.`);
  }
  if (existsSync(abs) && readdirSync(abs).length > 0) {
    throw new Error(`Target '${abs}' exists and is not empty. Choose a fresh target directory.`);
  }
  return abs;
}
