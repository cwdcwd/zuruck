#!/usr/bin/env bash
#
# Zuruck — install scheduled backups
#
# On macOS this installs a per-user launchd LaunchAgent that runs
# scripts/backup.sh on an interval. (On Linux, client-setup.sh already installs
# a systemd timer; this helper prints a cron line as a fallback.)
#
# Usage:
#   ./scripts/install-schedule.sh                 # every 4h, backup + retention
#   ./scripts/install-schedule.sh --every 6       # every 6 hours
#   ./scripts/install-schedule.sh --status        # show whether it's loaded
#   ./scripts/install-schedule.sh --uninstall     # remove the schedule
#   ./scripts/install-schedule.sh --print         # print the plist, don't install
#   ./scripts/install-schedule.sh -- --tag nightly --dry-run   # args after -- go to backup.sh
#
set -euo pipefail

LABEL="com.zuruck.backup"
EVERY_HOURS=4
ACTION="install"
BACKUP_ARGS=(--forget --tag scheduled)
USER_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --every)     EVERY_HOURS="$2"; shift 2 ;;
    --label)     LABEL="$2"; shift 2 ;;
    --uninstall) ACTION="uninstall"; shift ;;
    --status)    ACTION="status"; shift ;;
    --print)     ACTION="print"; shift ;;
    --)          shift; USER_ARGS=("$@"); break ;;
    -h|--help)   sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done
[[ ${#USER_ARGS[@]} -gt 0 ]] && BACKUP_ARGS=("${USER_ARGS[@]}")

[[ "$EVERY_HOURS" =~ ^[0-9]+$ && "$EVERY_HOURS" -ge 1 ]] || { echo "ERROR: --every must be a positive integer (hours)." >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_SH="$SCRIPT_DIR/backup.sh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/zuruck-backup.log"
INTERVAL=$(( EVERY_HOURS * 3600 ))
DOMAIN="gui/$(id -u)"

# ── Non-macOS: point at systemd (client-setup) or emit a cron line ────────
if [[ "$(uname)" != "Darwin" ]]; then
  echo "Not macOS — launchd is unavailable."
  echo "• On Linux with systemd, client-setup.sh already installs a restic-backup.timer."
  echo "• Otherwise add this cron line (crontab -e):"
  echo
  echo "    0 */$EVERY_HOURS * * * /bin/bash $BACKUP_SH ${BACKUP_ARGS[*]} >> $LOG 2>&1"
  exit 0
fi

[[ -x "$BACKUP_SH" ]] || { echo "ERROR: $BACKUP_SH not found or not executable." >&2; exit 1; }

# ── Status / uninstall ────────────────────────────────────────────────────
if [[ "$ACTION" == "status" ]]; then
  echo "Label:  $LABEL"
  echo "Plist:  $PLIST $( [[ -f "$PLIST" ]] && echo "(present)" || echo "(absent)" )"
  echo "Loaded: $(launchctl list 2>/dev/null | grep -q "$LABEL" && echo yes || echo no)"
  echo "Log:    $LOG"
  exit 0
fi

if [[ "$ACTION" == "uninstall" ]]; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || launchctl unload -w "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Removed schedule '$LABEL'."
  exit 0
fi

# ── Build the plist ───────────────────────────────────────────────────────
# launchd jobs get a minimal PATH, so bake in where restic/aws actually live.
BIN_DIRS="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
for tool in restic aws; do
  p="$(command -v "$tool" 2>/dev/null || true)"
  [[ -n "$p" ]] && BIN_DIRS="$(dirname "$p"):$BIN_DIRS"
done
PATH_VALUE="$(printf '%s' "$BIN_DIRS" | tr ':' '\n' | awk '!seen[$0]++' | paste -sd: -)"

# ProgramArguments: /bin/bash <backup.sh> <args...>
prog_args=$'\t\t<string>/bin/bash</string>\n'
prog_args+=$'\t\t<string>'"$BACKUP_SH"$'</string>\n'
for a in "${BACKUP_ARGS[@]}"; do prog_args+=$'\t\t<string>'"$a"$'</string>\n'; done

read -r -d '' PLIST_XML <<XML || true
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
$prog_args	</array>
	<key>WorkingDirectory</key>
	<string>$(dirname "$SCRIPT_DIR")</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>$PATH_VALUE</string>
		<key>HOME</key>
		<string>$HOME</string>
	</dict>
	<key>StartInterval</key>
	<integer>$INTERVAL</integer>
	<key>RunAtLoad</key>
	<false/>
	<key>StandardOutPath</key>
	<string>$LOG</string>
	<key>StandardErrorPath</key>
	<string>$LOG</string>
	<key>ProcessType</key>
	<string>Background</string>
	<key>LowPriorityIO</key>
	<true/>
</dict>
</plist>
XML

if [[ "$ACTION" == "print" ]]; then
  printf '%s\n' "$PLIST_XML"
  exit 0
fi

# ── Install + load ────────────────────────────────────────────────────────
mkdir -p "$HOME/Library/LaunchAgents" "$(dirname "$LOG")"
printf '%s\n' "$PLIST_XML" > "$PLIST"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null || launchctl load -w "$PLIST"
launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true

echo "Installed schedule '$LABEL': every ${EVERY_HOURS}h → backup.sh ${BACKUP_ARGS[*]}"
echo "  plist: $PLIST"
echo "  log:   $LOG"
echo
echo "Run once now:   launchctl kickstart -k $DOMAIN/$LABEL"
echo "Check it:       ./scripts/install-schedule.sh --status"
echo "Remove it:      ./scripts/install-schedule.sh --uninstall"
echo
echo "⚠️  macOS Full Disk Access: a launchd job can't read protected folders"
echo "    (Documents/Desktop/Downloads/.Trash) unless you grant FDA to /bin/bash"
echo "    (or /opt/homebrew/bin/restic) in System Settings › Privacy & Security."
