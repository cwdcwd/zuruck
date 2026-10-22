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

# Decrypt the AWS secret from systemd-creds storage (client-setup.sh
# --encrypt-creds). The env file then carries ZURUCK_AWS_CRED_FILE=<config>/aws.cred instead of
# a plaintext AWS_SECRET_ACCESS_KEY. The .cred file is encrypted with a
# user-scoped key, so the same user on the same machine can decrypt it —
# whether from a plain shell or from their systemd user service. Idempotent:
# an already-set AWS_SECRET_ACCESS_KEY (e.g. exported by the caller) wins.
# Returns non-zero when a credential file is configured but cannot be
# decrypted, so callers fail loudly instead of hitting S3 with no secret.
zuruck_decrypt_aws_secret() {
  if [[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    return 0
  fi
  if [[ -z "${ZURUCK_AWS_CRED_FILE:-}" ]]; then
    return 0
  fi
  if ! command -v systemd-creds &>/dev/null; then
    echo "ERROR: ZURUCK_AWS_CRED_FILE=${ZURUCK_AWS_CRED_FILE} is set but systemd-creds is not on PATH" \
         "(the env file carries an encrypted secret; re-run client-setup.sh without --encrypt-creds or install systemd-creds)." >&2
    return 1
  fi
  if [[ ! -r "${ZURUCK_AWS_CRED_FILE}" ]]; then
    echo "ERROR: ZURUCK_AWS_CRED_FILE=${ZURUCK_AWS_CRED_FILE} is set but not readable." >&2
    return 1
  fi
  if ! AWS_SECRET_ACCESS_KEY="$(systemd-creds decrypt --user --name=AWS_SECRET_ACCESS_KEY "${ZURUCK_AWS_CRED_FILE}")"; then
    echo "ERROR: systemd-creds decrypt failed for ${ZURUCK_AWS_CRED_FILE} (user-scoped key not decryptable by $(id -un)?)." >&2
    return 1
  fi
  if [[ -z "${AWS_SECRET_ACCESS_KEY}" ]]; then
    echo "ERROR: decrypted AWS secret from ${ZURUCK_AWS_CRED_FILE} is empty." >&2
    return 1
  fi
  export AWS_SECRET_ACCESS_KEY
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
