# Plan: Windows client support for Zuruck

## Context

Zuruck already backs up macOS/Linux clients to per-client S3 prefixes, and the
cloud side is OS-agnostic — the bucket, per-client IAM, KMS, and the hourly
freshness-checker Lambda all work by watching S3 object timestamps. The client
`fenster02` ("windows desktop", 48h freshness threshold) is **already in the
registry** ([lib/config/clients.ts](../../lib/config/clients.ts)), so `cdk deploy`
already provisions its IAM user, Secrets Manager access key, and SSM master
password. What's missing is **client-side tooling for Windows**: every existing
script is bash + `/etc/restic` + launchd/systemd + a macOS FDA wrapper, and
`client-setup.sh` explicitly `error`s on any OS other than Linux/Darwin.

Goal: a native-PowerShell toolset mirroring what we built for macOS
(`backup.sh`, `install-schedule.sh`, `status.sh`, `restore.sh`), so `fenster02`
can back up reliably with correct NTFS metadata, VSS for locked files, and the
same monitoring/recovery story — **no CDK/cloud changes required**.

## Confirmed decisions

- **Runtime:** native PowerShell + `restic.exe` (no WSL).
- **Scope:** full parallel toolset (backup, schedule, status, restore, setup, docs).
- **Secrets:** encrypted at rest via **DPAPI (LocalMachine scope) + an ACL-locked
  entropy file**; Credential Manager documented as the per-user alternative.
- **Privilege/VSS:** scheduled task runs as **SYSTEM** with `--use-fs-snapshot`
  (VSS), so open/locked/system files are captured.

## Deliverables

New directory `scripts/win/` (keeps PowerShell separate from the Unix scripts):

### 1. `scripts/win/setup.ps1`  — parallel to `client-setup.sh`
- Params: `-ClientName` (default `fenster02`), `-Bucket`, `-Region` (default
  `us-west-2`), `-AccessKeyId`, secret via `-SecretAccessKey`/prompt,
  `-BackupPath` (repeatable), `-InstallRestic`.
- Install restic (winget/scoop, or SHA-pinned download mirroring
  `client-setup.sh`'s pinning) when `-InstallRestic`.
- Store secrets: encrypt `AWS_SECRET_ACCESS_KEY` and the restic **client
  password** with `[System.Security.Cryptography.ProtectedData]::Protect(…,
  'LocalMachine')` plus a random entropy blob; write ciphertext + entropy under
  `%ProgramData%\zuruck\` and ACL the folder to `SYSTEM` + `Administrators` only.
- Write `%ProgramData%\zuruck\config.psd1`: repository URL
  (`s3:s3.<region>.amazonaws.com/<bucket>/<client>`), backup paths, exclude-file
  path, retention, freshness threshold (48h to match the registry).
- **Repo init (one-time admin step):** using the **master password** from SSM,
  `restic init` the client prefix, then `restic key add` the client password —
  same two-step as [docs/runbook.md](../runbook.md) "Adding a New Client".
- Connectivity test: `aws s3 ls <prefix>` + `restic snapshots`.

### 2. `scripts/win/backup.ps1`  — parallel to `scripts/backup.sh`
- Load `config.psd1`; decrypt secrets and set `$env:RESTIC_*/AWS_*` **in-process
  only** (never persisted to the environment).
- Path resolution mirroring `backup.sh`: explicit args → include list →
  default Windows set (`$env:USERPROFILE`, i.e. Desktop/Documents/Pictures/…,
  AppData\Roaming, etc.); skip non-existent paths.
- `restic unlock` at start (self-heal stale locks — the exact fix we added to
  `backup.sh`).
- `restic backup <paths> --use-fs-snapshot --tag scheduled --exclude-caches
  --exclude-file <win-excludes> --iexclude-file` (case-insensitive on Windows).
- **Exit-code hardening (ported):** treat restic exit 3 as a warning; wrap
  `forget --prune` so a retention/lock failure is non-fatal (snapshot already
  saved). Exit 0 on success/partial.
- Regenerate the HTML dashboard at the end (best-effort), like `backup.sh` does.

### 3. `scripts/win/restic-excludes.txt`
Windows-oriented excludes: `$Recycle.Bin`, `pagefile.sys`, `hiberfil.sys`,
`swapfile.sys`, `AppData\Local\Temp`, browser caches, `node_modules`, `.venv`,
build output — the Windows analog of `scripts/restic-excludes.txt`.

### 4. `scripts/win/install-task.ps1`  — parallel to `install-schedule.sh`
- Register a Scheduled Task `Zuruck Backup` via `Register-ScheduledTask`.
- Triggers: daily at `00/04/08/12/16/20` (mirrors the launchd calendar), spacing
  from an `-EveryHours` param.
- Principal: `SYSTEM`, `-RunLevel Highest` (VSS needs elevation).
- Settings: **`-StartWhenAvailable`** (runs a run missed while asleep on next
  wake — the Windows answer to the launchd sleep gap) and optional **`-WakeToRun`**;
  `-ExecutionTimeLimit` generous; battery settings allowed.
- Verbs: `-Status` (Get-ScheduledTaskInfo → LastTaskResult/LastRunTime/NextRunTime),
  `-Uninstall`. No FDA/compiled-wrapper analog is needed on Windows (no TCC).

### 5. `scripts/win/status.ps1`  — parallel to `scripts/status.sh`
- Gather: task state + `LastTaskResult` (Get-ScheduledTaskInfo); running?
  (`Get-Process restic`); `restic snapshots --json`; `restic stats --json`
  (filter to the JSON line); freshness vs threshold.
- Output: colored **terminal** summary (FRESH/STALE/RUNNING), **`-Json`**, and
  **`-Html [path]`** reusing the same self-contained dashboard template
  (freshness gauge, per-snapshot bars, snapshot table; theme-aware; no external
  assets so it also works as an Artifact).

### 6. `scripts/win/restore.ps1`  — parallel to `scripts/restore.sh`
- Verbs: `list`, `browse <id> [path]`, `dump <id> <file> [-Out]`,
  `restore <id> -Target <dir> [-Include …] [-DryRun] [-Verify]` (fresh-target
  safety guard, never restore into the profile root), `stage` (Glacier
  `restore-object` loop via `aws`), `mount <dir>` — detect **WinFsp** (the
  Windows analog of macFUSE; hint `winget install WinFsp` if absent).

### 7. Docs
- NEW `docs/windows-setup-guide.md` — the Windows parallel of
  `client-setup-guide.md` (install → secrets/DPAPI → repo init → first backup
  with VSS → Task Scheduler → verify → troubleshooting incl. `LastTaskResult`
  codes and WinFsp).
- EDIT [README.md](../../README.md) — add `scripts/win/` to Project Structure and
  a Windows client command row.
- EDIT [docs/runbook.md](../runbook.md) — Windows task troubleshooting note
  (LastTaskResult ≠ 0, VSS/elevation, stale-lock self-heal already covered).
- EDIT [docs/backup-strategy.md](../backup-strategy.md) — point Windows users
  at `install-task.ps1` alongside the systemd/launchd notes.

## Explicitly NOT in scope
- No CDK/cloud changes — `fenster02` is already provisioned; the freshness-checker
  and dashboard already track it against its 48h threshold.
- No compiled FDA wrapper — Windows has no TCC; VSS+elevation is the analog and is
  handled by the task principal.

## Cross-cutting design notes
- **Secret scope vs SYSTEM task:** DPAPI *LocalMachine* scope lets the SYSTEM-run
  task decrypt; the entropy file (ACL-locked to SYSTEM/Administrators) is the
  actual secret, mitigating "any local process can decrypt." Documented fallback:
  encrypt under SYSTEM's own user-scope DPAPI (run setup as SYSTEM) for stronger
  isolation, or Credential Manager for a user-run (non-SYSTEM) task.
- **PowerShell compatibility:** target Windows PowerShell 5.1 (built in) and
  PowerShell 7; avoid Unix-only cmdlets. Add a version guard.
- **Repo/flags parity:** same env var names as Unix (`RESTIC_REPOSITORY`,
  `RESTIC_PASSWORD_FILE`, `AWS_*`); same repo URL form; same GFS retention.

## Verification
- **Static (from a macOS/Linux dev box, best-effort):** if `pwsh` is available,
  parse each script with
  `pwsh -NoProfile -Command '$null=[ScriptBlock]::Create((Get-Content -Raw f))'`
  and run PSScriptAnalyzer if installed. Otherwise syntax is reviewed by hand.
- **On the Windows box (authoritative):**
  1. `setup.ps1 -ClientName fenster02 …` → secrets stored, repo init + key add,
     `restic snapshots` opens with the client password.
  2. `backup.ps1` elevated → snapshot saved with `--use-fs-snapshot`; confirm a
     known-locked file (e.g. an open Office doc) is captured; exit 0.
  3. `status.ps1` and `status.ps1 -Html` → matches `restic snapshots`; dashboard renders.
  4. `restore.ps1 restore latest -Target C:\zuruck-restore -Include <file> -Verify`
     then a `dump` of a single file → byte-identical to source.
  5. `install-task.ps1` → task registered; `-Status` shows it; force-run and
     confirm `LastTaskResult = 0`; toggle sleep to confirm `StartWhenAvailable`
     catch-up.
  6. Cloud: freshness-checker sees `fenster02` objects; dashboard turns healthy.
