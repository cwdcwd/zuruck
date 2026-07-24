<#
.SYNOPSIS
  Zuruck — restic backup wrapper for Windows (parallel to scripts/backup.sh).

.DESCRIPTION
  Loads the machine config + DPAPI-encrypted secrets, then runs a restic backup
  with VSS (--use-fs-snapshot) so open/locked files are captured. Clears stale
  locks first, tolerates partial-read (exit 3), and never lets a retention/prune
  hiccup mark the whole backup as failed. Meant to be run by the scheduled task
  (as SYSTEM, elevated) or manually.

  Backup paths come from config.psd1 (recorded at setup time), NOT from
  $env:USERPROFILE — under the SYSTEM task that variable points at SYSTEM's own
  profile, not the user's.

.EXAMPLE
  .\backup.ps1                         # back up the configured path set (tag: auto)
  .\backup.ps1 -Forget                 # back up, then apply retention + prune
  .\backup.ps1 -Path C:\Users\me\Docs  # back up only these paths
  .\backup.ps1 -DryRun                 # show what would be backed up
  .\backup.ps1 -Tag scheduled -Forget  # what the scheduled task runs
#>
[CmdletBinding()]
param(
    [string[]]$Path,
    [switch]$Forget,
    [switch]$DryRun,
    [string]$Tag = 'auto',
    [switch]$NoVss
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'zuruck.psm1') -Force

# ── Load config + secrets into this process' environment ───────────────────
$cfg = Set-ZuruckEnvironment

# Retention (matches scripts/backup.sh and the systemd unit).
$keepDaily   = if ($cfg.ContainsKey('KeepDaily'))   { $cfg.KeepDaily }   else { 7 }
$keepWeekly  = if ($cfg.ContainsKey('KeepWeekly'))  { $cfg.KeepWeekly }  else { 4 }
$keepMonthly = if ($cfg.ContainsKey('KeepMonthly')) { $cfg.KeepMonthly } else { 6 }
$keepYearly  = if ($cfg.ContainsKey('KeepYearly'))  { $cfg.KeepYearly }  else { 2 }

# ── Resolve the set of paths to back up ────────────────────────────────────
$paths = if ($Path) { $Path } else { $cfg.BackupPaths }
if (-not $paths) { throw "No backup paths: pass -Path or set BackupPaths in $(Get-ZuruckConfigPath)." }

$existing = @()
foreach ($p in $paths) {
    if (Test-Path -LiteralPath $p) { $existing += $p }
    else { Write-Warning "[skip] not found: $p" }
}
if (-not $existing) { throw "None of the requested paths exist." }

# ── Resolve the exclude file ───────────────────────────────────────────────
$excludeFile = $null
if ($cfg.ContainsKey('ExcludeFile') -and $cfg.ExcludeFile) { $excludeFile = $cfg.ExcludeFile }
elseif (Test-Path (Join-Path $PSScriptRoot 'restic-excludes.txt')) {
    $excludeFile = Join-Path $PSScriptRoot 'restic-excludes.txt'
}

# ── VSS: needs elevation; fall back with a warning if not elevated ─────────
$useVss = (-not $NoVss) -and (-not ($cfg.ContainsKey('UseVss') -and $cfg.UseVss -eq $false))
if ($useVss -and -not (Test-ZuruckElevated)) {
    Write-Warning "Not elevated — disabling VSS (--use-fs-snapshot); open/locked files may be skipped. Run as Administrator (the scheduled task runs as SYSTEM)."
    $useVss = $false
}

# ── S3 tuning + network readiness ──────────────────────────────────────────
# Optional: cap parallel S3 connections (config.S3Connections; restic default 5)
# to reduce connect timeouts on a flaky link.
$globalOpts = @()
if ($cfg.ContainsKey('S3Connections') -and $cfg.S3Connections) {
    $globalOpts = @('-o', "s3.connections=$($cfg.S3Connections)")
}
# Hard runtime cap so a wedged restic can't block the schedule (config default 4h).
$maxRuntime = if ($cfg.ContainsKey('MaxRuntimeSeconds')) { [int]$cfg.MaxRuntimeSeconds } else { 14400 }

# A scheduled run often fires right after wake, while the network is still
# coming up — a burst of S3 connect timeouts (restic retries, but it's noisy).
# Wait briefly for the S3 endpoint to answer first. Skip with SkipNetWait=$true.
function Wait-ForS3 {
    if ($cfg.ContainsKey('SkipNetWait') -and $cfg.SkipNetWait) { return }
    if ($env:RESTIC_REPOSITORY -notlike 's3:*') { return }
    $s3host = ($env:RESTIC_REPOSITORY -replace '^s3:', '').Split('/')[0]
    $tries = if ($cfg.ContainsKey('NetWaitTries')) { [int]$cfg.NetWaitTries } else { 12 }
    for ($i = 1; $i -le $tries; $i++) {
        if (Test-NetConnection -ComputerName $s3host -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue) { return }
        Write-Warning "[net] $s3host not reachable yet (attempt $i/$tries); waiting 5s..."
        Start-Sleep -Seconds 5
    }
    Write-Warning "[net] proceeding without confirmed reachability; restic will retry."
}
Wait-ForS3

# ── Clear stale locks from a killed run (safe: only removes stale locks) ────
& restic @globalOpts unlock *> $null

# ── Build restic args ──────────────────────────────────────────────────────
$rargs = @('backup') + $existing + @('--tag', $Tag, '--exclude-caches')
if ($useVss)      { $rargs += '--use-fs-snapshot' }
if ($excludeFile) { $rargs += @('--iexclude-file', $excludeFile) }
if ($DryRun)      { $rargs += @('--dry-run', '--verbose') }

Write-Host "==> Repository: $($env:RESTIC_REPOSITORY)"
Write-Host "==> Excludes:   $(if ($excludeFile) { $excludeFile } else { '<none>' })"
Write-Host "==> VSS:        $(if ($useVss) { 'on (--use-fs-snapshot)' } else { 'off' })"
Write-Host "==> Backing up: $($existing -join ', ')"

$backupRc = Invoke-ResticWithTimeout -ResticArgs (@($globalOpts) + $rargs) -TimeoutSeconds $maxRuntime
# 0 = ok, 3 = snapshot created but some files unreadable (treat as warning).
if ($backupRc -eq 3) {
    Write-Warning "restic reported unreadable source files (exit 3); snapshot was still created — continuing."
} elseif ($backupRc -ne 0) {
    Write-Error "restic backup failed (exit $backupRc)."
    exit $backupRc
}

# ── Optional retention (never fatal — the snapshot already saved) ──────────
if ($Forget -and -not $DryRun) {
    Write-Host "==> Applying retention (keep d=$keepDaily w=$keepWeekly m=$keepMonthly y=$keepYearly) + prune"
    $forgetArgs = @($globalOpts) + @('forget',
        '--keep-daily', $keepDaily, '--keep-weekly', $keepWeekly,
        '--keep-monthly', $keepMonthly, '--keep-yearly', $keepYearly, '--prune')
    $forgetRc = Invoke-ResticWithTimeout -ResticArgs $forgetArgs -TimeoutSeconds $maxRuntime
    if ($forgetRc -ne 0) {
        Write-Warning "retention/prune failed (exit $forgetRc); snapshot is safe, will retry next run."
    }
}

Write-Host "==> Done. Snapshots:"
& restic @globalOpts snapshots --latest 5 2>$null

# ── Refresh the local status dashboard (best-effort) ───────────────────────
$statusScript = Join-Path $PSScriptRoot 'status.ps1'
if (Test-Path $statusScript) {
    try { & $statusScript -Html | Out-Null } catch { Write-Verbose "$_" }
}

exit 0
