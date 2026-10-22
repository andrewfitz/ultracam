#!/bin/bash
set -euo pipefail
# The DeckLink SDK interfaces live in the repo (ThirdParty/DeckLinkSDK, SDK 16.0,
# license blocks intact). This only checks that the expected version is present.
task_root="$(cd "$(dirname "$0")/.." && pwd)"
sdk_dir="${DECKLINK_SDK_DIR:-$task_root/ThirdParty/DeckLinkSDK/include}"
version_header="$sdk_dir/DeckLinkAPIVersion.h"
if [[ ! -f "$version_header" || ! -f "$sdk_dir/DeckLinkAPI.h" || ! -f "$sdk_dir/DeckLinkAPIDispatch.cpp" ]]; then
  echo "DeckLink SDK interfaces not found in $sdk_dir." >&2
  exit 1
fi
if ! /usr/bin/grep -Eq 'define BLACKMAGIC_DECKLINK_API_VERSION[[:space:]]+0x10000000' "$version_header"; then
  echo "Expected DeckLink SDK 16.0 in $sdk_dir." >&2
  exit 1
fi
