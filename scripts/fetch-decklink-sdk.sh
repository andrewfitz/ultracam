#!/bin/bash
set -euo pipefail
# Compatibility wrapper: the required SDK is vendored and pin-verified.
task_root="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$task_root/scripts/vendor-sdk.py" verify decklink
