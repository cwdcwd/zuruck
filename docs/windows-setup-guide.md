# Windows Client Setup Guide

How to back up a Windows machine to Zuruck. The Windows client uses native
PowerShell + `restic.exe` (no WSL) and a Scheduled Task running as **SYSTEM**
with **VSS** so open/locked files are captured. The cloud side is unchanged — the
client (`fenster02` by default) is already in [`lib/config/clients.ts`](../lib/config/clients.ts)
and the freshness-checker tracks it against its 48h threshold automatically.

All scripts live in [`scripts/win/`](../scripts/win/). Run PowerShell **as
Administrator** for setup, scheduling, and any VSS backup.

> Scripts aren't code-signed, so launch them with
> `powershell -ExecutionPolicy Bypass -File .\<script>.ps1 …`, or
> `Set-ExecutionPolicy -Scope Process Bypass` for the session.

## Prerequisites

- Windows 10/11 (Windows PowerShell 5.1 built in, or PowerShell 7).
- Admin rights on the machine.
- `restic.exe` (setup can install it via winget).
- The client's credentials from the deploy account (see below).

## Step 1: Get the client credentials (admin, on the deploy machine)

`fenster02` is already provisioned by `cdk deploy`. Retrieve:

```bash
# Access key id (in the secret's description) + secret value
aws secretsmanager describe-secret  --secret-id zuruck/clients/fenster02/access-key --query Description --output text
aws secretsmanager get-secret-value --secret-id zuruck/clients/fenster02/access-key --query SecretString --output text

# Master password (needed once, to init the repo + add the client key)
aws ssm get-parameter --name /zuruck/restic/fenster02/master-password --with-decryption --query Parameter.Value --output text
```

## Step 2: Configure the client (elevated PowerShell)

```powershell
cd scripts\win
.\setup.ps1 -ClientName fenster02 `
            -Bucket zuruck-backup-<account-id>-us-west-2 `
            -AccessKeyId <AccessKeyId> `
            -InstallRestic
# prompts (securely) for the AWS secret and the SSM master password
```

`setup.ps1`:
- installs restic (with `-InstallRestic`);
- stores the AWS secret and a generated restic **client password**, encrypted
  with **DPAPI (LocalMachine scope) + an ACL-locked entropy file** under
  `%ProgramData%\zuruck\secrets` (folder ACL: SYSTEM + Administrators only);
- writes `%ProgramData%\zuruck\config.psd1` (repo URL, backup paths, excludes,
  retention, 48h threshold);
- `restic init`s the `fenster02` prefix with the master password and adds the
  machine-local client key;
- verifies the client password opens the repo.

Run setup **as the user whose folders you want backed up** (the default backup
set is that user's Desktop/Documents/Pictures/Music/Videos/Favorites +
`.ssh`/`.aws`/`.gitconfig`), or pass `-BackupPath` explicitly.

> **Why the path set is recorded at setup time:** the scheduled task runs as
> SYSTEM, whose `%USERPROFILE%` is *not* the user's profile. So paths are frozen
> into `config.psd1` at setup and read from there at backup time.

## Step 3: First backup (elevated, for VSS)

```powershell
.\backup.ps1              # tag "auto"
.\backup.ps1 -Forget      # + retention/prune
```

VSS (`--use-fs-snapshot`) needs elevation; a non-elevated run still works but
skips locked files with a warning. Confirm with `restic snapshots`.

## Step 4: Schedule it

```powershell
.\install-task.ps1                 # every 4h (00/04/08/12/16/20), as SYSTEM
.\install-task.ps1 -EveryHours 6
.\install-task.ps1 -Wake           # also wake the machine to run
.\install-task.ps1 -Status
.\install-task.ps1 -Uninstall
```

The task runs `backup.ps1 -Forget -Tag scheduled` as SYSTEM with highest
privileges (VSS) and **`StartWhenAvailable`**, so a run missed while the machine
was asleep fires on the next wake.

## Step 5: Check health

```powershell
.\status.ps1                 # terminal summary
.\status.ps1 -Html -Open     # self-contained dashboard
.\status.ps1 -Json           # scriptable
```

## Recovery

```powershell
.\restore.ps1 list
.\restore.ps1 browse latest C:\Users\<you>\Documents
.\restore.ps1 dump latest C:\Users\<you>\.gitconfig -Out .\gitconfig.recovered
.\restore.ps1 restore latest -Target C:\zuruck-restore
.\restore.ps1 restore <id> -Target C:\zuruck-restore -Include C:\Users\<you>\Documents -Verify
.\restore.ps1 mount C:\zuruck-mount      # needs WinFsp: winget install WinFsp.WinFsp
.\restore.ps1 stage                      # pre-restore Glacier/Deep Archive objects
```

`restore` always writes to a **fresh** directory (never in place) and prompts
first. See the [runbook](./runbook.md#recovery-quickstart) for the recovery model.

## Troubleshooting

- **Task shows a non-zero `LastTaskResult`** (`install-task.ps1 -Status`): open
  `restic snapshots` / the task history. `267009` = currently running, `267011`
  = never run, `0` = success. For a lock error, see the runbook's
  [Backup Job Fails to Lock](./runbook.md#backup-job-fails-to-lock-last-exit-11--repository-is-already-locked)
  — `backup.ps1` already runs `restic unlock` at the start, so this self-heals.
- **Locked/open files skipped**: the run wasn't elevated (no VSS). The scheduled
  task runs as SYSTEM and is fine; for manual runs use an elevated shell.
- **"repository is already locked"**: `backup.ps1` clears stale locks
  automatically; to clear by hand: `restic unlock` (with the env loaded).
- **`restic mount` fails**: install WinFsp (`winget install WinFsp.WinFsp`).
- **Wrong-password / access-denied**: re-run `setup.ps1` (it reuses the existing
  client password unless you pass `-RotateClientPassword`).
