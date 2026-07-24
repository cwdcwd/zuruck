<#
.SYNOPSIS
  Zuruck — install the scheduled backup task on Windows (parallel to install-schedule.sh).

.DESCRIPTION
  Registers a Scheduled Task that runs backup.ps1 as SYSTEM with highest
  privileges (so VSS works) at fixed daily times. Uses StartWhenAvailable so a
  run missed while the machine was asleep fires on the next wake — the Windows
  answer to the launchd sleep gap.

.EXAMPLE
  .\install-task.ps1                 # every 4h (00/04/08/12/16/20), as SYSTEM
  .\install-task.ps1 -EveryHours 6   # every 6h
  .\install-task.ps1 -Wake           # also wake the machine to run
  .\install-task.ps1 -Status
  .\install-task.ps1 -Uninstall
  .\install-task.ps1 -Print          # show what would be registered
#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [ValidateRange(1, 24)][int]$EveryHours = 4,
    [string]$TaskName = 'Zuruck Backup',
    [switch]$Wake,
    [Parameter(ParameterSetName = 'Status')][switch]$Status,
    [Parameter(ParameterSetName = 'Uninstall')][switch]$Uninstall,
    [Parameter(ParameterSetName = 'Print')][switch]$Print
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'zuruck.psm1') -Force

$backup = Join-Path $PSScriptRoot 'backup.ps1'
$psCmd  = Get-Command powershell.exe -ErrorAction SilentlyContinue
$psExe  = if ($psCmd) { $psCmd.Source } else { "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
$argLine = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$backup`" -Forget -Tag scheduled"

# ── Status ─────────────────────────────────────────────────────────────────
if ($Status) {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) { Write-Host "Task '$TaskName': not installed"; return }
    $info = $t | Get-ScheduledTaskInfo
    Write-Host "Task:        $TaskName"
    Write-Host "State:       $($t.State)"
    Write-Host "Last run:    $($info.LastRunTime)"
    Write-Host "Last result: $($info.LastTaskResult)  (0 = success; 267009 = running; 267011 = never run)"
    Write-Host "Next run:    $($info.NextRunTime)"
    Write-Host "Runs as:     $($t.Principal.UserId) (RunLevel $($t.Principal.RunLevel))"
    return
}

# ── Uninstall ──────────────────────────────────────────────────────────────
if ($Uninstall) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Removed task '$TaskName'."
    } else { Write-Host "Task '$TaskName' not present." }
    return
}

# ── Build task components ──────────────────────────────────────────────────
$hours = 0..23 | Where-Object { $_ % $EveryHours -eq 0 }
$triggers = foreach ($h in $hours) { New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.AddHours($h)) }

$action    = New-ScheduledTaskAction -Execute $psExe -Argument $argLine -WorkingDirectory $PSScriptRoot
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 6) `
    -RestartCount 2 -RestartInterval (New-TimeSpan -Minutes 10)
if ($Wake) { $settings.WakeToRun = $true }

$times = ($hours | ForEach-Object { '{0:00}:00' -f $_ }) -join ' '

# ── Print (don't register) ─────────────────────────────────────────────────
if ($Print) {
    Write-Host "Task:      $TaskName"
    Write-Host "Runs:      $psExe $argLine"
    Write-Host "As:        SYSTEM (highest privileges)"
    Write-Host "Daily at:  $times"
    Write-Host "Settings:  StartWhenAvailable, IgnoreNew, batteries-ok$(if ($Wake) { ', WakeToRun' })"
    return
}

# ── Register ───────────────────────────────────────────────────────────────
if (-not (Test-ZuruckElevated)) {
    throw "install-task.ps1 must run elevated (Run as Administrator) to register a SYSTEM task."
}
if (-not (Test-Path $backup)) { throw "backup.ps1 not found next to this script ($backup)." }
try { Get-ZuruckConfig | Out-Null } catch { throw "No config found — run setup.ps1 before installing the schedule. ($_)" }

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers `
    -Principal $principal -Settings $settings -Force `
    -Description "Zuruck restic backup (every ${EveryHours}h)" | Out-Null

Write-Host "Installed task '$TaskName': daily at $times, runs as SYSTEM (VSS-capable)."
Write-Host "  script: $backup -Forget -Tag scheduled"
Write-Host ""
Write-Host "Run once now:  Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "Check it:      .\install-task.ps1 -Status"
Write-Host "Remove it:     .\install-task.ps1 -Uninstall"
Write-Host ""
Write-Host "Note: runs missed while asleep fire on the next wake (StartWhenAvailable)."
