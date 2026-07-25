# Recovery UI

A browser-based way to **browse snapshots and restore specific files by clicking**,
complementing the scriptable [`restore.sh`](../scripts/restore.sh) CLI. It runs
**locally** today; the same code is structured to **deploy to AWS later** (an
opt-in, not-yet-deployed CDK stack).

## Local UI (`npm run ui`)

```sh
npm run ui                      # opens http://127.0.0.1:<port>/?t=<token> in your browser
npm run ui -- --port 9000       # fixed port
npm run ui -- --no-open         # don't auto-open the browser
npm run ui -- --env-file /path/to/env   # non-default /etc/restic/env
npm run ui -- --idle-timeout 30 # auto-shut down after 30 min idle
```

What you can do:

- **Pick a snapshot** from the dropdown (newest first).
- **Browse its file tree** — folders expand lazily (one `restic ls` per folder, so
  it's fast even on large trees).
- **Preview** a file inline (text and images) or **Download** any file.
- **Search filenames** across the snapshot.
- **Select files/folders** (checkboxes) and **Restore** them into a fresh folder,
  with live progress and a **Reveal in Finder** button when it's done.

### Security model

- The server **binds to `127.0.0.1` only** and mints a **random per-session token**.
  Every request must present it (in the URL or the `x-zuruck-token` header), so
  other local processes and cross-site requests can't drive it.
- **restic credentials never reach the browser** — they live only in the server
  process and the restic children it spawns (loaded from `/etc/restic/env`, exactly
  like `backup.sh`/`restore.sh`).
- **Restore is the only operation that writes anything**, and it refuses to write
  into `$HOME`, `/`, or any existing non-empty directory — the same guards as
  `restore.sh`. It never overwrites your live files.
- Cold (Glacier/Deep Archive) data: `dump`/`restore` will stall on cold packs.
  Warm them first with [`restore.sh stage`](../scripts/restore.sh), then retry.

## How it's built

```
app/
  core/     provider-agnostic restic logic (no HTTP/Lambda) — snapshots, ls, find, dump, restore, guards
  server/   LOCAL adapter — Node stdlib http, token auth, serves the SPA
  web/      the browser SPA (vanilla TypeScript)
  lambda/   CLOUD adapter (scaffold) — Function URL handler reusing core; restic from a layer
  zuruck-ui.mjs  launcher: esbuild-bundles server + SPA, then runs it
```

No new runtime dependencies — just Node's stdlib plus `esbuild`/`ts-node`, which
were already devDependencies. (`ts-node` is broken under Node 24, so the launcher
builds with esbuild and runs the bundle.)

## Cloud deployment (scaffold — opt-in, not yet deployed)

The `app/core` logic is provider-agnostic, so the same code backs an AWS
deployment via a **separate, opt-in** CDK stack (`lib/recovery-ui-stack.ts`):

```sh
# Fetch the SHA-pinned restic binary for the Lambda layer first:
app/lambda/fetch-restic.sh 0.19.0 <sha256-from-github-releases>

npx cdk synth ZuruckRecoveryUiStack -c deployRecoveryUi=true   # synthesizes; does NOT deploy
# (deploy is intentionally left to you once the auth model below is chosen)
```

It provisions an S3 + CloudFront (OAC) static site for the SPA and a **restic
Lambda** (restic from the layer) behind an **IAM-authenticated Function URL**,
with IAM scoped to **one client prefix**, restore/read-only (no delete/prune).
Without the flag it does not exist — the core `ZuruckStack` is untouched.

### ⚠️ Open items before deploying

- **Auth wiring (required).** The Function URL is `AWS_IAM`, so the browser must
  SigV4-sign requests (a Cognito Identity Pool or equivalent). Wiring that is the
  one TODO left open. **Do not** switch the Function URL to `NONE` — that would
  expose restic to the internet.
- **Blast radius (by design).** A restic restore Lambda *must* hold `s3:GetObject`
  + `kms:Decrypt` + read the repo's SSM master password — the exact grants the
  freshness checker was deliberately denied. They're scoped to a single client
  prefix and read/restore-only, but this is a real expansion; review before deploying.
- **Restore semantics differ in the cloud.** There's no "local folder" to write to.
  The scaffold implements browse + single-file dump; bulk restore (restore to
  `/tmp` → zip → S3 → presigned URL, with Fargate for large jobs) plugs into the
  `sink` seam in [`app/core/restore.ts`](../app/core/restore.ts) and is a follow-up.

See the full plan in [docs/plans/recovery-ui-plan.md](plans/recovery-ui-plan.md).
