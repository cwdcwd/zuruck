#!/usr/bin/env bash
#
# Run the Windows report-helper test on native PowerShell in a Debian
# container (DPAPI-free: the test mocks secrets and the HTTP call).
#   ./test/scripts/run-windows-report.sh
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
case "$(uname -m)" in arm64|aarch64) PARCH=arm64 ;; *) PARCH=x64 ;; esac
URL="$(curl -fsSL https://api.github.com/repos/PowerShell/PowerShell/releases/latest \
  | grep -o "https://[^\"]*linux-${PARCH}.tar.gz" | head -1)"
exec docker run --rm -v "$ROOT/scripts/win:/w:ro" -v "$ROOT/test/scripts:/t:ro" -e URL="$URL" debian:bookworm bash -c '
  set -e
  apt-get update -qq >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates libicu72 >/dev/null
  mkdir -p /opt/pwsh && curl -fsSL "$URL" | tar -xz -C /opt/pwsh && chmod +x /opt/pwsh/pwsh
  /opt/pwsh/pwsh -NoProfile -File /t/win-report.tests.ps1
'
