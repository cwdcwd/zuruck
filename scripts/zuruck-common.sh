# shellcheck shell=bash
#
# Zuruck — shared helpers for the client scripts (sourced, not executed).
#
# Config locations, in resolution order:
#   1. $RESTIC_ENV_FILE                      explicit override
#   2. ${XDG_CONFIG_HOME:-~/.config}/zuruck/env   user mode (client-setup.sh --user-mode)
#   3. /etc/restic/env                       system mode (original layout)
# The directory holding the env file is the "config dir": include, excludes and
# ingest-token live next to it.

zuruck_user_config_dir() {
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/zuruck"
}

zuruck_resolve_env_file() {
  if [[ -n "${RESTIC_ENV_FILE:-}" ]]; then
    printf '%s\n' "$RESTIC_ENV_FILE"; return
  fi
  local user_env
  user_env="$(zuruck_user_config_dir)/env"
  if [[ -r "$user_env" ]]; then
    printf '%s\n' "$user_env"; return
  fi
  printf '%s\n' /etc/restic/env
}

# Where logs and the generated HTML status page go.
zuruck_state_dir() {
  if [[ "$(uname)" == "Darwin" ]]; then
    printf '%s\n' "$HOME/Library/Logs"
  else
    printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/zuruck"
  fi
}

# User-mode installs put restic in ~/.local/bin, which systemd user units and
# non-login shells often lack on PATH.
zuruck_add_user_bin_to_path() {
  if [[ -d "$HOME/.local/bin" && ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    PATH="$HOME/.local/bin:$PATH"
    export PATH
  fi
}

# Client name = last path segment of the S3 repository URL.
zuruck_client_name() {
  local repo="${1:-${RESTIC_REPOSITORY:-}}"
  repo="${repo%/}"
  printf '%s\n' "${repo##*/}"
}

# restic emits ISO8601 with fractional seconds and a tz offset. GNU date parses
# it directly (offset honoured); BSD date needs the fraction and offset
# stripped and parses as local time. Prints 0 when unparseable.
zuruck_iso_to_epoch() {
  local iso="$1" out
  if out="$(date -d "$iso" +%s 2>/dev/null)"; then
    printf '%s\n' "$out"; return
  fi
  local t
  t="$(printf '%s' "$iso" | sed -E 's/\.[0-9]+//; s/([+-][0-9]{2}):?[0-9]{2}$//; s/Z$//')"
  date -j -f "%Y-%m-%dT%H:%M:%S" "$t" +%s 2>/dev/null || echo 0
}
