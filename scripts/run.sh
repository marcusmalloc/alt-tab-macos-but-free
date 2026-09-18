#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh
if pkill -x BareTab; then
    while pgrep -x BareTab >/dev/null; do sleep 0.1; done
fi
open .build/BareTab.app --args "$@"
