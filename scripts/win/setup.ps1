<#
.SYNOPSIS
  Zuruck — configure a Windows client (parallel to scripts/client-setup.sh).

.DESCRIPTION
  Stores AWS + restic credentials encrypted with DPAPI (LocalMachine scope +
  an ACL-locked entropy file) under %ProgramData%\zuruck, writes config.psd1,
  and (unless -SkipInit) initializes the client's restic repository with the
  master password and adds a machine-local client key.

  Run in an elevated PowerShell (writes to %ProgramData% and sets ACLs). Run it
  AS THE USER whose folders you want backed up, or pass -BackupPath explicitly —
  the default path set is resolved from the invoking user's known folders.

.EXAMPLE
  .\setup.ps1 -ClientName fenster02 -Bucket zuruck-backup-<acct>-us-west-2 `
              -AccessKeyId AKIA... -InstallRestic
  # prompts for the AWS secret and the SSM master password
#>
[CmdletBinding()]
param(
    [string]$ClientName = 'fenster02',
    [Parameter(Mandatory)][string]$Bucket,
    [string]$Region = 'us-west-2',
    [Parameter(Mandatory)][string]$AccessKeyId,
    [string]$SecretAccessKey,                 # prompted (secure) if omitted
    [string]$MasterPassword,                  # SSM master pw; prompted if omitted (unless -SkipInit)
    [string[]]$BackupPath,
    [switch]$InstallRestic,
    [switch]$SkipInit,
    [switch]$RotateClientPassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'zuruck.psm1') -Force

if (-not (Test-ZuruckElevated)) {
    throw "setup.ps1 must run elevated (Run as Administrator) — it writes to %ProgramData% and sets ACLs."
}
if ($ClientName -notmatch '^[a-z][a-z0-9-]{1,32}$') {
    throw "Invalid -ClientName '$ClientName': must match ^[a-z][a-z0-9-]{1,32}$ (used in the S3 prefix and IAM/SSM names)."
}

function ConvertTo-PlainText([Security.SecureString]$Secure) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

if (-not $SecretAccessKey) {
    $SecretAccessKey = ConvertTo-PlainText (Read-Host "AWS secret access key for $ClientName" -AsSecureString)
}
if (-not $SkipInit -and -not $MasterPassword) {
    $MasterPassword = ConvertTo-PlainText (Read-Host "restic MASTER password (from SSM /zuruck/restic/$ClientName/master-password)" -AsSecureString)
}

$repo    = "s3:s3.$Region.amazonaws.com/$Bucket/$ClientName"
$root    = Get-ZuruckRoot
$secrets = Get-ZuruckSecretsDir

# ── Optionally install restic ──────────────────────────────────────────────
if ($InstallRestic -and -not (Get-Command restic -ErrorAction SilentlyContinue)) {
    Write-Host "==> Installing restic via winget..."
    winget install --id restic.restic --accept-source-agreements --accept-package-agreements
}
if (-not (Get-Command restic -ErrorAction SilentlyContinue)) {
    throw "restic.exe not found on PATH. Install it (winget install restic.restic) or re-run with -InstallRestic."
}

# ── Create + lock down the config/secret store ─────────────────────────────
New-Item -ItemType Directory -Force -Path $secrets | Out-Null
Set-ZuruckAcl -Path $root
Set-ZuruckAcl -Path $secrets

# Entropy: generate once and reuse (regenerating would orphan existing blobs).
$entropyPath = Get-ZuruckEntropyPath
if (-not (Test-Path $entropyPath)) {
    $e = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($e)
    [System.IO.File]::WriteAllBytes($entropyPath, $e)
}
$entropy = Get-ZuruckEntropy

# ── Client restic password: reuse existing unless rotating ─────────────────
$clientPwFile = Join-Path $secrets 'restic_pw.bin'
if ((Test-Path $clientPwFile) -and -not $RotateClientPassword) {
    $clientPw = Unprotect-ZuruckSecret -InFile $clientPwFile -Entropy $entropy
    Write-Host "==> Reusing existing client password."
} else {
    $pwBytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($pwBytes)
    $clientPw = [Convert]::ToBase64String($pwBytes)
    Protect-ZuruckSecret -Plaintext $clientPw -OutFile $clientPwFile -Entropy $entropy
    Write-Host "==> Generated a new client password."
}

# ── Encrypt the AWS secret ─────────────────────────────────────────────────
Protect-ZuruckSecret -Plaintext $SecretAccessKey -OutFile (Join-Path $secrets 'aws_secret.bin') -Entropy $entropy

# ── Default backup paths (invoking user's known folders) ───────────────────
if (-not $BackupPath) {
    $BackupPath = @(
        [Environment]::GetFolderPath('Desktop')
        [Environment]::GetFolderPath('MyDocuments')
        [Environment]::GetFolderPath('MyPictures')
        [Environment]::GetFolderPath('MyMusic')
        [Environment]::GetFolderPath('MyVideos')
        [Environment]::GetFolderPath('Favorites')
        (Join-Path $env:USERPROFILE '.ssh')
        (Join-Path $env:USERPROFILE '.aws')
        (Join-Path $env:USERPROFILE '.gitconfig')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
}

# ── Write config.psd1 ──────────────────────────────────────────────────────
$q = { param($s) "'" + ($s -replace "'", "''") + "'" }
$pathsLiteral = ($BackupPath | ForEach-Object { '        ' + (& $q $_) }) -join ",`r`n"
$configPath = Get-ZuruckConfigPath
$configText = @"
@{
    ClientName              = $(& $q $ClientName)
    Repository              = $(& $q $repo)
    Region                  = $(& $q $Region)
    AwsAccessKeyId          = $(& $q $AccessKeyId)
    ExcludeFile             = $(& $q (Join-Path $PSScriptRoot 'restic-excludes.txt'))
    FreshnessThresholdHours = 48
    UseVss                  = `$true
    S3Connections           = 0        # 0 = restic default (5); lower (e.g. 2) for flaky links
    NetWaitTries            = 12       # wait up to 12x5s for S3 to answer after wake
    SkipNetWait             = `$false
    MaxRuntimeSeconds       = 14400    # kill a wedged restic after 4h; raise for a slow initial seed
    KeepDaily               = 7
    KeepWeekly              = 4
    KeepMonthly             = 6
    KeepYearly              = 2
    BackupPaths             = @(
$pathsLiteral
    )
}
"@
Set-Content -Path $configPath -Value $configText -Encoding UTF8

# ── Initialize the repository + add the client key (uses master password) ──
if (-not $SkipInit) {
    $env:RESTIC_REPOSITORY     = $repo
    $env:AWS_ACCESS_KEY_ID     = $AccessKeyId
    $env:AWS_SECRET_ACCESS_KEY = $SecretAccessKey
    $env:AWS_DEFAULT_REGION    = $Region

    # Is the repo already initialized? (open it with the master password.)
    $env:RESTIC_PASSWORD = $MasterPassword
    & restic cat config *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "==> Initializing repository $repo"
        & restic init
        if ($LASTEXITCODE -ne 0) { throw "restic init failed." }
    } else {
        Write-Host "==> Repository already initialized."
    }

    # Does the client password already open it? If not, add the client key.
    $env:RESTIC_PASSWORD = $clientPw
    & restic cat config *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "==> Adding client key."
        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            [System.IO.File]::WriteAllText($tmp, $clientPw)
            $env:RESTIC_PASSWORD = $MasterPassword
            & restic key add --new-password-file $tmp
            if ($LASTEXITCODE -ne 0) { throw "restic key add failed." }
        } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
}

# ── Verify the client password opens the repo ──────────────────────────────
$null = Set-ZuruckEnvironment
& restic snapshots *> $null
$ok = ($LASTEXITCODE -eq 0)

# Scrub plaintext secrets from this process.
$SecretAccessKey = $null; $MasterPassword = $null; $clientPw = $null
Remove-Item Env:\RESTIC_PASSWORD, Env:\AWS_SECRET_ACCESS_KEY -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Zuruck configured for '$ClientName'."
Write-Host "  config:  $configPath"
Write-Host "  secrets: $secrets  (DPAPI LocalMachine + entropy, ACL: SYSTEM/Administrators)"
Write-Host "  repo:    $repo"
Write-Host "  client password opens repo: $(if ($ok) { 'yes' } else { 'NO — check credentials/key' })"
Write-Host ""
Write-Host "Next:"
Write-Host "  .\backup.ps1                 # first backup (run elevated for VSS)"
Write-Host "  .\install-task.ps1           # schedule it (SYSTEM, every 4h)"
Write-Host "  .\status.ps1                 # check health"
