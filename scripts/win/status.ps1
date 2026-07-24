<#
.SYNOPSIS
  Zuruck — backup status for Windows (parallel to scripts/status.sh).

.DESCRIPTION
  Shows local backup health: the scheduled task state + last result, whether a
  backup is running, latest snapshot age vs the freshness threshold, repo size,
  and recent snapshots. Terminal by default; -Json for scripting; -Html writes a
  self-contained dashboard.

.EXAMPLE
  .\status.ps1                 # colored terminal summary
  .\status.ps1 -Json
  .\status.ps1 -Html -Open     # write the dashboard and open it
  .\status.ps1 -Threshold 12
#>
[CmdletBinding()]
param(
    [switch]$Json,
    [switch]$Html,
    [string]$HtmlPath,
    [switch]$Open,
    [int]$Threshold,
    [string]$TaskName = 'Zuruck Backup'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'zuruck.psm1') -Force

function prop($o, $n, $d = $null) { if ($o -and $o.PSObject.Properties[$n]) { $o.PSObject.Properties[$n].Value } else { $d } }
function enc($s) { [System.Security.SecurityElement]::Escape([string]$s) }

$cfg = Set-ZuruckEnvironment
if (-not $Threshold) {
    $Threshold = if ($cfg.ContainsKey('FreshnessThresholdHours')) { [int]$cfg.FreshnessThresholdHours } else { 24 }
}
if (-not $HtmlPath) { $HtmlPath = Join-Path (Get-ZuruckRoot) 'status.html' }
$now = [System.DateTimeOffset]::Now
$generated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')

# ── Scheduled task state ───────────────────────────────────────────────────
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
$schedLoaded = [bool]$task
$schedTimes = @(); $lastResult = $null; $nextRun = $null
if ($task) {
    foreach ($tr in $task.Triggers) {
        if ($tr.PSObject.Properties['StartBoundary'] -and $tr.StartBoundary) {
            $schedTimes += ([datetime]::Parse($tr.StartBoundary)).ToString('HH:mm')
        }
    }
    $schedTimes = $schedTimes | Sort-Object -Unique
    $info = $task | Get-ScheduledTaskInfo
    $lastResult = $info.LastTaskResult
    $nextRun = $info.NextRunTime
}

# ── Running? ───────────────────────────────────────────────────────────────
$running = [bool](Get-Process -Name restic -ErrorAction SilentlyContinue)

# ── Repo: snapshots + stats ────────────────────────────────────────────────
$snaps = Get-ResticSnapshotsJson
$stats = Get-ResticStatsJson -Mode 'raw-data'
$repoStored = [double](prop $stats 'total_size' 0)
$repoBlobs  = [long](prop $stats 'total_blob_count' 0)
$snapCount  = $snaps.Count

# Normalize snapshots into flat records (oldest -> newest as restic returns).
$rows = @(foreach ($s in $snaps) {
    $sum = prop $s 'summary'
    [pscustomobject]@{
        ShortId  = prop $s 'short_id'
        Time     = prop $s 'time'
        Tags     = (@(prop $s 'tags' @()) -join ',')
        Added    = [double](prop $sum 'data_added' 0)
        Logical  = [double](prop $sum 'total_bytes_processed' 0)
        Files    = [long](prop $sum 'total_files_processed' 0)
    }
})

$latest = if ($snapCount -gt 0) { $rows[-1] } else { $null }
$latestAge = $null
if ($latest) { $latestAge = ($now - (ConvertFrom-ResticTime $latest.Time)).TotalSeconds }

$verdict =
    if ($running)               { 'running' }
    elseif ($snapCount -eq 0)   { 'none' }
    elseif ($latestAge -le $Threshold * 3600) { 'fresh' }
    else                        { 'stale' }

# ── JSON ───────────────────────────────────────────────────────────────────
if ($Json) {
    [pscustomobject]@{
        generated_at    = $generated
        repository      = $env:RESTIC_REPOSITORY
        verdict         = $verdict
        threshold_hours = $Threshold
        schedule        = [pscustomobject]@{
            installed       = $schedLoaded
            times           = $schedTimes
            last_result     = $lastResult
            next_run        = if ($nextRun) { $nextRun.ToString('o') } else { $null }
        }
        running         = $running
        latest          = if ($latest) { [pscustomobject]@{ short_id = $latest.ShortId; time = $latest.Time; age_seconds = [int]$latestAge } } else { $null }
        repo            = [pscustomobject]@{ stored_bytes = $repoStored; blob_count = $repoBlobs; snapshot_count = $snapCount }
        snapshots       = $rows
    } | ConvertTo-Json -Depth 6
    return
}

# ── Terminal ───────────────────────────────────────────────────────────────
if (-not $Html) {
    $badge, $color = switch ($verdict) {
        'fresh'   { '● FRESH', 'Green' }
        'stale'   { '● STALE', 'Red' }
        'running' { '● RUNNING', 'Cyan' }
        default   { '● NO SNAPSHOTS', 'Yellow' }
    }
    Write-Host "Zuruck backup status  " -NoNewline; Write-Host $badge -ForegroundColor $color
    Write-Host $generated -ForegroundColor DarkGray
    Write-Host ""
    $sched = if ($schedLoaded) {
        $t = "installed"
        if ($schedTimes) { $t += ", daily at $($schedTimes -join ' ')" }
        if ($null -ne $lastResult) { $t += ", last result $lastResult" }
        $t
    } else { "not installed" }
    Write-Host ("  {0,-12} {1}" -f 'Schedule:', $sched)
    Write-Host ("  {0,-12} {1}" -f 'Running:', $(if ($running) { 'yes' } else { 'no' }))
    if ($latest) {
        Write-Host ("  {0,-12} latest {1} ({2}), threshold {3}h" -f 'Freshness:', $latest.ShortId, (Format-ZuruckAge $latestAge), $Threshold)
    } else {
        Write-Host ("  {0,-12} no snapshots found" -f 'Freshness:')
    }
    Write-Host ("  {0,-12} {1} stored, {2} snapshots, {3} blobs" -f 'Repository:', (Format-ZuruckBytes $repoStored), $snapCount, $repoBlobs)
    Write-Host ""
    if ($snapCount -gt 0) {
        Write-Host "  Recent snapshots"
        Write-Host ("  {0,-10} {1,-19} {2,-10} {3,10} {4,10}" -f 'id', 'when', 'tags', 'uploaded', 'logical') -ForegroundColor DarkGray
        foreach ($r in ($rows[($rows.Count - 1)..0] | Select-Object -First 10)) {
            $when = ($r.Time -replace '\..*$', '') -replace 'T', ' '
            Write-Host ("  {0,-10} {1,-19} {2,-10} {3,10} {4,10}" -f $r.ShortId, $when.Substring(0, [Math]::Min(19, $when.Length)), $r.Tags, (Format-ZuruckBytes $r.Added), (Format-ZuruckBytes $r.Logical))
        }
    }
    return
}

# ── HTML dashboard (self-contained, theme-aware — mirrors status.sh) ───────
$maxAdd = 1; foreach ($r in $rows) { if ($r.Added -gt $maxAdd) { $maxAdd = $r.Added } }
$vlabel, $vclass = switch ($verdict) {
    'fresh'   { 'Fresh', 'ok' }
    'stale'   { 'Stale', 'bad' }
    'running' { 'Backing up…', 'run' }
    default   { 'No snapshots', 'warn' }
}
$gaugePct = 0
if ($null -ne $latestAge) { $gaugePct = [Math]::Min(100, [int](($latestAge / ($Threshold * 3600)) * 100)) }
$latestAgeDisp = if ($null -ne $latestAge) { Format-ZuruckAge $latestAge } else { '—' }

$bars = ''; $tableRows = ''
$recent = if ($rows.Count -gt 0) { $rows[($rows.Count - 1)..0] } else { @() }
foreach ($r in $recent) {
    $when = (($r.Time -replace '\..*$', '') -replace 'T', ' ')
    $when = $when.Substring(0, [Math]::Min(19, $when.Length))
    $age = if ($r.Time) { Format-ZuruckAge (($now - (ConvertFrom-ResticTime $r.Time)).TotalSeconds) } else { '' }
    $wpct = if ($maxAdd -gt 0) { [Math]::Round(($r.Added / $maxAdd) * 100, 1) } else { 0 }
    $bars += "<div class=bar-row><div class=bar-label>$(enc $when.Substring(5))</div><div class=bar-track><div class=bar-fill style=`"width:$wpct%`"></div></div><div class=bar-val>$(Format-ZuruckBytes $r.Added)</div></div>"
    $tableRows += "<tr><td class=mono>$(enc $r.ShortId)</td><td>$(enc $when)</td><td>$(enc $age)</td><td><span class=tag>$(enc $r.Tags)</span></td><td class=num>$(Format-ZuruckBytes $r.Added)</td><td class=num>$(Format-ZuruckBytes $r.Logical)</td><td class=num>$($r.Files)</td></tr>"
}
if (-not $bars) { $bars = '<div class=repo>No snapshots yet.</div>' }
if (-not $tableRows) { $tableRows = '<tr><td colspan=7 class=repo>No snapshots yet.</td></tr>' }

$schedDisp = if ($schedLoaded) { if ($schedTimes) { "daily at $($schedTimes -join ' ')" } else { 'installed' } } else { '—' }
$lastResultDisp = if ($null -ne $lastResult) { " · last result $lastResult" } else { '' }

$html = @"
<!doctype html>
<html lang=en>
<head>
<meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>Zuruck backup status</title>
<style>
  :root{--bg:#f6f7f9;--card:#fff;--fg:#1a1d21;--muted:#5c636e;--line:#e3e6ea;
        --ok:#1a7f37;--bad:#cf222e;--warn:#9a6700;--run:#0969da;--accent:#0969da;--bar:#0969da33;--barfill:#0969da}
  @media (prefers-color-scheme:dark){:root{--bg:#0d1117;--card:#161b22;--fg:#e6edf3;--muted:#9198a1;--line:#30363d;
        --ok:#3fb950;--bad:#f85149;--warn:#d29922;--run:#58a6ff;--accent:#58a6ff;--bar:#58a6ff22;--barfill:#58a6ff}}
  :root[data-theme=dark]{--bg:#0d1117;--card:#161b22;--fg:#e6edf3;--muted:#9198a1;--line:#30363d;
        --ok:#3fb950;--bad:#f85149;--warn:#d29922;--run:#58a6ff;--accent:#58a6ff;--bar:#58a6ff22;--barfill:#58a6ff}
  :root[data-theme=light]{--bg:#f6f7f9;--card:#fff;--fg:#1a1d21;--muted:#5c636e;--line:#e3e6ea;
        --ok:#1a7f37;--bad:#cf222e;--warn:#9a6700;--run:#0969da;--accent:#0969da;--bar:#0969da33;--barfill:#0969da}
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif}
  .wrap{max-width:920px;margin:0 auto;padding:28px 20px 48px}
  h1{font-size:20px;margin:0 0 2px}
  .sub{color:var(--muted);font-size:13px;margin-bottom:22px}
  .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:14px;margin-bottom:22px}
  .card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px}
  .card .k{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.04em}
  .card .v{font-size:22px;font-weight:600;margin-top:6px}
  .badge{display:inline-flex;align-items:center;gap:7px;font-weight:600;padding:5px 12px;border-radius:999px;font-size:14px;background:color-mix(in srgb,currentColor 12%,transparent)}
  .badge::before{content:"";width:9px;height:9px;border-radius:50%}
  .ok{color:var(--ok)}.ok::before{background:var(--ok)}
  .bad{color:var(--bad)}.bad::before{background:var(--bad)}
  .warn{color:var(--warn)}.warn::before{background:var(--warn)}
  .run{color:var(--run)}.run::before{background:var(--run);animation:pulse 1.4s infinite}
  @keyframes pulse{0%,100%{opacity:1}50%{opacity:.3}}
  .gauge{height:10px;background:var(--line);border-radius:999px;overflow:hidden;margin-top:10px}
  .gauge>div{height:100%;border-radius:999px;background:var(--accent)}
  h2{font-size:14px;text-transform:uppercase;letter-spacing:.04em;color:var(--muted);margin:26px 0 12px}
  .bar-row{display:grid;grid-template-columns:110px 1fr 90px;align-items:center;gap:12px;margin:6px 0;font-size:13px}
  .bar-label{color:var(--muted)}
  .bar-track{background:var(--bar);border-radius:6px;height:18px;overflow:hidden}
  .bar-fill{height:100%;background:var(--barfill);border-radius:6px;min-width:2px}
  .bar-val{text-align:right;color:var(--muted);font-variant-numeric:tabular-nums}
  table{width:100%;border-collapse:collapse;font-size:13px}
  th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--line)}
  th{color:var(--muted);font-weight:600;text-transform:uppercase;font-size:11px;letter-spacing:.04em}
  td.num,th.num{text-align:right;font-variant-numeric:tabular-nums}
  .mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
  .tag{background:color-mix(in srgb,var(--accent) 14%,transparent);color:var(--accent);padding:2px 8px;border-radius:6px;font-size:12px}
  .scroll{overflow-x:auto}
  .repo{color:var(--muted);font-size:12px;word-break:break-all;margin-top:6px}
  .foot{color:var(--muted);font-size:12px;margin-top:28px}
</style>
</head>
<body>
<div class=wrap>
  <h1>Zuruck backup status</h1>
  <div class=sub>Generated $generated</div>
  <div style="margin-bottom:20px"><span class="badge $vclass">$vlabel</span></div>
  <div class=grid>
    <div class=card><div class=k>Freshness</div><div class=v>$latestAgeDisp</div>
      <div class=gauge><div style="width:$gaugePct%"></div></div>
      <div class=repo>within ${Threshold}h window</div></div>
    <div class=card><div class=k>Schedule</div><div class=v>$(if ($schedLoaded) { 'Installed' } else { 'Off' })</div>
      <div class=repo>$schedDisp$lastResultDisp</div></div>
    <div class=card><div class=k>Repo size</div><div class=v>$(Format-ZuruckBytes $repoStored)</div>
      <div class=repo>$repoBlobs blobs</div></div>
    <div class=card><div class=k>Snapshots</div><div class=v>$snapCount</div>
      <div class=repo>$(if ($running) { 'backing up now' } else { 'idle' })</div></div>
  </div>
  <h2>Data uploaded per snapshot</h2>
  $bars
  <h2>Recent snapshots</h2>
  <div class=scroll><table>
    <thead><tr><th>ID</th><th>When</th><th>Age</th><th>Tags</th><th class=num>Uploaded</th><th class=num>Logical</th><th class=num>Files</th></tr></thead>
    <tbody>$tableRows</tbody>
  </table></div>
  <div class=repo style="margin-top:20px">Repository: <span class=mono>$(enc $env:RESTIC_REPOSITORY)</span></div>
  <div class=foot>Static snapshot — re-run <span class=mono>status.ps1 -Html</span> to refresh.</div>
</div>
</body>
</html>
"@

New-Item -ItemType Directory -Force -Path (Split-Path $HtmlPath) | Out-Null
Set-Content -Path $HtmlPath -Value $html -Encoding UTF8
Write-Host "Wrote dashboard: $HtmlPath"
if ($Open) { Start-Process $HtmlPath }
