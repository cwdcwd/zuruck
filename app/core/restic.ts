/**
 * restic invocation helpers.
 *
 * Every call spawns restic with an ARGUMENT ARRAY (never a shell string), so
 * user-supplied snapshot ids / paths can't inject a command. Callers pass the
 * resolved `ResticEnv` explicitly, which is what keeps this provider-agnostic:
 * locally the env comes from /etc/restic/env, in Lambda it comes from SSM + the
 * task role — this module doesn't care which.
 */
import { spawn } from 'node:child_process';
import type { Writable } from 'node:stream';
import type { ResticEnv } from './types';

/** The restic binary to run. Override with $RESTIC_BIN (e.g. a Lambda layer path). */
export function resticBin(): string {
  return process.env.RESTIC_BIN || 'restic';
}

/**
 * Guard a value that will be passed as a restic positional argument. Even though
 * we never use a shell, a value beginning with '-' would be parsed by restic as
 * a flag; reject that (and empty values) so a snapshot id / path can't smuggle one.
 */
export function assertNotFlag(value: string, what: string): void {
  if (!value || value.startsWith('-')) {
    throw new Error(`Invalid ${what}: '${value}'`);
  }
}

/** A restic snapshot id must be hex, or the alias "latest". */
export function assertSnapshotId(id: string): void {
  if (id !== 'latest' && !/^[0-9a-f]{8,64}$/i.test(id)) {
    throw new Error(`Invalid snapshot id: '${id}'`);
  }
}

/** An in-snapshot path must be absolute (restic requires it) and not a flag. */
export function assertSnapshotPath(p: string): void {
  if (!p.startsWith('/')) throw new Error(`Path must be absolute: '${p}'`);
}

export interface RunResult {
  code: number;
  stdout: string;
  stderr: string;
}

/** Run restic to completion, buffering stdout/stderr. For small JSON outputs. */
export function runRestic(args: string[], env: ResticEnv): Promise<RunResult> {
  return new Promise((resolve, reject) => {
    const child = spawn(resticBin(), args, {
      env: { ...process.env, ...env },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (d) => (stdout += d));
    child.stderr.on('data', (d) => (stderr += d));
    child.on('error', reject);
    child.on('close', (code) => resolve({ code: code ?? -1, stdout, stderr }));
  });
}

/** Run restic and JSON.parse its stdout. Throws on a non-zero exit. */
export async function runResticJson<T>(args: string[], env: ResticEnv): Promise<T> {
  const r = await runRestic(args, env);
  if (r.code !== 0) throw new Error(`restic ${args[0]} failed (exit ${r.code}): ${r.stderr.trim()}`);
  return JSON.parse(r.stdout) as T;
}

/**
 * Run restic that emits newline-delimited JSON (e.g. `ls --json`, `find --json`)
 * and return the parsed objects. `restic ls --json` prints the snapshot header
 * object first; callers filter it out by shape.
 */
export async function runResticNdjson(args: string[], env: ResticEnv): Promise<unknown[]> {
  const r = await runRestic(args, env);
  if (r.code !== 0) throw new Error(`restic ${args[0]} failed (exit ${r.code}): ${r.stderr.trim()}`);
  const out: unknown[] = [];
  for (const line of r.stdout.split('\n')) {
    const t = line.trim();
    if (!t) continue;
    try {
      out.push(JSON.parse(t));
    } catch {
      // restic occasionally interleaves a non-JSON progress line; skip it.
    }
  }
  return out;
}

/**
 * Spawn restic and stream stdout to `sink` (used for `dump`). Resolves with the
 * exit code once the stream ends. When `maxBytes` is set (preview), we stop after
 * that many bytes and kill restic so we don't pull a whole large file from S3;
 * otherwise we pipe with backpressure so downloads stay memory-flat.
 */
export function streamRestic(
  args: string[],
  env: ResticEnv,
  sink: Writable,
  maxBytes?: number,
): Promise<number> {
  return new Promise((resolve, reject) => {
    const child = spawn(resticBin(), args, {
      env: { ...process.env, ...env },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    child.stderr.resume(); // drain so the pipe buffer can't deadlock
    child.on('error', reject);
    child.on('close', (code) => resolve(code ?? -1));

    if (maxBytes && maxBytes > 0) {
      let sent = 0;
      let done = false;
      child.stdout.on('data', (chunk: Buffer) => {
        if (done) return;
        const remaining = maxBytes - sent;
        if (chunk.length >= remaining) {
          sink.write(chunk.subarray(0, remaining));
          sent = maxBytes;
          done = true;
          child.kill('SIGTERM'); // enough for a preview; stop the S3 pull
        } else {
          sink.write(chunk);
          sent += chunk.length;
        }
      });
    } else {
      child.stdout.pipe(sink, { end: false });
    }
  });
}

/**
 * Spawn restic and deliver combined stdout+stderr line-by-line to `onLine`
 * (used for `restore`, whose progress goes to stderr). Resolves with the exit code.
 */
export function spawnResticLines(
  args: string[],
  env: ResticEnv,
  onLine: (line: string) => void,
): Promise<number> {
  return new Promise((resolve, reject) => {
    const child = spawn(resticBin(), args, {
      env: { ...process.env, ...env },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let buf = '';
    const pump = (chunk: Buffer) => {
      buf += chunk.toString();
      let nl: number;
      while ((nl = buf.indexOf('\n')) >= 0) {
        onLine(buf.slice(0, nl));
        buf = buf.slice(nl + 1);
      }
    };
    child.stdout.on('data', pump);
    child.stderr.on('data', pump);
    child.on('error', reject);
    child.on('close', (code) => {
      if (buf.trim()) onLine(buf);
      resolve(code ?? -1);
    });
  });
}
