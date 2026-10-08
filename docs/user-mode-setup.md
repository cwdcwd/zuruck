# User-Mode Clients, Root Scope, and Collector Reporting

This guide covers three optional pieces that sit on top of the standard
[client setup](client-setup-guide.md):

- **User mode**: a Linux client that runs entirely as an unprivileged user,
  with no sudo during setup or backups.
- **Root scope**: an owner-installed grant that lets that user back up
  root-owned paths (`/etc`, docker volumes) without a general root shell.
- **Collector reporting**: each run POSTs its status to a central dashboard.

System-mode clients (`/etc/restic`, root timer) keep working exactly as
before. Every script finds its config the same way:
`$RESTIC_ENV_FILE`, then `~/.config/zuruck/env`, then `/etc/restic/env`.

## User mode

### What gets installed

| Item | Location | Mode |
|---|---|---|
| Config dir | `~/.config/zuruck/` | 0700 |
| Env file (repo, AWS creds, flags) | `~/.config/zuruck/env` | 0600 |
| Client restic password | `~/.config/zuruck/password` | 0600 |
| Paths to back up | `~/.config/zuruck/include` | 0600 |
| Ingest token (if reporting) | `~/.config/zuruck/ingest-token` | 0600 |
| restic binary | `~/.local/bin/restic` | 0755 |
| systemd user units | `~/.config/systemd/user/zuruck-backup.{service,timer}` | |

The timer runs `scripts/backup.sh --forget --tag scheduled` from the zuruck
checkout every 4 hours. Don't move or delete the checkout after setup; re-run
setup if you do.

### Setup

Run as the backup user. Secrets come from the environment or a hidden
prompt. `--secret-access-key` is refused in user mode because it shows up in
`ps` and shell history.

```bash
git clone https://github.com/cwdcwd/zuruck.git ~/zuruck && cd ~/zuruck
export SECRET_ACCESS_KEY='<from Secrets Manager>'
export ZURUCK_INGEST_TOKEN='<from the collector>'   # only with --ingest-url
./scripts/client-setup.sh --user-mode \
  --client-name myhost-<suffix> \
  --bucket <bucket> --access-key-id <AKIA...> \
  --install-restic --restic-version <X.Y.Z> --restic-sha256 <sha256 of the .bz2> \
  --backup-path ~/.hermes --backup-path ~/fleet-ops \
  --freshness-hours 12 \
  --ingest-url http://collector.lan:8790/api/ingest \
  --root-backup
unset SECRET_ACCESS_KEY ZURUCK_INGEST_TOKEN
```

User mode can't use apt, so `--install-restic` needs a pinned version and its
SHA256 from the [restic releases page](https://github.com/restic/restic/releases).
Re-running setup is safe: it keeps the existing client password, so an
initialized repository stays readable.

Then have the admin initialize the repository with the master password (the
setup output prints the exact commands), and run a first backup:

```bash
~/zuruck/scripts/backup.sh --tag first
```

### Lingering

User timers only run while the user has a session unless lingering is on.
Setup tries `loginctl enable-linger`. If polkit refuses, the owner runs:

```bash
sudo loginctl enable-linger <user>
```

### Checking on it

```bash
systemctl --user list-timers zuruck-backup.timer
journalctl --user -u zuruck-backup.service -n 50
~/zuruck/scripts/status.sh            # terminal summary
~/zuruck/scripts/status.sh --json     # what the collector receives
```

## Root scope

A user-mode client can't read root-owned files. The root scope closes that gap
with one fixed, root-owned command the user may run through sudo, with no
arguments allowed.

### What the owner installs

| Item | Location |
|---|---|
| Wrapper (`scripts/root-backup.sh`) | `/usr/local/sbin/zuruck-root-backup`, root 0755 |
| Root-owned restic copy | `/usr/local/sbin/restic-zuruck`, root 0755 |
| Root config | `/etc/zuruck-root/{env,password,paths}`, root 0600 |
| Optional hooks | `/etc/zuruck-root/hooks/<name>` + `/etc/zuruck-root/hooks.env` |
| Grant | `/etc/sudoers.d/030-zuruck-root-backup` |

The grant line is exact-argv with an empty argument list:

```
<user> ALL=(root) NOPASSWD: /usr/local/sbin/zuruck-root-backup ""
```

The wrapper refuses to run if any config file, hook, or the restic binary is
not root-owned, is a symlink, or is group- or world-writable. It never uses
the user's `~/.local/bin/restic`, because a user-writable binary run as root
would be a privilege escalation.

### Install (owner, once per host, after user-mode setup)

```bash
cd ~<user>/zuruck   # or any checkout the owner trusts
sudo ./scripts/install-root-backup.sh --user <user> \
  --path /etc --path /var/lib/docker/volumes/<volume>/_data \
  [--hook litellm-pg-dump] \
  --restic-version <X.Y.Z> --restic-sha256 <sha256>
```

The installer copies the repo URL, AWS credentials, and client password from
the user's `~/.config/zuruck/`, so root-scope snapshots land in the same
repository, tagged `root`. CloudWatch freshness stays per machine, and
`status.sh --json` reports `scopes.user` and `scopes.root` separately.

Verify as the user:

```bash
sudo -n -l                                         # exactly one command listed
sudo -n id                                         # must fail
sudo -n /usr/local/sbin/zuruck-root-backup --x     # must fail
sudo -n /usr/local/sbin/zuruck-root-backup         # first root snapshot
```

Scheduled runs include the root scope when the env file has
`ZURUCK_ROOT_BACKUP=1` (set by `client-setup.sh --root-backup`). Order within
a run: user backup, root backup, retention, report. A failed root scope
fails the run, after retention and reporting have still happened.

To remove the grant: `sudo ./scripts/install-root-backup.sh --user <user> --uninstall`.

### Hooks

Hooks produce consistent dumps that a file-level backup can't, such as a live
database. Each hook writes under `$ZURUCK_HOOK_OUT`, and that output is added
to the root snapshot. If a hook fails, its output is discarded so a partial
dump is never backed up. The rest of the root scope is still backed up, and
the run exits non-zero.

`litellm-pg-dump` runs `pg_dump` inside the LiteLLM compose project's
postgres container. Fill in `/etc/zuruck-root/hooks.env` first. The service,
user, and database names have no defaults, because a wrong guess would back
up the wrong thing. Check them against `/opt/litellm/docker-compose.yml`.

Each run writes `/var/lib/zuruck-root/last-run.json` (no secrets, world-readable),
which `status.sh --json` includes as `root_last_run`.

### Restoring root-scope files (owner)

```bash
sudo RESTIC_ENV_FILE=/etc/zuruck-root/env ./scripts/restore.sh list
sudo RESTIC_ENV_FILE=/etc/zuruck-root/env ./scripts/restore.sh restore latest --tag root --target /root/restore-test
```

## Appliances

Hosts with no agent user (OctoPrint, Pi-hole) use the standard **system-mode**
client with root paths, which already runs as root:

```bash
sudo ./scripts/client-setup.sh --client-name pihole-<suffix> --bucket <bucket> \
  --access-key-id <AKIA...> --backup-path /etc/pihole --backup-path /etc/dnsmasq.d \
  --install-restic --restic-version <X.Y.Z> --restic-sha256 <sha256> \
  --ingest-url http://collector.lan:8790/api/ingest
```

## Collector reporting

When `ZURUCK_INGEST_URL` is set in the env file, `backup.sh` runs
`scripts/report.sh` on every exit, success or failure. The report is
`status.sh --json` plus a `report` object:

```json
"report": { "schema": 1, "host": "myhost", "client": "myhost-<suffix>",
            "platform": "linux", "sent_at": "2026-10-07T20:00:00Z", "exit_code": 0 }
```

The request carries `Authorization: Bearer <token>`. The token is read from a
0600 file and passed to curl through a temporary 0600 header file, so it
never appears in a process argument list. A down collector only produces a
warning. It never fails the backup.

To add or rotate reporting on an existing client:

```bash
ZURUCK_INGEST_TOKEN='<token>' ./scripts/set-ingest.sh --url http://collector.lan:8790/api/ingest --test
sudo ZURUCK_INGEST_TOKEN='<token>' ./scripts/set-ingest.sh --url ...   # system-mode client
./scripts/set-ingest.sh --disable
```

On Windows, run `scripts\win\set-ingest.ps1 -Url <url> [-Test]` elevated. The
token is DPAPI-encrypted like the client's other secrets, and `backup.ps1`
reports after each run. See [windows-setup-guide.md](windows-setup-guide.md).

`./scripts/report.sh --print` shows the payload without sending it.

## Testing

```bash
npm run test:scripts
```

This runs the Linux integration test in Debian containers and the Windows
report-helper test on PowerShell for Linux. It needs Docker. The Linux test
uses a local restic repository, a stub `systemctl`, and a stand-in collector.
It covers setup file modes, secret handling, the sudo grant's limits, hook
failure handling, reporting on success and failure, per-scope status, and
restores.
