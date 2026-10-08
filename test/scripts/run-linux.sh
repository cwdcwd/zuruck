#!/usr/bin/env bash
#
# Run the client-script integration test in a throwaway Debian container.
#   ./test/scripts/run-linux.sh                 # debian:bookworm (Raspberry Pi OS base)
#   IMAGE=debian:trixie ./test/scripts/run-linux.sh
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE="${IMAGE:-debian:bookworm}"
exec docker run --rm -v "$ROOT:/src:ro" "$IMAGE" bash -c '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null
  apt-get install -y -qq restic jq curl sudo python3 openssl bzip2 procps >/dev/null
  mkdir -p /work && cp -a /src /work/zuruck
  rm -rf /work/zuruck/node_modules
  bash /work/zuruck/test/scripts/linux-integration.sh
'
