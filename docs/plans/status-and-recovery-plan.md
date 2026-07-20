# Plan: Local status visualization + data-recovery workflow

## Context

Zuruck backs up this Mac to S3 via restic, on a launchd schedule through the FDA
wrapper (`scripts/zuruck-runner.c`). Today the only way to see what's happening is
tailing a log or running `pgrep`. There **is** rich cloud-side monitoring (a
CloudWatch dashboard `zuruck-backup-health`, SNS email alerts, and an hourly
freshness-checker Lambda emitting `Zuruck/Backup` metrics — see
`lib/constructs/backup-monitoring.ts`, `lib/lambda/freshness-checker.ts`) — but
nothing local, and no recovery tooling at all. This adds (1) a way to *see* status
at a glance and (2) a guided way to *execute a recovery*.

Both features are client-side shell tools that reuse the existing env pattern
(`/etc/restic/env` → repo + `RESTIC_PASSWORD_FILE` + AWS creds), the same one
`scripts/backup.sh` sources. restic is 0.19.0 (modern flags + JSON), `jq` present.

**Confirmed scope:** (A) status = **HTML dashboard + terminal**; (B) recovery =
**full guided `restore.sh`** (list/browse/mount/restore/selective/dump/Glacier stage).

## Deliverable A — `scripts/status.sh` (status visualization)

A single client-side status tool with a terminal view and an HTML dashboard.

Gathers:
- **Schedule state** — `launchctl print gui/$(id -u)/com.zuruck.backup`: loaded?,
  running now?, last exit code, PID. (Same source as `install-schedule.sh --status`.)
- **Live run** — `pgrep -f 'zuruck-runner|restic backup'` to show "backing up now".
- **Repo health** — `restic snapshots --json` and `restic stats --json` (read-only,
  safe during a running backup): latest snapshot age, snapshot count, total size,
  per-snapshot table.
- **Freshness** — age of newest snapshot vs a threshold (default 24h, matching
  `lazybaer02` in `lib/config/clients.ts`; overridable via `--threshold`/env).
- **Last log** — tail of `~/Library/Logs/zuruck-backup.log`.

Outputs (flags):
- default: colored **terminal** summary with a FRESH/STALE/RUNNING verdict badge.
- `--json`: machine-readable blob (drives the HTML; also handy for scripting).
- `--html [path]`: writes a **self-contained** HTML dashboard (inline CSS/JS, no
  external assets) — freshness gauge, schedule/run-state badges, a snapshot
  size-over-time chart, and a recent-snapshots table. Static, point-in-time;
  refresh by re-running. Can be published as an Artifact for a shareable view.

Reuse: copy the env-sourcing guard from `scripts/backup.sh:29,56-59`; the launchd
status idiom from `scripts/install-schedule.sh`. HTML styling follows the
`dataviz` + `artifact-design` skills (theme-aware, accessible).

Integration: after each scheduled run, regenerate the HTML so it's always current
— a small post-run step in the backup flow writing to a fixed path
(`~/Library/Logs/zuruck-status.html`) that can be bookmarked/opened anytime.

## Deliverable B — `scripts/restore.sh` (data recovery)

A guided, safety-first wrapper over restic restore, reusing the same env. Verbs:
- `list` (default) — `restic snapshots` table.
- `browse <id|latest>` — `restic ls -l <id>`; and `mount <dir>` via `restic mount`
  (detect macFUSE; if absent, print the one-line install hint and fall back to `ls`).
- `restore <id|latest> --target <dir> [--include PATH ...] [--path P] [--host H] [--dry-run]`
  — restores into a **fresh** target dir (default `~/zuruck-restore-<date>`; never
  in place), selective via repeatable `--include` (fine on 0.19).
- `dump <id|latest> <file-in-snapshot> [> out]` — single-file recovery without a
  full restore (`restic dump`).
- Glacier pre-stage — if a restore hits cold objects, a `stage` path runs the
  `aws s3api restore-object` bulk loop (from `runbook.md:120-131`) and polls
  `head-object` StorageClass until Standard. Current data is Standard (<90d) so
  this is documented + supported but not the common path yet.

Also documents (in `docs/runbook.md`, not the script) the operator-only
version-history recovery via `aws s3api list-object-versions` for the case where a
`forget`/`prune` dropped a snapshot but the noncurrent S3 version survives (~90d
window). Object Lock never blocks reads, so restores are otherwise unimpeded.

## Immediate answer — how to recover right now (no new script needed)

```bash
source /etc/restic/env
restic snapshots                                  # find the snapshot id
restic restore latest --target ~/zuruck-restore   # full restore to a new dir
restic restore <id> --target ~/zuruck-restore --include /Users/cwd/Documents/foo  # selective
restic dump latest /Users/cwd/.gitconfig > ./gitconfig.recovered                  # one file
```

## Files

- NEW `scripts/status.sh` — status collector + terminal/JSON/HTML renderer.
- NEW `scripts/restore.sh` — guided restore wrapper.
- EDIT `docs/runbook.md` — add a "Local Status" note and a concise "Recovery
  Quickstart" pointing at `restore.sh`; add the version-history recovery snippet.
- EDIT the launchd/backup flow — regenerate the HTML dashboard after each run.

## Verification

- `./scripts/status.sh` → terminal summary matches reality (schedule loaded, running
  now, latest snapshot age). Cross-check against `restic snapshots` and `launchctl print`.
- `./scripts/status.sh --html /tmp/z.html` → open in browser; optionally publish as Artifact.
- `./scripts/restore.sh list` → lists snapshots. `restore latest --target /tmp/rtest
  --include <small file> --dry-run` then a real run; diff restored file vs source.
- `./scripts/restore.sh dump latest ~/.gitconfig` → matches the live file.
- All exercised against the live `lazybaer02` repo (reads only; no forget/prune).
