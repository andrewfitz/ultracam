#!/bin/bash
# Keeps a Release build's dSYM so a crash report of that build still symbolicates
# after its run directory is gone:
#   <symbols>/<build id>/<name>.dSYM   one copy per build
#   <symbols>/<UUID> -> <build id>     one link per UUID the dSYM holds (every
#                                      slice), so a crash report's UUID finds it
# Only the newest <keep> builds' copies are kept (build ids sort by time, as
# build.sh's run ids do), and links to removed copies go with them. A UUID seen
# again (an identical binary) links to the newest copy.
# Usage: archive-dsym.sh <dSYM> <symbols directory> <build id> [keep, default 20]
set -euo pipefail
export LC_ALL=C
if [[ $# -lt 3 || $# -gt 4 ]]; then
  echo 'Usage: archive-dsym.sh <dSYM> <symbols directory> <build id> [keep]' >&2
  exit 2
fi
dsym="$1"
symbols="$2"
build_id="$3"
keep="${4:-20}"
if [[ ! -d "$dsym" ]]; then
  echo "No dSYM at $dsym" >&2
  exit 1
fi
if [[ ! "$build_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "Invalid build id: $build_id" >&2
  exit 2
fi
if [[ ! "$keep" =~ ^[1-9][0-9]*$ ]]; then
  echo "keep must be a positive integer: $keep" >&2
  exit 2
fi
mkdir -p "$symbols"
# Hold the archive lock across copying, index updates and retention. The
# kernel releases the directory descriptor if this process is interrupted.
if [[ "${ULTRACAM_DSYM_LOCK_PID:-}" != "$$" ]]; then
  exec python3 - "$0" "$@" <<'PYTHON'
import fcntl
import os
import sys

directory = os.open(sys.argv[3], os.O_RDONLY)
fcntl.flock(directory, fcntl.LOCK_EX)
os.set_inheritable(directory, True)
os.environ["ULTRACAM_DSYM_LOCK_PID"] = str(os.getpid())
os.execv("/bin/bash", ["/bin/bash", *sys.argv[1:]])
PYTHON
fi
uuids="$(/usr/bin/dwarfdump --uuid "$dsym" | /usr/bin/awk '$1 == "UUID:" { print $2 }')"
if [[ -z "$uuids" ]]; then
  echo "dwarfdump found no UUID in $dsym" >&2
  exit 1
fi
archive_name="$(basename "$dsym")"
copy="$symbols/$build_id"
if [[ -e "$copy" || -L "$copy" ]]; then
  echo "A symbol archive already exists: $copy" >&2
  exit 1
fi
for uuid in $uuids; do
  link="$symbols/$uuid"
  if [[ -e "$link" && ! -L "$link" ]]; then
    echo "Cannot index UUID over an existing archive entry: $link" >&2
    exit 1
  fi
done
partial="$(mktemp -d "$symbols/.$build_id.XXXXXX")"
trap 'rm -rf "$partial"' EXIT
/usr/bin/ditto "$dsym" "$partial/$archive_name"
mv "$partial" "$copy"
for uuid in $uuids; do
  link="$symbols/$uuid"
  if [[ -L "$link" && -d "$link" && "$(readlink "$link")" > "$build_id" ]]; then continue; fi
  ln -sfn "$build_id" "$link"
done
# Count copies of this bundle under valid build IDs.
entries=("$symbols"/*)
kept=0
for ((index=${#entries[@]} - 1; index >= 0; index--)); do
  path="${entries[index]}"
  bundle="$path/$archive_name"
  if [[ ! "${path##*/}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ || -L "$path" || -L "$bundle" || ! -d "$bundle" ]]; then continue; fi
  kept=$((kept + 1))
  if [[ "$kept" -gt "$keep" ]]; then rm -rf "$path"; fi
done
for path in "${entries[@]}"; do
  if [[ "${path##*/}" =~ ^[A-Fa-f0-9]{8}(-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}$ && -L "$path" && ! -e "$path" ]]; then
    rm -f "$path"
  fi
done
echo "Symbols: $copy ($(echo "$uuids" | /usr/bin/tr '\n' ' ' | /usr/bin/sed 's/ $//'))"
