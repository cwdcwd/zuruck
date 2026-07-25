/**
 * Zuruck Recovery UI — LOCAL server adapter.
 *
 * A localhost-only HTTP server that wires the browser SPA to the provider-
 * agnostic core (app/core). Security model:
 *   - binds 127.0.0.1 only, on an ephemeral port;
 *   - mints a per-session random token that every request must present
 *     (query ?t= or x-zuruck-token header) → other local processes and cross-site
 *     requests can't drive it;
 *   - restic credentials live only in this process + the restic children it
 *     spawns; they are NEVER written into any response.
 * The only mutating route is POST /api/restore, which validates its target first.
 *
 * Run via app/zuruck-ui.mjs, which esbuild-bundles this (and injects the browser
 * bundle as __ZURUCK_WEB_BUNDLE__).
 */
import * as http from 'node:http';
import { timingSafeEqual, randomBytes } from 'node:crypto';
import { spawn } from 'node:child_process';
import { URL } from 'node:url';
import { parseEnvFile, DEFAULT_ENV_FILE } from '../core/env';
import { listSnapshots } from '../core/snapshots';
import { listDir } from '../core/tree';
import { findInSnapshot } from '../core/find';
import { dumpToStream } from '../core/dump';
import { restoreToDirectory } from '../core/restore';
import { validateRestoreTarget } from '../core/validate';
import { assertSnapshotId, assertSnapshotPath } from '../core/restic';
import { renderPage } from './page';
import type { ResticEnv } from '../core/types';

// Injected at bundle time by app/zuruck-ui.mjs (esbuild `define`).
declare const __ZURUCK_WEB_BUNDLE__: string;
const WEB_BUNDLE = typeof __ZURUCK_WEB_BUNDLE__ === 'string' ? __ZURUCK_WEB_BUNDLE__ : '';

interface Options {
  envFile: string;
  port: number;
  open: boolean;
  idleTimeoutMin: number;
}

function parseArgs(argv: string[]): Options {
  const o: Options = { envFile: DEFAULT_ENV_FILE, port: 0, open: true, idleTimeoutMin: 0 };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--env-file') o.envFile = argv[++i];
    else if (a === '--port') o.port = parseInt(argv[++i], 10) || 0;
    else if (a === '--no-open') o.open = false;
    else if (a === '--idle-timeout') o.idleTimeoutMin = parseInt(argv[++i], 10) || 0;
  }
  return o;
}

function tokenOk(token: string, provided: string | null): boolean {
  if (!provided) return false;
  const a = Buffer.from(token);
  const b = Buffer.from(provided);
  return a.length === b.length && timingSafeEqual(a, b);
}

function sendJson(res: http.ServerResponse, status: number, body: unknown): void {
  const s = JSON.stringify(body);
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'content-length': Buffer.byteLength(s) });
  res.end(s);
}

const CONTENT_TYPES: Record<string, string> = {
  txt: 'text/plain', md: 'text/plain', log: 'text/plain', json: 'application/json',
  js: 'text/plain', ts: 'text/plain', css: 'text/plain', html: 'text/plain', xml: 'text/plain',
  csv: 'text/plain', yml: 'text/plain', yaml: 'text/plain', sh: 'text/plain', conf: 'text/plain',
  png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', gif: 'image/gif', webp: 'image/webp',
  svg: 'image/svg+xml', bmp: 'image/bmp', ico: 'image/x-icon', pdf: 'application/pdf',
};
function guessType(path: string): string {
  const ext = path.slice(path.lastIndexOf('.') + 1).toLowerCase();
  return CONTENT_TYPES[ext] || 'application/octet-stream';
}

async function main(): Promise<void> {
  const opts = parseArgs(process.argv.slice(2));
  const env: ResticEnv = parseEnvFile(opts.envFile);
  const repo = env.RESTIC_REPOSITORY;
  const token = randomBytes(24).toString('hex');

  // Directories this session has restored into — the only paths /api/reveal will open.
  const restored = new Set<string>();
  let lastActivity = Date.now();
  let inFlight = 0; // never idle-shutdown while a request (e.g. a long restore) is running
  const touch = () => (lastActivity = Date.now());

  const server = http.createServer((req, res) => {
    inFlight++;
    touch();
    handle(req, res)
      .catch((err) => {
        if (!res.headersSent) sendJson(res, 500, { error: String(err?.message || err) });
        else res.end();
      })
      .finally(() => {
        inFlight--;
        touch();
      });
  });

  async function handle(req: http.IncomingMessage, res: http.ServerResponse): Promise<void> {
    const url = new URL(req.url || '/', 'http://127.0.0.1');
    const provided = url.searchParams.get('t') || (req.headers['x-zuruck-token'] as string) || null;
    if (!tokenOk(token, provided)) {
      sendJson(res, 403, { error: 'forbidden' });
      return;
    }

    const path = url.pathname;
    if (path === '/' && req.method === 'GET') {
      const html = renderPage({ token, repo, bundle: WEB_BUNDLE });
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
      res.end(html);
      return;
    }

    if (path === '/api/snapshots' && req.method === 'GET') {
      sendJson(res, 200, await listSnapshots(env));
      return;
    }

    if (path === '/api/ls' && req.method === 'GET') {
      const snap = url.searchParams.get('snap') || '';
      const dir = url.searchParams.get('path') || '';
      sendJson(res, 200, await listDir(env, snap, dir));
      return;
    }

    if (path === '/api/find' && req.method === 'GET') {
      const snap = url.searchParams.get('snap') || '';
      const q = url.searchParams.get('q') || '';
      sendJson(res, 200, await findInSnapshot(env, snap, q));
      return;
    }

    if (path === '/api/dump' && req.method === 'GET') {
      const snap = url.searchParams.get('snap') || '';
      const file = url.searchParams.get('path') || '';
      const download = url.searchParams.get('download') === '1';
      const max = parseInt(url.searchParams.get('max') || '0', 10);
      // Validate before sending headers so a bad request is a clean 400.
      try {
        assertSnapshotId(snap);
        assertSnapshotPath(file);
      } catch (e) {
        sendJson(res, 400, { error: (e as Error).message });
        return;
      }
      const headers: http.OutgoingHttpHeaders = { 'content-type': guessType(file) };
      if (download) {
        const name = file.slice(file.lastIndexOf('/') + 1) || 'file';
        headers['content-disposition'] = `attachment; filename="${name.replace(/"/g, '')}"`;
      }
      res.writeHead(200, headers);
      // Preview cap: stop after `max` bytes so previewing a huge file is cheap
      // (core kills restic once the cap is hit). `res` is itself the sink.
      await dumpToStream(env, snap, file, res, max > 0 ? max : undefined);
      res.end();
      return;
    }

    if (path === '/api/restore' && req.method === 'POST') {
      const body = await readBody(req);
      const reqData = JSON.parse(body) as { snap: string; includes: string[]; target: string };
      // Validate everything BEFORE streaming, so a rejected request (bad target,
      // bad snapshot/path) is a clean 400 instead of a half-sent 200.
      try {
        assertSnapshotId(reqData.snap);
        for (const inc of reqData.includes || []) assertSnapshotPath(inc);
        validateRestoreTarget(reqData.target);
      } catch (e) {
        sendJson(res, 400, { error: (e as Error).message });
        return;
      }
      res.writeHead(200, { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-cache' });
      const result = await restoreToDirectory(
        env,
        { snapshot: reqData.snap, includes: reqData.includes || [], target: reqData.target },
        (line) => res.write(line + '\n'),
      );
      if (result.code === 0 || result.code === 3) restored.add(result.target);
      res.write(`\n__DONE__ ${result.code} ${result.target}\n`);
      res.end();
      return;
    }

    if (path === '/api/reveal' && req.method === 'POST') {
      const body = await readBody(req);
      const { path: target } = JSON.parse(body) as { path: string };
      if (!restored.has(target)) {
        sendJson(res, 400, { error: 'can only reveal a directory restored this session' });
        return;
      }
      if (process.platform === 'darwin') spawn('open', [target], { stdio: 'ignore' }).unref();
      sendJson(res, 200, { ok: true });
      return;
    }

    sendJson(res, 404, { error: 'not found' });
  }

  await new Promise<void>((resolve) => server.listen(opts.port, '127.0.0.1', resolve));
  const addr = server.address();
  const boundPort = typeof addr === 'object' && addr ? addr.port : opts.port;
  const link = `http://127.0.0.1:${boundPort}/?t=${token}`;

  // eslint-disable-next-line no-console
  console.log(`\nZuruck Recovery UI\n  repo:  ${repo}\n  open:  ${link}\n\nPress Ctrl-C to stop.\n`);
  if (opts.open && process.platform === 'darwin') spawn('open', [link], { stdio: 'ignore' }).unref();

  if (opts.idleTimeoutMin > 0) {
    const ms = opts.idleTimeoutMin * 60_000;
    setInterval(() => {
      if (inFlight === 0 && Date.now() - lastActivity > ms) {
        // eslint-disable-next-line no-console
        console.log(`Idle for ${opts.idleTimeoutMin}m — shutting down.`);
        process.exit(0);
      }
    }, 15_000).unref();
  }
}

function readBody(req: http.IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', (c) => {
      data += c;
      if (data.length > 1_000_000) req.destroy(); // 1MB cap on control payloads
    });
    req.on('end', () => resolve(data));
    req.on('error', reject);
  });
}

main().catch((err) => {
  // eslint-disable-next-line no-console
  console.error(`Failed to start: ${err?.message || err}`);
  process.exit(1);
});
