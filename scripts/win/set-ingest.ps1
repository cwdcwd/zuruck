<#
.SYNOPSIS
  Zuruck — configure (or rotate) collector reporting on a Windows client
  (parallel to scripts/set-ingest.sh).

.DESCRIPTION
  Stores the ingest token DPAPI-encrypted (LocalMachine + entropy) in the
  secrets folder and the collector URL in ingest.psd1, both under
  %ProgramData%\zuruck. backup.ps1 then POSTs a status report after every run.
  The token is read from $env:ZURUCK_INGEST_TOKEN or a hidden prompt — never
  from a parameter. Run elevated (the secrets folder is SYSTEM/Administrators only).

.EXAMPLE
  .\set-ingest.ps1 -Url http://collector.lan:8790/api/ingest          # prompts for the token
  .\set-ingest.ps1 -Url http://collector.lan:8790/api/ingest -Test    # also send one report now
  .\set-ingest.ps1 -Disable
#>
[CmdletBinding()]
param(
    [string]$Url,
    [switch]$Test,
    [switch]$Disable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'zuruck.psm1') -Force

if (-not (Test-ZuruckElevated)) { throw "Run elevated (Administrator): the secrets folder is SYSTEM/Administrators only." }

$cfgPath   = Get-ZuruckIngestConfigPath
$tokenPath = Get-ZuruckIngestTokenPath

if ($Disable) {
    Remove-Item -LiteralPath $cfgPath, $tokenPath -ErrorAction SilentlyContinue
    Write-Host "==> Collector reporting disabled."
    exit 0
}

if (-not $Url) { throw "-Url is required." }
if ($Url -notmatch '^https?://[^\s''"`$]+$') { throw "-Url must be a plain http(s) URL." }

$token = $env:ZURUCK_INGEST_TOKEN
if (-not $token) {
    $sec  = Read-Host -AsSecureString 'Ingest token (input hidden)'
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try     { $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
if (-not $token) { throw "Empty token." }

Protect-ZuruckSecret -Plaintext $token -OutFile $tokenPath -Entropy (Get-ZuruckEntropy)
$token = $null
Set-Content -LiteralPath $cfgPath -Encoding UTF8 -Value ("@{{`r`n    Url = '{0}'`r`n}}" -f ($Url -replace "'", "''"))
Write-Host "==> Reporting to $Url (token DPAPI-encrypted at $tokenPath)"

if ($Test) {
    Send-ZuruckReport -StatusScript (Join-Path $PSScriptRoot 'status.ps1')
}
