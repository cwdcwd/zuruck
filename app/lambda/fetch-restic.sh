#!/usr/bin/env bash
#
# Populate the restic Lambda layer with a SHA256-pinned linux/arm64 binary.
# Run this before `cdk deploy -c deployRecoveryUi=true`; `cdk synth` works without
# it (the layer asset dir exists with a placeholder README).
#
# Usage:
#   app/lambda/fetch-restic.sh [VERSION] [SHA256]
#   app/lambda/fetch-restic.sh 0.19.0 <sha256-from-github-releases>
#
# Mirrors the SHA-pinned download in scripts/client-setup.sh. Look up the hash at
# https://github.com/restic/restic/releases (restic_<version>_linux_arm64.bz2).
set -euo pipefail

VERSION="${1:-0.19.0}"
SHA256="${2:-}"
DEST="$(cd "$(dirname "$0")" && pwd)/layer/bin"
file="restic_${VERSION}_linux_arm64.bz2"
url="https://github.com/restic/restic/releases/download/v${VERSION}/${file}"

mkdir -p "$DEST"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

echo "Downloading $url"
curl -fsSL "$url" -o "$tmp/$file"

if [[ -n "$SHA256" ]]; then
  actual="$(shasum -a 256 "$tmp/$file" | awk '{print $1}')"
  if [[ "$actual" != "$SHA256" ]]; then
    echo "SHA256 mismatch: expected $SHA256, got $actual" >&2
    exit 1
  fi
  echo "SHA256 verified: $actual"
else
  echo "WARNING: no SHA256 provided — skipping verification. Pin it for a hardened build." >&2
fi

bunzip2 -c "$tmp/$file" > "$DEST/restic"
chmod +x "$DEST/restic"
echo "Installed restic ${VERSION} (linux/arm64) → $DEST/restic"
