#!/usr/bin/env bash
#
# Zuruck — backup status
#
# Shows local backup health at a glance: whether the launchd schedule is loaded
# and running, when the last snapshot landed, whether that's within the freshness
# threshold, repo size, and a recent-snapshot history.
#
# Usage:
#   ./scripts/status.sh                      # colored terminal summary
#   ./scripts/status.sh --json               # machine-readable JSON
#   ./scripts/status.sh --html [PATH]        # write a self-contained HTML dashboard
#                                            # (default ~/Library/Logs/zuruck-status.html)
#   ./scripts/status.sh --html --open        # write it and open in the browser
#   ./scripts/status.sh --threshold 12       # freshness window in hours (default 24)
#
# Reads the same client env as backup.sh (/etc/restic/env or $RESTIC_ENV_FILE).
# All restic calls are read-only and safe to run during a backup.
#
set -euo pipefail

# Needs bash >= 4 (mapfile, negative array indices). macOS ships 3.2 at /bin/bash,
# so re-exec under a newer bash if we were launched with the old one.
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -x "$b" ] && exec "$b" "$0" "$@"
  done
  echo "ERROR: status.sh needs bash >= 4 (found ${BASH_VERSION:-unknown}); install via 'brew install bash'." >&2
  exit 1
fi

MODE="terminal"
HTML_PATH=""
OPEN_HTML=false
THRESHOLD_HOURS="${ZURUCK_FRESHNESS_HOURS:-24}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)      MODE="json"; shift ;;
    --html)      MODE="html"; shift
                 if [[ $# -gt 0 && "$1" != --* ]]; then HTML_PATH="$1"; shift; fi ;;
    --open)      OPEN_HTML=true; shift ;;
    --threshold) THRESHOLD_HOURS="$2"; shift 2 ;;
    -h|--help)   sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${RESTIC_ENV_FILE:-/etc/restic/env}"
LABEL="com.zuruck.backup"
DOMAIN="gui/$(id -u)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/zuruck-backup.log"
[[ -z "$HTML_PATH" ]] && HTML_PATH="$HOME/Library/Logs/zuruck-status.html"

# ── Load the client environment ───────────────────────────────────────────
[[ -r "$ENV_FILE" ]] || { echo "ERROR: cannot read $ENV_FILE — run client-setup.sh first." >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"
: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY not set in $ENV_FILE}"

# ── Small helpers ──────────────────────────────────────────────────────────
human() { awk -v b="${1:-0}" 'BEGIN{u="B KiB MiB GiB TiB PiB";n=split(u,a," ");i=1;while(b>=1024&&i<n){b/=1024;i++}printf((i==1)?"%d %s":"%.2f %s"),b,a[i]}'; }
fmt_age() { local s=${1:-0}
  if   (( s < 3600 ));  then echo "$((s/60))m ago"
  elif (( s < 86400 )); then echo "$((s/3600))h $(((s%3600)/60))m ago"
  else echo "$((s/86400))d $(((s%86400)/3600))h ago"; fi; }
# restic emits local ISO8601 (fractional seconds + tz offset); strip both, parse as local.
iso_to_epoch() {
  local t; t="$(printf '%s' "$1" | sed -E 's/\.[0-9]+//; s/([+-][0-9]{2}):?[0-9]{2}$//; s/Z$//')"
  date -j -f "%Y-%m-%dT%H:%M:%S" "$t" +%s 2>/dev/null || echo 0
}

NOW_EPOCH="$(date +%s)"
GENERATED="$(date '+%Y-%m-%d %H:%M:%S %Z')"

# ── Schedule state (launchd) ───────────────────────────────────────────────
SCHED_LOADED="no"; SCHED_PID=""; SCHED_LAST_EXIT=""; EVERY_HOURS=""
if PRINT="$(launchctl print "$DOMAIN/$LABEL" 2>/dev/null)"; then
  SCHED_LOADED="yes"
  SCHED_PID="$(printf '%s\n' "$PRINT" | awk -F'= ' '/^[[:space:]]*pid =/{print $2; exit}')"
  SCHED_LAST_EXIT="$(printf '%s\n' "$PRINT" | awk -F'= ' '/last exit code =/{print $2; exit}')"
fi
if [[ -f "$PLIST" ]]; then
  secs="$(plutil -extract StartInterval raw "$PLIST" 2>/dev/null || echo "")"
  [[ "$secs" =~ ^[0-9]+$ ]] && EVERY_HOURS="$(( secs / 3600 ))"
fi

# ── Live run? ──────────────────────────────────────────────────────────────
RUNNING="no"; RUNNING_PIDS=""
if RUNNING_PIDS="$(pgrep -f 'zuruck-runner|restic backup' 2>/dev/null | paste -sd, -)"; then
  [[ -n "$RUNNING_PIDS" ]] && RUNNING="yes"
fi

# ── Repo: snapshots + stats (read-only) ────────────────────────────────────
SNAP_JSON="$(restic snapshots --json 2>/dev/null || echo '[]')"
[[ -z "$SNAP_JSON" ]] && SNAP_JSON='[]'
STATS_JSON="$(restic stats --mode raw-data --json 2>/dev/null | grep -E '^\{' | tail -1 || true)"
[[ -z "$STATS_JSON" ]] && STATS_JSON='{}'

REPO_STORED="$(printf '%s' "$STATS_JSON" | jq -r '.total_size // 0')"
REPO_BLOBS="$(printf '%s' "$STATS_JSON" | jq -r '.total_blob_count // 0')"
SNAP_COUNT="$(printf '%s' "$SNAP_JSON" | jq 'length')"

# Per-snapshot rows (oldest→newest as restic returns): id, iso, tags, data_added, bytes_processed, files
mapfile -t SNAP_ROWS < <(printf '%s' "$SNAP_JSON" | jq -r '
  .[] | [ .short_id, .time, ((.tags // []) | join(",")),
          (.summary.data_added // 0), (.summary.total_bytes_processed // 0),
          (.summary.total_files_processed // 0) ] | @tsv')

# Latest snapshot age + verdict
LATEST_ID=""; LATEST_ISO=""; LATEST_AGE_SECS=""; VERDICT="none"
if (( SNAP_COUNT > 0 )); then
  IFS=$'\t' read -r LATEST_ID LATEST_ISO _ _ _ _ <<<"${SNAP_ROWS[-1]}"
  le="$(iso_to_epoch "$LATEST_ISO")"
  if (( le > 0 )); then LATEST_AGE_SECS=$(( NOW_EPOCH - le )); fi
fi
if [[ "$RUNNING" == "yes" ]]; then VERDICT="running"
elif (( SNAP_COUNT == 0 )); then VERDICT="none"
elif [[ -n "$LATEST_AGE_SECS" ]] && (( LATEST_AGE_SECS <= THRESHOLD_HOURS * 3600 )); then VERDICT="fresh"
else VERDICT="stale"; fi

# ── JSON output ────────────────────────────────────────────────────────────
nn() { [[ -n "${1:-}" ]] && printf '%s' "$1" || printf 'null'; }  # numeric-or-null for --argjson
build_json() {
  printf '%s' "$SNAP_JSON" | jq \
    --arg generated "$GENERATED" \
    --arg repo "$RESTIC_REPOSITORY" \
    --arg verdict "$VERDICT" \
    --argjson threshold "$THRESHOLD_HOURS" \
    --arg loaded "$SCHED_LOADED" \
    --arg running "$RUNNING" \
    --arg pids "$RUNNING_PIDS" \
    --argjson schedpid "$(nn "${SCHED_PID:-}")" \
    --argjson lastexit "$(nn "${SCHED_LAST_EXIT:-}")" \
    --argjson every "$(nn "${EVERY_HOURS:-}")" \
    --arg latestid "${LATEST_ID:-}" \
    --arg latestiso "${LATEST_ISO:-}" \
    --argjson lateage "$(nn "${LATEST_AGE_SECS:-}")" \
    --argjson stored "$REPO_STORED" \
    --argjson blobs "$REPO_BLOBS" '
    {
      generated_at: $generated,
      repository: $repo,
      verdict: $verdict,
      threshold_hours: $threshold,
      schedule: { loaded: ($loaded=="yes"), every_hours: $every, pid: $schedpid, last_exit_code: $lastexit },
      running: ($running=="yes"),
      running_pids: (if $pids=="" then [] else ($pids|split(",")) end),
      latest: (if $latestid=="" then null else { short_id: $latestid, time: $latestiso, age_seconds: $lateage } end),
      repo: { stored_bytes: $stored, blob_count: $blobs, snapshot_count: (. | length) },
      snapshots: [ .[] | {
        short_id, time, tags: (.tags // []),
        data_added: (.summary.data_added // 0),
        bytes_processed: (.summary.total_bytes_processed // 0),
        files: (.summary.total_files_processed // 0)
      } ]
    }'
}

if [[ "$MODE" == "json" ]]; then build_json; exit 0; fi

# ── Terminal output ────────────────────────────────────────────────────────
if [[ "$MODE" == "terminal" ]]; then
  if [[ -t 1 ]]; then
    B=$'\033[1m'; D=$'\033[2m'; R=$'\033[0m'
    GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; CYN=$'\033[36m'
  else B=""; D=""; R=""; GRN=""; YEL=""; RED=""; CYN=""; fi

  case "$VERDICT" in
    fresh)   badge="${GRN}● FRESH${R}" ;;
    stale)   badge="${RED}● STALE${R}" ;;
    running) badge="${CYN}● RUNNING${R}" ;;
    *)       badge="${YEL}● NO SNAPSHOTS${R}" ;;
  esac

  echo "${B}Zuruck backup status${R}  $badge"
  echo "${D}$GENERATED${R}"
  echo
  # Schedule line
  sched="not loaded"
  if [[ "$SCHED_LOADED" == "yes" ]]; then
    sched="loaded"
    [[ -n "$EVERY_HOURS" ]] && sched+=", every ${EVERY_HOURS}h"
    [[ -n "$SCHED_LAST_EXIT" ]] && sched+=", last exit ${SCHED_LAST_EXIT}"
  fi
  printf "  %-12s %s\n" "Schedule:" "$sched"
  if [[ "$RUNNING" == "yes" ]]; then
    printf "  %-12s ${CYN}yes${R} (pid %s)\n" "Running:" "$RUNNING_PIDS"
  else
    printf "  %-12s no\n" "Running:"
  fi
  # Freshness line
  if (( SNAP_COUNT > 0 )) && [[ -n "$LATEST_AGE_SECS" ]]; then
    printf "  %-12s latest %s ($(fmt_age "$LATEST_AGE_SECS")), threshold ${THRESHOLD_HOURS}h\n" "Freshness:" "$LATEST_ID"
  else
    printf "  %-12s no snapshots found\n" "Freshness:"
  fi
  printf "  %-12s %s stored, %s snapshots, %s blobs\n" "Repository:" "$(human "$REPO_STORED")" "$SNAP_COUNT" "$REPO_BLOBS"
  echo
  # Recent snapshots (newest first, up to 10)
  if (( SNAP_COUNT > 0 )); then
    echo "  ${B}Recent snapshots${R}"
    printf "  ${D}%-10s %-19s %-10s %10s %10s${R}\n" "id" "when" "tags" "uploaded" "logical"
    for (( i=${#SNAP_ROWS[@]}-1, n=0; i>=0 && n<10; i--, n++ )); do
      IFS=$'\t' read -r sid siso stags sadded sbytes _ <<<"${SNAP_ROWS[i]}"
      se="$(iso_to_epoch "$siso")"; when="${siso%.*}"; when="${when:0:19}"
      printf "  %-10s %-19s %-10s %10s %10s\n" "$sid" "${when/T/ }" "${stags:0:10}" "$(human "$sadded")" "$(human "$sbytes")"
    done
  fi
  echo
  # Last log lines
  if [[ -f "$LOG" ]]; then
    echo "  ${B}Last log${R} ${D}($LOG)${R}"
    tail -n 4 "$LOG" | sed 's/^/    /'
  fi
  exit 0
fi

# ── HTML dashboard (self-contained, theme-aware, no external assets) ───────
# Max data_added for bar scaling.
MAXADD=1
for row in "${SNAP_ROWS[@]}"; do IFS=$'\t' read -r _ _ _ a _ _ <<<"$row"; (( a > MAXADD )) && MAXADD=$a; done

case "$VERDICT" in
  fresh)   vlabel="Fresh";        vclass="ok" ;;
  stale)   vlabel="Stale";        vclass="bad" ;;
  running) vlabel="Backing up…";  vclass="run" ;;
  *)       vlabel="No snapshots"; vclass="warn" ;;
esac
# Freshness gauge fill (% of threshold consumed; clamp 100)
gauge_pct=0
if [[ -n "$LATEST_AGE_SECS" ]]; then
  gauge_pct="$(awk -v a="$LATEST_AGE_SECS" -v t="$((THRESHOLD_HOURS*3600))" 'BEGIN{p=(t>0)?a/t*100:0;if(p>100)p=100;printf "%.0f",p}')"
fi

esc() { sed -e 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

# Build snapshot rows + bars HTML (newest first)
ROWS_HTML=""; BARS_HTML=""
for (( i=${#SNAP_ROWS[@]}-1; i>=0; i-- )); do
  IFS=$'\t' read -r sid siso stags sadded sbytes sfiles <<<"${SNAP_ROWS[i]}"
  se="$(iso_to_epoch "$siso")"; age=""; [[ "$se" -gt 0 ]] && age="$(fmt_age "$(( NOW_EPOCH - se ))")"
  when="${siso%.*}"; when="${when:0:19}"; when="${when/T/ }"
  wpct="$(awk -v a="$sadded" -v m="$MAXADD" 'BEGIN{printf "%.1f",(m>0)?a/m*100:0}')"
  ROWS_HTML+="<tr><td class=mono>$(printf '%s' "$sid" | esc)</td><td>${when}</td><td>$(printf '%s' "$age" | esc)</td><td><span class=tag>$(printf '%s' "$stags" | esc)</span></td><td class=num>$(human "$sadded")</td><td class=num>$(human "$sbytes")</td><td class=num>${sfiles}</td></tr>"
  BARS_HTML+="<div class=bar-row><div class=bar-label>${when:5:11}</div><div class=bar-track><div class=bar-fill style=\"width:${wpct}%\"></div></div><div class=bar-val>$(human "$sadded")</div></div>"
done

REPO_DISP="$(printf '%s' "$RESTIC_REPOSITORY" | esc)"
LATEST_AGE_DISP="—"; [[ -n "$LATEST_AGE_SECS" ]] && LATEST_AGE_DISP="$(fmt_age "$LATEST_AGE_SECS")"

mkdir -p "$(dirname "$HTML_PATH")"
cat > "$HTML_PATH" <<HTML
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
  .badge{display:inline-flex;align-items:center;gap:7px;font-weight:600;padding:5px 12px;border-radius:999px;font-size:14px}
  .badge::before{content:"";width:9px;height:9px;border-radius:50%}
  .ok{color:var(--ok)}.ok::before{background:var(--ok)}
  .bad{color:var(--bad)}.bad::before{background:var(--bad)}
  .warn{color:var(--warn)}.warn::before{background:var(--warn)}
  .run{color:var(--run)}.run::before{background:var(--run);animation:pulse 1.4s infinite}
  @keyframes pulse{0%,100%{opacity:1}50%{opacity:.3}}
  .badge{background:color-mix(in srgb,currentColor 12%,transparent)}
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
  .mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
  .tag{background:color-mix(in srgb,var(--accent) 14%,transparent);color:var(--accent);padding:2px 8px;border-radius:6px;font-size:12px}
  .scroll{overflow-x:auto}
  .repo{color:var(--muted);font-size:12px;word-break:break-all;margin-top:6px}
  .foot{color:var(--muted);font-size:12px;margin-top:28px}
</style>
</head>
<body>
<div class=wrap>
  <h1>Zuruck backup status</h1>
  <div class=sub>Generated ${GENERATED}</div>

  <div style="margin-bottom:20px"><span class="badge ${vclass}">${vlabel}</span></div>

  <div class=grid>
    <div class=card><div class=k>Freshness</div><div class=v>${LATEST_AGE_DISP}</div>
      <div class=gauge><div style="width:${gauge_pct}%"></div></div>
      <div class=repo>within ${THRESHOLD_HOURS}h window</div></div>
    <div class=card><div class=k>Schedule</div><div class=v>$( [[ "$SCHED_LOADED" == yes ]] && echo "Loaded" || echo "Off" )</div>
      <div class=repo>$( [[ -n "$EVERY_HOURS" ]] && echo "every ${EVERY_HOURS}h" || echo "—" )$( [[ -n "$SCHED_LAST_EXIT" ]] && echo " · last exit ${SCHED_LAST_EXIT}" )</div></div>
    <div class=card><div class=k>Repo size</div><div class=v>$(human "$REPO_STORED")</div>
      <div class=repo>${REPO_BLOBS} blobs</div></div>
    <div class=card><div class=k>Snapshots</div><div class=v>${SNAP_COUNT}</div>
      <div class=repo>$( [[ "$RUNNING" == yes ]] && echo "backing up now" || echo "idle" )</div></div>
  </div>

  <h2>Data uploaded per snapshot</h2>
  ${BARS_HTML:-<div class=repo>No snapshots yet.</div>}

  <h2>Recent snapshots</h2>
  <div class=scroll><table>
    <thead><tr><th>ID</th><th>When</th><th>Age</th><th>Tags</th><th class=num>Uploaded</th><th class=num>Logical</th><th class=num>Files</th></tr></thead>
    <tbody>${ROWS_HTML:-<tr><td colspan=7 class=repo>No snapshots yet.</td></tr>}</tbody>
  </table></div>

  <div class=repo style="margin-top:20px">Repository: <span class=mono>${REPO_DISP}</span></div>
  <div class=foot>Static snapshot — re-run <span class=mono>status.sh --html</span> to refresh.</div>
</div>
</body>
</html>
HTML

echo "Wrote dashboard: $HTML_PATH"
if $OPEN_HTML; then open "$HTML_PATH" 2>/dev/null || true; fi
