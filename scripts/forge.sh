#!/usr/bin/env bash
# Resolve the Forge binary from PATH and run it. CI installs the exact version
# declared in its workflow; local contributors install Foundry separately.
set -euo pipefail

if command -v forge >/dev/null 2>&1; then
    FORGE="$(command -v forge)"
else
    echo "[forge.sh] forge not found on PATH." >&2
    echo "[forge.sh] Install Foundry from https://getfoundry.sh." >&2
    exit 127
fi

exec "$FORGE" "$@"
