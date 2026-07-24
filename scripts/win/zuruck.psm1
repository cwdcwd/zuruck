<#
  zuruck.psm1 — shared helpers for the Zuruck Windows client scripts.

  Provides config loading, DPAPI-encrypted secret storage, in-process
  environment setup for restic, and small formatting helpers. Imported by
  backup.ps1 / status.ps1 / restore.ps1 / setup.ps1 / install-task.ps1.

  Compatible with Windows PowerShell 5.1 and PowerShell 7 (Windows only).
#>

Set-StrictMode -Version Latest

# Root for config + secrets. Overridable via $env:ZURUCK_HOME (mainly for tests).
function Get-ZuruckRoot {
    if ($env:ZURUCK_HOME) { return $env:ZURUCK_HOME }
    return (Join-Path $env:ProgramData 'zuruck')
}

function Get-ZuruckConfigPath  { Join-Path (Get-ZuruckRoot) 'config.psd1' }
function Get-ZuruckSecretsDir  { Join-Path (Get-ZuruckRoot) 'secrets' }
function Get-ZuruckEntropyPath { Join-Path (Get-ZuruckSecretsDir) 'entropy.bin' }

# ── DPAPI (LocalMachine scope) + entropy ───────────────────────────────────
function Initialize-ZuruckCrypto {
    if (-not ('System.Security.Cryptography.ProtectedData' -as [type])) {
        try { Add-Type -AssemblyName System.Security -ErrorAction Stop } catch { Write-Verbose "$_" }
    }
    if (-not ('System.Security.Cryptography.ProtectedData' -as [type])) {
        throw "DPAPI (System.Security.Cryptography.ProtectedData) is unavailable. Use Windows PowerShell 5.1, or install the System.Security.Cryptography.ProtectedData package for PowerShell 7."
    }
}

function Get-ZuruckEntropy {
    $path = Get-ZuruckEntropyPath
    if (-not (Test-Path $path)) { throw "Entropy file missing ($path). Run setup.ps1 first." }
    return [System.IO.File]::ReadAllBytes($path)
}

# Encrypt a plaintext string to a DPAPI blob file (LocalMachine + entropy).
function Protect-ZuruckSecret {
    param([Parameter(Mandatory)][string]$Plaintext,
          [Parameter(Mandatory)][string]$OutFile,
          [Parameter(Mandatory)][byte[]]$Entropy)
    Initialize-ZuruckCrypto
    $bytes  = [System.Text.Encoding]::UTF8.GetBytes($Plaintext)
    $cipher = [System.Security.Cryptography.ProtectedData]::Protect(
        $bytes, $Entropy, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    [System.IO.File]::WriteAllBytes($OutFile, $cipher)
    # Best-effort scrub of the plaintext byte copy.
    [Array]::Clear($bytes, 0, $bytes.Length)
}

# Decrypt a DPAPI blob file back to a plaintext string.
function Unprotect-ZuruckSecret {
    param([Parameter(Mandatory)][string]$InFile,
          [Parameter(Mandatory)][byte[]]$Entropy)
    Initialize-ZuruckCrypto
    $cipher = [System.IO.File]::ReadAllBytes($InFile)
    $plain  = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $cipher, $Entropy, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    return [System.Text.Encoding]::UTF8.GetString($plain)
}

# ── Config ─────────────────────────────────────────────────────────────────
function Get-ZuruckConfig {
    $path = Get-ZuruckConfigPath
    if (-not (Test-Path $path)) { throw "Config not found ($path). Run setup.ps1 first." }
    $cfg = Import-PowerShellDataFile -Path $path
    foreach ($k in 'ClientName','Repository','Region','AwsAccessKeyId','BackupPaths') {
        if (-not $cfg.ContainsKey($k)) { throw "Config $path is missing required key '$k'." }
    }
    return $cfg
}

# Load config, decrypt secrets, and set restic/AWS env vars for THIS process only.
# Returns the config hashtable.
function Set-ZuruckEnvironment {
    $cfg     = Get-ZuruckConfig
    $entropy = Get-ZuruckEntropy
    $secrets = Get-ZuruckSecretsDir

    $env:RESTIC_REPOSITORY   = $cfg.Repository
    $env:AWS_ACCESS_KEY_ID   = $cfg.AwsAccessKeyId
    $env:AWS_DEFAULT_REGION  = $cfg.Region
    $env:AWS_SECRET_ACCESS_KEY = Unprotect-ZuruckSecret -InFile (Join-Path $secrets 'aws_secret.bin') -Entropy $entropy
    $env:RESTIC_PASSWORD       = Unprotect-ZuruckSecret -InFile (Join-Path $secrets 'restic_pw.bin')  -Entropy $entropy
    # Never leave a plaintext password file around; RESTIC_PASSWORD wins.
    Remove-Item Env:\RESTIC_PASSWORD_FILE -ErrorAction SilentlyContinue
    return $cfg
}

# ── Filesystem ACL: lock a folder to SYSTEM + Administrators only ───────────
function Set-ZuruckAcl {
    param([Parameter(Mandatory)][string]$Path)
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)   # disable inheritance, drop inherited ACEs
    foreach ($id in 'SYSTEM','Administrators') {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $id, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -Path $Path -AclObject $acl
}

# ── restic JSON helpers ────────────────────────────────────────────────────
function Get-ResticSnapshotsJson {
    $raw = & restic snapshots --json 2>$null | Out-String
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    try { return ,([array](ConvertFrom-Json $raw)) } catch { return @() }
}

# restic stats prints progress lines to stdout before the JSON; keep the JSON line.
function Get-ResticStatsJson {
    param([string]$Mode = 'raw-data')
    $line = & restic stats --mode $Mode --json 2>$null | Where-Object { $_ -match '^\{' } | Select-Object -Last 1
    if (-not $line) { return $null }
    try { return ConvertFrom-Json $line } catch { return $null }
}

# Run restic and stream its raw stdout bytes to a file (binary-safe; the PS
# pipeline would re-encode text and corrupt binary). Errors go to the console;
# throws on a non-zero exit. Cross-version (uses ProcessStartInfo.Arguments,
# since ArgumentList is not available on .NET Framework / Windows PowerShell 5.1).
function Invoke-ResticToFile {
    param([Parameter(Mandatory)][string[]]$ResticArgs,
          [Parameter(Mandatory)][string]$OutFile)
    $exe = (Get-Command restic -ErrorAction Stop).Source
    $quote = { param($a) if ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' } else { $a } }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $exe
    $psi.Arguments              = (($ResticArgs | ForEach-Object { & $quote $_ }) -join ' ')
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true    # only stdout; stderr → console (avoids buffer deadlock)
    $p  = [System.Diagnostics.Process]::Start($psi)
    $fs = [System.IO.File]::Create($OutFile)
    try { $p.StandardOutput.BaseStream.CopyTo($fs) } finally { $fs.Dispose() }
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { throw "restic exited $($p.ExitCode) writing $OutFile" }
}

# Run restic with a hard runtime cap. A wedged restic (dead-but-established S3
# connection) would otherwise run forever and block the schedule. Output inherits
# the console (flows to the task log). Returns restic's exit code, or 124 if it
# was killed for exceeding the timeout. Cross-version (ProcessStartInfo.Arguments).
function Invoke-ResticWithTimeout {
    param([Parameter(Mandatory)][string[]]$ResticArgs,
          [int]$TimeoutSeconds = 14400)
    $exe = (Get-Command restic -ErrorAction Stop).Source
    $quote = { param($a) $s = [string]$a; if ($s -match '[\s"]') { '"' + ($s -replace '"', '\"') + '"' } else { $s } }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = $exe
    $psi.Arguments       = (($ResticArgs | ForEach-Object { & $quote $_ }) -join ' ')
    $psi.UseShellExecute = $false      # inherit stdout/stderr → task log
    $p = [System.Diagnostics.Process]::Start($psi)
    if ($TimeoutSeconds -gt 0 -and -not $p.WaitForExit($TimeoutSeconds * 1000)) {
        Write-Warning "[watchdog] restic exceeded ${TimeoutSeconds}s; terminating (pid $($p.Id))."
        try { $p.Kill() } catch { Write-Verbose "$_" }
        Start-Sleep -Seconds 5
        if (-not $p.HasExited) { try { $p.Kill() } catch { Write-Verbose "$_" } }
        return 124
    }
    return $p.ExitCode
}

# ── Formatting ─────────────────────────────────────────────────────────────
function Format-ZuruckBytes {
    param([double]$Bytes = 0)
    $u = 'B','KiB','MiB','GiB','TiB','PiB'; $i = 0
    while ($Bytes -ge 1024 -and $i -lt ($u.Count - 1)) { $Bytes /= 1024; $i++ }
    if ($i -eq 0) { return ('{0:N0} {1}' -f $Bytes, $u[$i]) }
    return ('{0:N2} {1}' -f $Bytes, $u[$i])
}

function Format-ZuruckAge {
    param([double]$Seconds = 0)
    $s = [int]$Seconds
    if     ($s -lt 3600)  { return ('{0}m ago' -f [int]($s / 60)) }
    elseif ($s -lt 86400) { return ('{0}h {1}m ago' -f [int]($s / 3600), [int](($s % 3600) / 60)) }
    else                  { return ('{0}d {1}h ago' -f [int]($s / 86400), [int](($s % 86400) / 3600)) }
}

function ConvertFrom-ResticTime {
    param([Parameter(Mandatory)][string]$Time)   # ISO8601 with offset
    return [System.DateTimeOffset]::Parse($Time, [System.Globalization.CultureInfo]::InvariantCulture)
}

function Test-ZuruckElevated {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

Export-ModuleMember -Function `
    Get-ZuruckRoot, Get-ZuruckConfigPath, Get-ZuruckSecretsDir, Get-ZuruckEntropyPath, `
    Initialize-ZuruckCrypto, Get-ZuruckEntropy, Protect-ZuruckSecret, Unprotect-ZuruckSecret, `
    Get-ZuruckConfig, Set-ZuruckEnvironment, Set-ZuruckAcl, `
    Get-ResticSnapshotsJson, Get-ResticStatsJson, Invoke-ResticToFile, Invoke-ResticWithTimeout, `
    Format-ZuruckBytes, Format-ZuruckAge, ConvertFrom-ResticTime, Test-ZuruckElevated
