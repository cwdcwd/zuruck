# Client Setup Guide

This guide walks you through setting up a client machine to back up to the Zuruck S3 backup system using restic.

## Prerequisites

- A client entry has been added to `lib/config/clients.ts` and deployed via CDK
- You have received from your AWS administrator:
  - AWS Access Key ID and Secret Access Key for the client's IAM user
    (retrieved from Secrets Manager — see runbook)
  - The S3 bucket name
  - The AWS region (default: `us-west-2`)
  - The master password from SSM (for initial repo initialization only)

## Step 1: Install Restic

### Linux (Debian/Ubuntu)

```bash
sudo apt update && sudo apt install restic
```

### Linux (RHEL/CentOS)

```bash
sudo yum install restic
```

### macOS

```bash
brew install restic
```

### Manual Download

```bash
# Download the latest release
curl -L https://github.com/restic/restic/releases/latest/download/restic_0.17.3_linux_amd64.bz2 -o restic.bz2
bzip2 -d restic.bz2
chmod +x restic
sudo mv restic /usr/local/bin/
```

## Step 2: Create the Client Password File

Generate a strong client-specific password. This is **different** from the master password.

```bash
# Create the restic config directory
sudo mkdir -p /etc/restic

# Generate a random password
openssl rand -base64 32 | sudo tee /etc/restic/password
sudo chmod 600 /etc/restic/password
# On Linux (systemd runs restic as root):
sudo chown root:root /etc/restic/password
# On macOS (you run restic as your user):
# sudo chown $(whoami) /etc/restic/password
```

## Step 3: Configure Environment

Create the environment file:

```bash
sudo tee /etc/restic/env <<EOF
export AWS_ACCESS_KEY_ID="<your-access-key-id>"
export AWS_SECRET_ACCESS_KEY="<your-secret-access-key>"
export RESTIC_REPOSITORY="s3:s3.us-west-2.amazonaws.com/<bucket-name>/<client-prefix>"
export RESTIC_PASSWORD_FILE="/etc/restic/password"
EOF
sudo chmod 600 /etc/restic/env
# On Linux (systemd runs restic as root):
sudo chown root:root /etc/restic/env
# On macOS (you run restic as your user):
# sudo chown $(whoami) /etc/restic/env
```

> **Important**: Replace `<your-access-key-id>`, `<your-secret-access-key>`, `<bucket-name>`, and `<client-prefix>` with the values from your administrator.
>
> **Security tip**: The automated `scripts/client-setup.sh` script accepts the
> secret access key via the `SECRET_ACCESS_KEY` environment variable (preferred)
> or an interactive prompt, avoiding exposure in `ps(1)` and shell history.
> The `--secret-access-key` CLI flag is also supported for CI but is not
> recommended for interactive use.

## Step 4: Initialize the Repository

This step is split between admin and client. Admin uses the master password
once to bootstrap the repo and add a client-specific key; the client then
operates only with its own password. The master password should never be
stored on the client machine.

### Step 4a — Admin (one-time, on a trusted workstation)

```bash
# Set repo + master password env (do NOT use the client's env file)
export AWS_ACCESS_KEY_ID="<admin-credentials-or-temporary-keys>"
export AWS_SECRET_ACCESS_KEY="<...>"
export RESTIC_REPOSITORY="s3:s3.us-west-2.amazonaws.com/<bucket-name>/<client-name>"
export RESTIC_PASSWORD="<master-password-from-ssm>"

# Initialize the repository
restic init

# Add the client key (will prompt for the *new* client password)
restic key add

# Verify both keys exist
restic key list
```

### Step 4b — Client (on the target machine)

The client only needs `/etc/restic/password` populated (Step 2) and
`/etc/restic/env` configured (Step 3). No additional restic admin work.

## Step 5: Test the Backup

```bash
source /etc/restic/env
restic backup /path/to/test/data
restic snapshots
restic stats
```

## Step 6: Schedule Automatic Backups

### Option A: Systemd Timer (Recommended for Linux)

`scripts/client-setup.sh` writes these unit files for you using the absolute
path from `command -v restic`. If you're authoring them by hand, substitute
the right path below — `/usr/bin/restic` on Debian/Ubuntu (apt), or
`/usr/local/bin/restic` for a manual download. systemd does not expand
shell substitutions in unit files.

```ini
# /etc/systemd/system/restic-backup.service
[Unit]
Description=Restic Backup
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/restic/env
ExecStartPre=/usr/bin/restic backup /data --tag auto
ExecStart=/usr/bin/restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --keep-yearly 2 --prune
```

Create the timer:

```ini
# /etc/systemd/system/restic-backup.timer
[Unit]
Description=Restic Backup Timer

[Timer]
OnCalendar=*-*-* 00/4:00:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
```

Enable:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now restic-backup.timer
```

### Option B: Cron (Alternative for Linux)

```bash
# Add to crontab (every 4 hours at :05)
sudo crontab -e -u root
```

Add:

```
5 */4 * * * . /etc/restic/env && restic backup /data --tag auto && restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --keep-yearly 2 --prune >> /var/log/restic.log 2>&1
```

### Option C: macOS launchd (use `scripts/install-schedule.sh`)

Don't hand-write the plist — `scripts/install-schedule.sh` builds and loads a
per-user LaunchAgent (`com.zuruck.backup`) that runs `backup.sh` on a fixed
daily schedule (`StartCalendarInterval`, default every 4h: 00/04/08/12/16/20).

```bash
./scripts/install-schedule.sh                # install, default every 4h
./scripts/install-schedule.sh --every 6      # every 6 hours
./scripts/install-schedule.sh --status       # is it loaded? built? last exit?
./scripts/install-schedule.sh --uninstall    # remove it
```

**Full Disk Access (required, one-time).** A background launchd job cannot read
protected folders (Desktop/Documents/Downloads/Pictures/Photos) without FDA, and
it gets *no* prompt — it silently skips them. To avoid granting FDA to
system-wide `/bin/bash`, the schedule runs through a dedicated compiled wrapper
(`scripts/zuruck-runner.c` → `~/Library/Application Support/Zuruck/zuruck-runner`).
Grant FDA to **that binary only**:

> System Settings › Privacy & Security › Full Disk Access › **+** , press **⌘⇧G**,
> paste the path printed by the installer, enable the toggle. No need to grant
> `/bin/bash`.

Because macOS attributes file access to the launchd job's *responsible process*
(the wrapper, which stays resident via `fork()`+`exec()`), that single grant
covers the whole `runner → bash → restic` chain. Rebuilding the wrapper changes
its code hash and invalidates the grant, so a normal install never recompiles an
existing binary — only `./scripts/install-schedule.sh --build-runner` does, after
which you re-grant FDA.

> **Laptops sleep.** launchd does not fire a scheduled job while the Mac is
> asleep; it runs a single catch-up on the next wake. With a 24h freshness
> threshold this is fine, but if you need guaranteed overnight backups, wake the
> Mac with `sudo pmset repeat wakeorpoweron MTWRFSU 23:55:00`.

Check health anytime with `./scripts/status.sh` (see the runbook's
[Client Status](./runbook.md#client-status-local) section).

## Step 7: Verify Monitoring

After the first backup completes, verify that CloudWatch metrics are being published:

1. Open the AWS CloudWatch console
2. Navigate to Dashboards → `zuruck-backup-health`
3. Confirm your client appears with `BackupFreshness = 1`

## Troubleshooting

### "bucket not found" or "access denied"

- Verify the `RESTIC_REPOSITORY` URL uses **path-style**: `s3:s3.us-west-2.amazonaws.com/bucket-name/prefix`
- Check that the IAM access key has the correct permissions
- Verify the bucket name matches the CDK output

### "wrong password"

- Ensure `RESTIC_PASSWORD_FILE` points to the correct file
- The file should contain only the password, no trailing newline

### "no such host"

- Check network connectivity to `s3.us-west-2.amazonaws.com`
- Verify the AWS region matches your deployment

### `i/o timeout` / retry spam during backup

Transient network flakiness (often right after wake) — restic retries and
recovers, so `operation successful after N retries` means nothing failed.
`backup.sh` waits for the S3 endpoint before starting; on a persistently weak
link, set `S3_CONNECTIONS=2` in `/etc/restic/env` to cap parallel connections.
See the runbook's [Transient S3 Timeouts](./runbook.md#transient-s3-timeouts-io-timeout-tls-handshake-timeout).

### Glacier restore needed

If backups have transitioned to Glacier, you must restore objects before running `restic restore`:

```bash
# Check storage class
aws s3api head-object --bucket <bucket-name> --key <key> --query 'StorageClass'

# Restore from Glacier
aws s3api restore-object --bucket <bucket-name> --key <key> \
  --restore-request '{"Days":7,"GlacierJobParameters":{"Tier":"Standard"}}'
```

## Security Notes

- **Never** store the master password on the client machine
- Rotate IAM access keys every 90 days
- Use `RESTIC_PASSWORD_FILE` instead of `RESTIC_PASSWORD` environment variable (more secure, doesn't show in `ps`)
- Restrict `/etc/restic/env` and `/etc/restic/password` to `root:root 600`
- A compromised client credential cannot wipe the bucket's version history
  unless the attacker waits out the noncurrent retention window (90 days);
  with Object Lock enabled (recommended for new deployments — see
  [backup-strategy.md](./backup-strategy.md)), even that path is closed.

### Hardening: Encrypt `/etc/restic/env` at rest

The default install writes the AWS secret access key to `/etc/restic/env`
in cleartext. The file is `chmod 600` so only root can read it, but a host
filesystem snapshot, backup, or `dd` captures the secret. For laptops
and any machine you don't fully trust, encrypt the env file so it's only
readable by the systemd service that needs it. (Security-review S12.)

#### Linux (systemd ≥ 250)

Encrypt the env file with `systemd-creds`:

```bash
sudo systemd-creds encrypt --name=AWS_SECRET_ACCESS_KEY \
  - /etc/restic/aws_secret.cred <<<"$SECRET_ACCESS_KEY"
sudo chmod 600 /etc/restic/aws_secret.cred
```

Update the service unit to load the credential:

```ini
[Service]
Type=oneshot
LoadCredentialEncrypted=AWS_SECRET_ACCESS_KEY:/etc/restic/aws_secret.cred
EnvironmentFile=/etc/restic/env_public  # contains everything *except* the secret
ExecStartPre=/bin/sh -c 'export AWS_SECRET_ACCESS_KEY=$(cat $CREDENTIALS_DIRECTORY/AWS_SECRET_ACCESS_KEY); /usr/bin/restic backup /data'
```

Now the secret is decryptable only by this service when systemd has unlocked
the host (TPM-bound on most modern Linux installs).

#### macOS (Keychain)

```bash
# Store the secret once
security add-generic-password -a "$(whoami)" -s zuruck-aws-secret -w "$SECRET_ACCESS_KEY"

# In your launchd ProgramArguments wrapper:
export AWS_SECRET_ACCESS_KEY=$(security find-generic-password -a "$(whoami)" -s zuruck-aws-secret -w)
```

### Pinning restic version

Distro packages can lag behind upstream and don't expose a checksum-pinning
workflow. For a hardened install, fetch the upstream binary with
`--restic-version` + `--restic-sha256`:

```bash
sudo SECRET_ACCESS_KEY=... ./scripts/client-setup.sh \
  --client-name alpha \
  --bucket zuruck-backup-... \
  --access-key-id AKIA... \
  --install-restic \
  --restic-version 0.17.3 \
  --restic-sha256 <sha256-from-github-release>
```

Look up the SHA256 at <https://github.com/restic/restic/releases>.
(Security-review S14.)

### Accepted risk: prefix-name reconnaissance

A compromised client can probe whether other client prefixes exist (e.g.
`bravo/`, `gamma/`) by listing them — IAM `s3:ListBucket` policies in S3
condition on the `s3:prefix` parameter, not on the bucket contents.
The probe only confirms existence; it does not give read access. The
recommended mitigations are: (a) name prefixes with non-guessable suffixes
(`alpha-7f3a/`), or (b) accept the leakage. We currently accept it.
(Security-review S9.)