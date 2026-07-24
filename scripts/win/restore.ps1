<#
.SYNOPSIS
  Zuruck — restore / recover data on Windows (parallel to scripts/restore.sh).

.DESCRIPTION
  Wraps restic restore with the machine's stored env. All verbs except `restore`
  are read-only. `restore` writes into a FRESH target directory (never in place)
  and prompts before running.

.EXAMPLE
  .\restore.ps1 list
  .\restore.ps1 browse latest C:\Users\me\Documents
  .\restore.ps1 dump latest C:\Users\me\.gitconfig -Out .\gitconfig.recovered
  .\restore.ps1 restore latest -Target C:\zuruck-restore
  .\restore.ps1 restore <id> -Target C:\zuruck-restore -Include C:\Users\me\Documents -Verify
  .\restore.ps1 mount C:\zuruck-mount        # needs WinFsp
  .\restore.ps1 stage                        # pre-restore Glacier/Deep Archive objects
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][ValidateSet('list', 'browse', 'dump', 'restore', 'mount', 'stage')][string]$Verb = 'list',
    [Parameter(Position = 1)][string]$Snapshot = 'latest',
    [Parameter(Position = 2)][string]$File,
    [string]$Target,
    [string[]]$Include,
    [string]$SelectPath,
    [string]$SnapHost,
    [string]$Out,
    [string]$MountPoint = "$env:USERPROFILE\zuruck-mount",
    [string]$Prefix,
    [int]$Days = 7,
    [string]$Tier = 'Standard',
    [switch]$DryRun,
    [switch]$Verify,
    [switch]$Yes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'zuruck.psm1') -Force

$cfg = Set-ZuruckEnvironment

switch ($Verb) {

    'list' {
        Write-Host "Repository: $($env:RESTIC_REPOSITORY)"
        & restic snapshots
    }

    'browse' {
        if ($File) { & restic ls -l $Snapshot $File } else { & restic ls -l $Snapshot }
    }

    'dump' {
        if (-not $File) { throw "usage: restore.ps1 dump <id|latest> <file-in-snapshot> [-Out file]" }
        if ($Out) {
            Write-Host "Dumping $File from $Snapshot -> $Out"
            Invoke-ResticToFile -ResticArgs @('dump', $Snapshot, $File) -OutFile $Out
            Write-Host "Wrote $((Get-Item $Out).Length) bytes to $Out"
        } else {
            & restic dump $Snapshot $File
        }
    }

    'restore' {
        if (-not $Target) { $Target = Join-Path $env:USERPROFILE ("zuruck-restore-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss')) }
        $full = [System.IO.Path]::GetFullPath($Target)
        if ([string]::IsNullOrWhiteSpace($Target) -or
            $full -eq [System.IO.Path]::GetFullPath($env:USERPROFILE) -or
            $full -eq [System.IO.Path]::GetPathRoot($full)) {
            throw "Refusing to restore into '$Target'. Choose a fresh -Target directory."
        }
        if ((Test-Path $Target) -and (Get-ChildItem -Force $Target -ErrorAction SilentlyContinue)) {
            throw "Target '$Target' exists and is not empty. Choose a fresh -Target."
        }

        $rargs = @('restore', $Snapshot, '--target', $Target)
        if ($SelectPath) { $rargs += @('--path', $SelectPath) }
        if ($SnapHost)   { $rargs += @('--host', $SnapHost) }
        foreach ($inc in $Include) { $rargs += @('--include', $inc) }
        if ($Verify)     { $rargs += '--verify' }
        if ($DryRun)     { $rargs += @('--dry-run', '--verbose') }

        Write-Host "Repository: $($env:RESTIC_REPOSITORY)"
        Write-Host "Snapshot:   $Snapshot"
        Write-Host "Target:     $Target"
        if ($Include) { Write-Host "Include:    $($Include -join ', ')" }
        if ($DryRun)  { Write-Host "Mode:       DRY RUN (no files written)" }

        if (-not $DryRun -and -not $Yes) {
            if ([Environment]::UserInteractive) {
                $ans = Read-Host "Proceed with restore? [y/N]"
                if ($ans -notmatch '^[Yy]$') { Write-Host "Aborted."; return }
            } else {
                throw "Refusing to restore non-interactively without -Yes."
            }
        }
        New-Item -ItemType Directory -Force -Path $Target | Out-Null
        & restic @rargs
        if (-not $DryRun) { Write-Host "==> Restored to $Target" }
    }

    'mount' {
        # restic mount on Windows requires WinFsp.
        $winfsp = (Test-Path "$env:ProgramFiles\WinFsp\bin\winfsp-x64.dll") -or
                  (Get-Service -Name 'WinFsp.Launcher' -ErrorAction SilentlyContinue)
        if (-not $winfsp) {
            Write-Host "WinFsp is required for 'restic mount' on Windows but was not found."
            Write-Host "  Install it:  winget install WinFsp.WinFsp"
            Write-Host "  Or browse without mounting:  .\restore.ps1 browse latest"
            return
        }
        New-Item -ItemType Directory -Force -Path $MountPoint | Out-Null
        Write-Host "Mounting repository at: $MountPoint"
        Write-Host "Browse it in Explorer; press Ctrl-C here to unmount."
        & restic mount $MountPoint
    }

    'stage' {
        # Pre-restore Glacier / Deep Archive objects so a later restore can read them.
        if (-not (Get-Command aws -ErrorAction SilentlyContinue)) { throw "aws CLI not found." }
        $body = $env:RESTIC_REPOSITORY -replace '^s3:', ''
        $repoHost = $body.Split('/')[0]
        $rest = $body.Substring($repoHost.Length + 1)
        $bucket = $rest.Split('/')[0]
        $repoPrefix = $rest.Substring($bucket.Length + 1)
        $region = $cfg.Region
        $stagePrefix = if ($Prefix) { $Prefix } else { $repoPrefix }

        Write-Host "Staging s3://$bucket/$stagePrefix (region $region) for $Days days, tier $Tier..."
        $req = '{"Days":' + $Days + ',"GlacierJobParameters":{"Tier":"' + $Tier + '"}}'
        $requested = 0; $warm = 0
        $keys = (& aws s3api list-objects-v2 --bucket $bucket --prefix $stagePrefix --region $region --query 'Contents[].Key' --output text 2>$null)
        foreach ($key in ($keys -split '\s+' | Where-Object { $_ })) {
            $sc = (& aws s3api head-object --bucket $bucket --key $key --region $region --query 'StorageClass' --output text 2>$null)
            if ($sc -in @('GLACIER', 'DEEP_ARCHIVE', 'GLACIER_IR')) {
                & aws s3api restore-object --bucket $bucket --key $key --region $region --restore-request $req 2>$null
                if ($LASTEXITCODE -eq 0) { $requested++ }
            } else { $warm++ }
        }
        Write-Host "Restore requested for $requested object(s); $warm already warm."
        Write-Host "Glacier retrieval: minutes (Standard) to hours (Bulk/Deep Archive)."
        Write-Host "When warm, run:  .\restore.ps1 restore latest -Target C:\zuruck-restore"
    }
}
