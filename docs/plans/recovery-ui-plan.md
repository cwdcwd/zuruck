# Plan: Zuruck Recovery UI — local TypeScript web app, cloud-ready via CDK

## Context

Recovery today is CLI-only ([scripts/restore.sh](../../scripts/restore.sh):
`list`, `browse`, `dump`, `restore --include`, `mount`, Glacier `stage`). We want
a **good UI** to browse snapshots and restore specific files by clicking.

Decision: a **local web UI built in TypeScript**, living in its **own top-level
`app/` folder** (not `scripts/`), and **architected so it can later deploy to AWS
via the CDK**. This first pass builds the working local app **and** a
synthesizable (not-yet-deployed) CDK stack for the cloud version.

Why this fits the repo (already CDK/TypeScript):
- Node **v24**, TypeScript **5.9**, strict, `module: NodeNext`.
- **esbuild** + **ts-node** already devDeps → server runs with no build step, the
  SPA bundles with a tool already present. **No web framework** → Node stdlib `http`, zero new runtime deps.
- CDK conventions to mirror: Constructs composed in a Stack; `lambdaNodejs.NodejsFunction`
  (entry `.ts`, `bundling`, ARM64/Node20) as in
  [backup-monitoring.ts](../../lib/constructs/backup-monitoring.ts):95; least-privilege,
  security-review-driven IAM; optional features gated by props/context (e.g. `enableAuditTrail`).
- `restic ls <snap> <dir>` **without `--recursive`** = immediate children only →
  lazy per-click tree loading is native and cheap.

## Architecture: provider-agnostic core + adapters

The key move for cloud-readiness: **all restic logic lives in `app/core/` with no
HTTP or Lambda knowledge.** The local server and the future Lambda are thin
adapters over the same core; the SPA is shared (inlined locally, served from S3 in cloud).

```
app/
  core/            provider-agnostic — no http/lambda
    restic.ts        spawn restic (args array, no shell), NDJSON stream parse
    snapshots.ts     listSnapshots()
    tree.ts          listDir(snap, path)  → restic ls --json (non-recursive)
    dump.ts          dumpFile(snap, path) → stream
    restore.ts       restore(snap, includes[], sink)  — sink is pluggable
    env.ts           EnvSource interface: local=/etc/restic/env, cloud=SSM+role
    validate.ts      target-path guards (ported from restore.sh:123-129)
    format.ts        human()/fmt_age() (ported from status.sh:64-68)
    types.ts
  server/          LOCAL adapter (works NOW)
    server.ts        Node stdlib http; 127.0.0.1 + random token; opens browser
    router.ts        /api/* → core; GET / → SPA (esbuild-bundled, inlined)
  lambda/          CLOUD adapter (scaffold; not deployed)
    handler.ts       Function URL event → core; restic from layer; restore→/tmp→presigned
    fetch-restic.sh  populate the ARM64 restic Lambda-layer asset (SHA-pinned)
  web/             shared frontend SPA (TypeScript)
    app.ts, components, index.html template
    styles.css       theme tokens ported from status.sh:271-314 (light/dark)
```

## Local app (usable immediately)

- **`app/server/server.ts`** — stdlib `http`, binds `127.0.0.1` on an ephemeral
  port + per-session **random token** (every `/api/*` call must present it; blocks
  other local procs / CSRF). Loads `/etc/restic/env` via `core/env.ts` (reuse the
  load + S3-URL parse from [restore.sh](../../scripts/restore.sh):44-58). Secrets
  stay server-side; **never sent to the browser**.
- **Endpoints** (all read-only except restore) → `app/core`:
  - `GET /api/snapshots` · `GET /api/ls?snap&path` (non-recursive) ·
    `GET /api/find?snap&q` (`restic find --json`) ·
    `GET /api/dump?snap&path` (stream; preview + Download) ·
    `POST /api/restore {snap, includes[], target}` (**validate target first**;
    the only mutating endpoint; streams progress).
- **SPA** (`app/web`) — snapshot picker; lazy checkbox tree; preview pane (text
  inline size-capped, images inline, else Download); filename search; restore
  panel with target field (default `~/zuruck-restore-<ts>`), confirm, live
  progress, "Reveal in Finder" (`open`). Reuses the dashboard's look.
- **Run:** `"ui": "ts-node app/server/server.ts"` in [package.json](../../package.json);
  thin `app/zuruck-ui` wrapper. Flags `--env-file --port --no-open --idle-timeout`.

## CDK scaffold (synthesizable now, deploy later)

New **`lib/recovery-ui-stack.ts`** (`RecoveryUiStack`), instantiated in
[bin/zuruck.ts](../../bin/zuruck.ts) **only when `-c deployRecoveryUi=true`**, so
the core backup stack and current deploys are untouched by default. It receives
`bucket` + `encryptionKey` from `ZuruckStack` (same app → cross-stack refs).

Synthesizes:
- **SPA hosting:** private S3 bucket + CloudFront (OAC); `aws-s3-deployment`
  pushes the built `app/web` assets.
- **Restic API Lambda:** `NodejsFunction` running `app/lambda/handler.ts` (reuses
  `app/core`), with an **ARM64 restic binary as a Lambda layer**
  (`lambda.Code.fromAsset`, populated by `app/lambda/fetch-restic.sh`, SHA-pinned
  like `client-setup.sh`). Behind a **Lambda Function URL (AuthType=AWS_IAM)**.
- **IAM (least-privilege, single client prefix):** `s3:GetObject`+`s3:ListBucket`
  on `bucket/<prefix>/*`, `kms:Decrypt` on the key, `ssm:GetParameter`
  (WithDecryption) on `/zuruck/restic/<client>/*`. Restore-only — **no Delete, no prune.**
- **Outputs:** CloudFront URL, Function URL, layer ARN.

### ⚠️ Security caveats (called out for review, this repo cares)
- A restic-in-Lambda **necessarily** holds `s3:GetObject` + `kms:Decrypt` +
  the client restic password — the exact grants the freshness checker was
  deliberately denied ([backup-monitoring.ts](../../lib/constructs/backup-monitoring.ts):124-145).
  This is a genuine blast-radius expansion. Mitigations baked into the scaffold:
  scope to one client prefix, restore/read-only, IAM-auth Function URL, private
  SPA via CloudFront OAC. **Auth model (Cognito vs. IAM SigV4 from the SPA) is
  left as an explicit TODO** — do not expose restic to the internet unauthenticated.
- **Cloud restore semantics differ:** no "local folder." v1 cloud path = browse +
  single-file dump via presigned URL; **bulk restore → zip in `/tmp` → S3 →
  presigned download**, bounded by Lambda 15min/10GB. Large restores are a
  documented **Fargate** follow-up (the `sink` abstraction in `core/restore.ts` is
  where that plugs in).

## Docs
- NEW `docs/recovery-ui.md` — local usage (`npm run ui`), security model, the
  cloud stack (opt-in `-c deployRecoveryUi=true`) + its caveats; complements `restore.sh`.
- EDIT [README.md](../../README.md) — add `app/` to Project Structure + a command row.
- EDIT [docs/client-setup-guide.md](../client-setup-guide.md) — a "Recovering files (UI)" pointer.

## Explicitly NOT in scope
- No macFUSE/mount UI, `fzf` picker, or third-party app.
- No changes to backup/schedule scripts or the core `ZuruckStack` (UI stack is separate + opt-in).
- No actual cloud deployment; no Cognito wiring; no Fargate bulk-restore (all documented seams).

## Verification
- **Local:** `npm run build` (tsc) clean; `npm run ui` binds 127.0.0.1, opens the
  browser; snapshots list; lazy-expand `Documents/`, `Pictures/`; preview text +
  image, download a binary, search a filename; select files → restore to a fresh
  temp dir → **byte-identical** to source and `restic dump`; guards reject `$HOME`
  / non-empty target and any tokenless `/api/*`; no secret in any browser response or stdout.
- **Cloud scaffold:** `cdk synth` succeeds with `-c deployRecoveryUi=true` and is a
  **no-op without it** (`cdk diff` clean against current); IAM policies scope to the
  single prefix; Function URL is `AWS_IAM`. (No deploy in this pass.)
