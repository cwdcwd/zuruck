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
#   ./scripts/install-schedule.sh --build-runner   # (re)compile the FDA wrapper only
#   ./scripts/install-schedule.sh -- --tag nightly --dry-run   # args after -- go to backup.sh
#
# macOS Full Disk Access:
#   The scheduled job runs through a dedicated compiled wrapper (zuruck-runner)
#   rather than /bin/bash, so you grant FDA to that one binary instead of
#   blessing system-wide bash. Its path is printed after install.
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
    --build-runner) ACTION="build-runner"; shift ;;
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

# Dedicated FDA wrapper: a tiny compiled binary that is the only thing we grant
# Full Disk Access to (instead of system-wide /bin/bash). See zuruck-runner.c.
RUNNER_SRC="$SCRIPT_DIR/zuruck-runner.c"
RUNNER_DIR="$HOME/Library/Application Support/Zuruck"
RUNNER_BIN="$RUNNER_DIR/zuruck-runner"

# Compile + ad-hoc sign the wrapper, baking in the absolute path to backup.sh.
# Rebuilds only when the source is newer than the binary (rebuilding changes the
# code hash and invalidates the FDA grant, so we avoid gratuitous rebuilds).
build_runner() {
  command -v clang >/dev/null 2>&1 || { echo "ERROR: clang not found (install Xcode Command Line Tools: xcode-select --install)." >&2; return 1; }
  mkdir -p "$RUNNER_DIR"
  if [[ -x "$RUNNER_BIN" && "$RUNNER_BIN" -nt "$RUNNER_SRC" ]]; then
    return 0
  fi
  echo "==> Building FDA wrapper: $RUNNER_BIN"
  clang -O2 -Wall -Wextra -o "$RUNNER_BIN" "$RUNNER_SRC" \
    -DBACKUP_SH="\"$BACKUP_SH\"" -DINTERP="\"/bin/bash\""
  codesign -s - -i com.zuruck.runner -f "$RUNNER_BIN" >/dev/null 2>&1 || true
}

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

# ── Build-only ──────────────────────────────────────────────────────────────
if [[ "$ACTION" == "build-runner" ]]; then
  build_runner
  echo "Runner: $RUNNER_BIN"
  echo "Grant Full Disk Access to that path (System Settings › Privacy & Security)."
  exit 0
fi

# ── Status / uninstall ────────────────────────────────────────────────────
if [[ "$ACTION" == "status" ]]; then
  echo "Label:  $LABEL"
  echo "Plist:  $PLIST $( [[ -f "$PLIST" ]] && echo "(present)" || echo "(absent)" )"
  echo "Runner: $RUNNER_BIN $( [[ -x "$RUNNER_BIN" ]] && echo "(built)" || echo "(NOT built)" )"
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

# ProgramArguments: <zuruck-runner> <args...>
# The runner is ProgramArguments[0], so it is the FDA "responsible process";
# it internally runs /bin/bash backup.sh with these forwarded args.
prog_args=$'\t\t<string>'"$RUNNER_BIN"$'</string>\n'
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
build_runner
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
echo "⚠️  macOS Full Disk Access (one-time): the job can't read protected folders"
echo "    (Desktop/Documents/Downloads/…) until you grant FDA to the wrapper:"
echo
echo "      $RUNNER_BIN"
echo
echo "    System Settings › Privacy & Security › Full Disk Access › + , then"
echo "    press ⌘⇧G and paste that path. (No need to grant /bin/bash.)"
