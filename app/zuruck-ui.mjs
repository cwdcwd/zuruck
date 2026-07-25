#!/usr/bin/env node
/**
 * Zuruck Recovery UI launcher.
 *
 * ts-node is broken under Node 24 and Node's native .ts runner needs explicit
 * `.ts` import extensions (which would break `tsc`), so we build with esbuild —
 * already a devDependency — and run the result:
 *   1. bundle the browser SPA (app/web/app.ts) to an IIFE string;
 *   2. bundle the server (app/server/server.ts) to a self-contained CJS file,
 *      injecting the SPA string as __ZURUCK_WEB_BUNDLE__;
 *   3. import the server bundle, which starts listening and reads argv flags
 *      (--env-file, --port, --no-open, --idle-timeout).
 *
 * Usage: node app/zuruck-ui.mjs [--env-file PATH] [--port N] [--no-open] [--idle-timeout MIN]
 * (or `npm run ui -- --port 9000`)
 */
import esbuild from 'esbuild';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';
import { mkdirSync } from 'node:fs';

const here = dirname(fileURLToPath(import.meta.url));

const web = await esbuild.build({
  entryPoints: [join(here, 'web', 'app.ts')],
  bundle: true,
  format: 'iife',
  platform: 'browser',
  target: 'es2020',
  write: false,
  sourcemap: false,
  legalComments: 'none',
});
const webBundle = web.outputFiles[0].text;

const runDir = join(here, '.run');
mkdirSync(runDir, { recursive: true });
const outfile = join(runDir, 'server.cjs');

await esbuild.build({
  entryPoints: [join(here, 'server', 'server.ts')],
  bundle: true,
  platform: 'node',
  format: 'cjs',
  target: 'node20',
  outfile,
  sourcemap: 'inline',
  define: { __ZURUCK_WEB_BUNDLE__: JSON.stringify(webBundle) },
});

await import(pathToFileURL(outfile).href);
