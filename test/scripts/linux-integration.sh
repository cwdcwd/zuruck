#!/bin/bash
#
# Linux integration test for the client scripts. Runs INSIDE a disposable
# Debian container as root (see run-linux.sh); never run it on a real host —
# it creates users, sudoers entries and /etc/zuruck-root.
#
# Uses a local restic repository instead of S3, a stub systemctl/loginctl, and
# a tiny HTTP listener standing in for the collector.
#
set -euo pipefail

[[ -f /.dockerenv || "${ZURUCK_TEST_IN_CONTAINER:-}" == 1 ]] || { echo "refusing: not in a container" >&2; exit 1; }

PASS=0; FAIL=0
ok()   { echo "  ok   - $*"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL - $*"; FAIL=$((FAIL+1)); }
check() { local desc="$1"; shift; if "$@" >/dev/null; then ok "$desc"; else bad "$desc"; fi; }

SRC=/work/zuruck          # writable copy of the repo
U=alice
UH=/home/$U
REPO=/srv/repo
as_user() { sudo -u "$U" -H env -u RESTIC_ENV_FILE "$@"; }

echo "[$SECONDS s] == setup"
useradd -m -s /bin/bash "$U"
mkdir -p "$REPO" && chown "$U:$U" "$REPO"

# Collector stand-in: records the Authorization header and body of each POST.
cat >/tmp/collector.py <<'EOF'
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        with open('/tmp/ingest.log', 'a') as f:
            f.write(json.dumps({"auth": self.headers.get('Authorization'), "body": json.loads(body)}) + "\n")
        self.send_response(204); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', 18790), H).serve_forever()
EOF
python3 /tmp/collector.py & COLLECTOR_PID=$!
trap 'kill $COLLECTOR_PID 2>/dev/null || true' EXIT

# Stub systemctl/loginctl for the user (no systemd in the container).
install -d -o "$U" -g "$U" "$UH/stubs"
for cmd in systemctl loginctl; do
  cat >"$UH/stubs/$cmd" <<EOF
#!/bin/sh
echo "$cmd \$*" >>"$UH/stub-calls.log"
case "\$*" in "show-user"*) echo no ;; esac
exit 0
EOF
  chmod 755 "$UH/stubs/$cmd"
done
# Stub restic for client-setup only (setup probes S3; real restic is used later).
sudo -u "$U" mkdir -p "$UH/.local/bin"
cat >"$UH/.local/bin/restic" <<'EOF'
#!/bin/sh
case "$1" in version) echo "restic 0.0.0-stub";; *) exit 1;; esac
EOF
chmod 755 "$UH/.local/bin/restic"; chown "$U:$U" "$UH/.local/bin/restic"

echo "[$SECONDS s] == client-setup.sh --user-mode"
check "refuses --secret-access-key in user mode" \
  bash -c "! sudo -u $U -H $SRC/scripts/client-setup.sh --user-mode --client-name test-abc123 --bucket b --access-key-id AKIATEST --secret-access-key x >/dev/null 2>&1"
check "refuses to run user mode as root" \
  bash -c "! SECRET_ACCESS_KEY=abc $SRC/scripts/client-setup.sh --user-mode --client-name test-abc123 --bucket b --access-key-id AKIATEST >/dev/null 2>&1"

# shellcheck disable=SC2088 # literal ~ on purpose: backup.sh expands it from the include file
as_user env PATH="$UH/stubs:/usr/bin:/bin" SECRET_ACCESS_KEY='wJalrXUtnFEMI/K7MDENGbPxRfiCYEXAMPLEKEY' ZURUCK_INGEST_TOKEN='tok-123' \
  "$SRC/scripts/client-setup.sh" --user-mode --client-name test-abc123 --bucket zuruck-backup-test \
  --access-key-id AKIATESTKEY --backup-path "$UH/data" --backup-path '~/notes' \
  --ingest-url http://127.0.0.1:18790/api/ingest --root-backup --freshness-hours 12 >/tmp/setup.log 2>&1 \
  || { cat /tmp/setup.log; bad "client-setup user mode ran"; }
C="$UH/.config/zuruck"
check "config dir is 0700"        test "$(stat -c %a "$C")" = 700
check "env is 0600 and user-owned" test "$(stat -c '%a %U' "$C/env")" = "600 $U"
check "password is 0600"          test "$(stat -c %a "$C/password")" = 600
check "ingest-token is 0600"      test "$(stat -c %a "$C/ingest-token")" = 600
check "env points at user password file" grep -q "RESTIC_PASSWORD_FILE=\"$C/password\"" "$C/env"
check "env has ingest url"        grep -q 'ZURUCK_INGEST_URL="http://127.0.0.1:18790/api/ingest"' "$C/env"
check "env has root flag"         grep -q 'ZURUCK_ROOT_BACKUP=1' "$C/env"
check "secret not in setup output" bash -c "! grep -q wJalrXUtnFEMI /tmp/setup.log"
check "include file has paths"    grep -qx "$UH/data" "$C/include"
check "user service written"      grep -q "ExecStart=\"$SRC/scripts/backup.sh\" --forget --tag scheduled" "$UH/.config/systemd/user/zuruck-backup.service"
check "timer enabled via --user"  grep -q 'systemctl --user enable --now zuruck-backup.timer' "$UH/stub-calls.log"
check "linger attempted"          grep -q 'loginctl enable-linger' "$UH/stub-calls.log"
check "no sudo used by setup"     bash -c "! grep -qi 'sudo' $UH/stub-calls.log"
PW_BEFORE="$(cat "$C/password")"
as_user env PATH="$UH/stubs:/usr/bin:/bin" SECRET_ACCESS_KEY='wJalrXUtnFEMI/K7MDENGbPxRfiCYEXAMPLEKEY' \
  "$SRC/scripts/client-setup.sh" --user-mode --client-name test-abc123 --bucket zuruck-backup-test \
  --access-key-id AKIATESTKEY --no-timer >/dev/null 2>&1
check "re-run keeps the client password" test "$(cat "$C/password")" = "$PW_BEFORE"
check "re-run without --ingest-url dropped it" bash -c "! grep -q ZURUCK_INGEST_URL $C/env"
# Restore reporting via set-ingest.sh (the path existing clients use).
as_user env ZURUCK_INGEST_TOKEN='tok-123' "$SRC/scripts/set-ingest.sh" --url http://127.0.0.1:18790/api/ingest >/dev/null
check "set-ingest adds the url once" test "$(grep -c ZURUCK_INGEST_URL "$C/env")" = 1
cat >>"$C/env" <<'EOF'
export ZURUCK_ROOT_BACKUP=1
export ZURUCK_FRESHNESS_HOURS=12
EOF

echo "[$SECONDS s] == backup.sh (user scope, local repo, real restic)"
rm -f "$UH/.local/bin/restic"
sed -i "s|^export RESTIC_REPOSITORY=.*|export RESTIC_REPOSITORY=\"$REPO/test-abc123\"|" "$C/env"
as_user bash -c "source $C/env && restic init >/dev/null"
# Local-backend only (S3 has no file owners): share the repo through group
# $U with setgid dirs and a group-readable config, which makes restic create
# group-readable files — so root's snapshots stay readable to the user.
chmod -R g+rwX "$REPO"; find "$REPO" -type d -exec chmod g+s {} +; chmod 640 "$REPO/test-abc123/config"
as_user mkdir -p "$UH/data" "$UH/notes"
as_user bash -c "echo hello >$UH/data/a.txt; echo note >$UH/notes/n.txt"
# Root grant not installed yet → run must fail on the root step but still report.
set +e
as_user "$SRC/scripts/backup.sh" --tag first >/tmp/backup1.log 2>&1
RC1=$?
set -e
check "backup fails when root grant missing" test "$RC1" -ne 0
check "user snapshot still created" as_user bash -c "source $C/env && restic snapshots --json | jq -e 'length==1' >/dev/null"
check "report sent on failure" test -s /tmp/ingest.log
check "report carries failing exit code" bash -c "tail -1 /tmp/ingest.log | jq -e '.body.report.exit_code != 0' >/dev/null"
check "bearer token sent" bash -c "tail -1 /tmp/ingest.log | jq -e '.auth == \"Bearer tok-123\"' >/dev/null"
check "token not in any argv during run" bash -c "! grep -q tok-123 /tmp/backup1.log"

echo "[$SECONDS s] == install-root-backup.sh"
mkdir -p /srv/rootdata && echo secret-config >/srv/rootdata/app.conf && chmod 600 /srv/rootdata/app.conf
"$SRC/scripts/install-root-backup.sh" --user "$U" --path /srv/rootdata --path /does/not/exist \
  --hook litellm-pg-dump --restic-binary "$(command -v restic)" >/tmp/install.log 2>&1 \
  || { cat /tmp/install.log; bad "install-root-backup ran"; }
check "wrapper installed root 0755" test "$(stat -c '%U %a' /usr/local/sbin/zuruck-root-backup)" = "root 755"
check "sudoers valid"               visudo -cf /etc/sudoers.d/030-zuruck-root-backup
check "root env is 0600"            test "$(stat -c %a /etc/zuruck-root/env)" = 600
check "hooks.env template created"  test -f /etc/zuruck-root/hooks.env
check "user cannot read root data"  bash -c "! sudo -u $U cat /srv/rootdata/app.conf 2>/dev/null"
check "sudo -n id denied"           bash -c "! sudo -u $U sudo -n id >/dev/null 2>&1"
check "wrapper with args denied"    bash -c "! sudo -u $U sudo -n /usr/local/sbin/zuruck-root-backup --x >/dev/null 2>&1"
check "sudo -l lists only the wrapper" bash -c "sudo -u $U sudo -n -l | grep -q 'zuruck-root-backup \"\"'"

# Run the wrapper directly via the grant.
set +e
# shellcheck disable=SC2024 # the log is the test's (root's), not the user's
sudo -u "$U" sudo -n /usr/local/sbin/zuruck-root-backup >/tmp/root1.log 2>&1
RRC=$?
set -e
check "unconfigured hook fails the run"  test "$RRC" -ne 0
check "last-run records failed hook"     jq -e '.hooks_failed == ["litellm-pg-dump"]' /var/lib/zuruck-root/last-run.json
check "root snapshot still created"      as_user bash -c "source $C/env && restic snapshots --tag root --json | jq -e 'length==1' >/dev/null"
check "failed hook output not backed up" as_user bash -c "source $C/env && ! restic ls latest --tag root | grep -q litellm"
check "scratch cleaned up"               test ! -e /var/lib/zuruck-root/scratch

# Disable the hook → a clean root run.
rm /etc/zuruck-root/hooks/litellm-pg-dump
check "root run succeeds without the hook" sudo -u "$U" sudo -n /usr/local/sbin/zuruck-root-backup >/dev/null 2>&1

echo "[$SECONDS s] == wrapper refuses tampered config"
chmod 660 /etc/zuruck-root/paths
check "refuses group-writable paths file" bash -c "! /usr/local/sbin/zuruck-root-backup >/dev/null 2>&1"
chmod 600 /etc/zuruck-root/paths
ln -sf /etc/hostname /tmp/evil && mv /etc/zuruck-root/paths /etc/zuruck-root/paths.real && ln -s /tmp/evil /etc/zuruck-root/paths
check "refuses symlinked paths file" bash -c "! /usr/local/sbin/zuruck-root-backup >/dev/null 2>&1"
rm /etc/zuruck-root/paths && mv /etc/zuruck-root/paths.real /etc/zuruck-root/paths

echo "[$SECONDS s] == backup.sh with root scope + forget"
: >/tmp/ingest.log
as_user timeout 300 "$SRC/scripts/backup.sh" --tag scheduled --forget >/tmp/backup2.log 2>&1 || { cat /tmp/backup2.log; bad "full run succeeded"; }
check "full run reported exit 0" bash -c "tail -1 /tmp/ingest.log | jq -e '.body.report.exit_code == 0' >/dev/null"
check "root step ran inside backup.sh" grep -q 'Root scope: sudo -n' /tmp/backup2.log
root_line="$(grep -n 'Root scope: sudo -n' /tmp/backup2.log | head -1 | cut -d: -f1)"
ret_line="$(grep -n 'Applying retention' /tmp/backup2.log | head -1 | cut -d: -f1)"
check "retention ran after root step" test -n "$root_line" -a -n "$ret_line" -a "${root_line:-0}" -lt "${ret_line:-0}"

echo "[$SECONDS s] == status.sh --json"
as_user "$SRC/scripts/status.sh" --json >/tmp/status.json
check "client name derived"       jq -e '.client == "test-abc123"' /tmp/status.json
check "threshold from env file"   jq -e '.threshold_hours == 12' /tmp/status.json
check "user scope fresh (GNU date)" jq -e '.scopes.user.fresh == true and .scopes.user.age_seconds < 900' /tmp/status.json
check "root scope present"        jq -e '.scopes.root.fresh == true' /tmp/status.json
check "verdict fresh"             jq -e '.verdict == "fresh"' /tmp/status.json
check "root_last_run embedded"   jq -e '.root_last_run.exit_code == 0' /tmp/status.json
as_user "$SRC/scripts/status.sh" --html >/dev/null
check "html written to state dir" test -f "$UH/.local/state/zuruck/status.html"

echo "[$SECONDS s] == restore.sh"
as_user "$SRC/scripts/restore.sh" restore latest --target "$UH/restored" --path "$UH/data" --yes >/dev/null 2>&1 || true
check "restore of user file works" test "$(cat "$UH/restored$UH/data/a.txt" 2>/dev/null)" = hello
RESTORE_DIR=/root/root-restore
RESTIC_ENV_FILE=/etc/zuruck-root/env "$SRC/scripts/restore.sh" restore latest --tag root --target "$RESTORE_DIR" --yes >/dev/null 2>&1 \
  || RESTIC_ENV_FILE=/etc/zuruck-root/env bash -c "source /etc/zuruck-root/env; /usr/local/sbin/restic-zuruck restore latest --tag root --target $RESTORE_DIR >/dev/null"
check "owner can restore root file" test "$(cat $RESTORE_DIR/srv/rootdata/app.conf 2>/dev/null)" = secret-config

echo "[$SECONDS s] == uninstall"
"$SRC/scripts/install-root-backup.sh" --user "$U" --uninstall >/dev/null
check "sudoers removed" test ! -e /etc/sudoers.d/030-zuruck-root-backup

echo
echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
