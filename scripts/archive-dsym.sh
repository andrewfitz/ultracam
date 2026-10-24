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
uuids="$(/usr/bin/dwarfdump --uuid "$dsym" | /usr/bin/awk '$1 == "UUID:" { print $2 }')"
if [[ -z "$uuids" ]]; then
  echo "dwarfdump found no UUID in $dsym" >&2
  exit 1
fi
mkdir -p "$symbols"
copy="$symbols/$build_id"
partial="$symbols/.$build_id.partial"
# Also any copy an interrupted run left.
rm -rf "$symbols"/.*.partial
/usr/bin/ditto "$dsym" "$partial/$(basename "$dsym")" || {
  rm -rf "$partial"
  exit 1
}
rm -rf "$copy"
mv "$partial" "$copy"
for uuid in $uuids; do
  link="$symbols/$uuid"
  # ln -sfn on a real directory would link inside it.
  if [[ -d "$link" && ! -L "$link" ]]; then rm -rf "$link"; fi
  ln -sfn "$build_id" "$link"
done
# Newest first: every real directory is one build's copy.
kept=0
for entry in $(/bin/ls -1 "$symbols" | /usr/bin/sort -r); do
  path="$symbols/$entry"
  if [[ -L "$path" || ! -d "$path" ]]; then continue; fi
  kept=$((kept + 1))
  if [[ "$kept" -gt "$keep" ]]; then rm -rf "$path"; fi
done
for entry in $(/bin/ls -1 "$symbols"); do
  path="$symbols/$entry"
  if [[ -L "$path" && ! -e "$path" ]]; then rm -f "$path"; fi
done
echo "Symbols: $copy ($(echo "$uuids" | /usr/bin/tr '\n' ' ' | /usr/bin/sed 's/ $//'))"
