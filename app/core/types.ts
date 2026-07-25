/**
 * Shared types for the Zuruck recovery core.
 *
 * This module is provider-agnostic: it has NO knowledge of HTTP or Lambda.
 * The local server ([app/server]) and the future cloud adapter ([app/lambda])
 * both build on the same core, so keep node/http specifics out of here.
 */

/** The restic/AWS environment restic children run with (repo, creds, password). */
export type ResticEnv = Record<string, string>;

/** A restic snapshot as emitted by `restic snapshots --json`. */
export interface Snapshot {
  id: string;
  short_id: string;
  time: string;
  hostname: string;
  username?: string;
  paths: string[];
  tags?: string[];
  summary?: {
    total_bytes_processed?: number;
    total_files_processed?: number;
    data_added?: number;
  };
}

/** One entry inside a snapshot directory (`restic ls --json`). */
export interface DirEntry {
  name: string;
  /** "dir" | "file" | "symlink" | … */
  type: string;
  /** Absolute path within the snapshot. */
  path: string;
  size?: number;
  mtime?: string;
}

/** A restore request: pull `includes` out of `snapshot` into `target`. */
export interface RestoreRequest {
  snapshot: string;
  includes: string[];
  target: string;
}

/** Parsed S3 repository URL (`s3:s3.<region>.amazonaws.com/<bucket>/<prefix>`). */
export interface RepoUrl {
  host: string;
  bucket: string;
  prefix: string;
  region: string;
}
