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
# Generate a random password
openssl rand -base64 32 | sudo tee /etc/restic/password
sudo chmod 600 /etc/restic/password
sudo chown root:root /etc/restic/password
```

## Step 3: Configure Environment

Create the environment file:

```bash
sudo mkdir -p /etc/restic
sudo tee /etc/restic/env <<EOF
export AWS_ACCESS_KEY_ID="<your-access-key-id>"
export AWS_SECRET_ACCESS_KEY="<your-secret-access-key>"
export RESTIC_REPOSITORY="s3:s3.us-west-2.amazonaws.com/<bucket-name>/<client-prefix>"
export RESTIC_PASSWORD_FILE="/etc/restic/password"
EOF
sudo chmod 600 /etc/restic/env
sudo chown root:root /etc/restic/env
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

### Option C: macOS launchd

```bash
# Create ~/Library/LaunchAgents/com.restic.backup.plist
```

See the [restic documentation](https://restic.readthedocs.io/en/stable/080_examples.html) for macOS-specific scheduling.

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