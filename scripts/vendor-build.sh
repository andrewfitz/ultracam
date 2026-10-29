#!/bin/bash
# Shared, validated vendor inputs. Manifest data is never evaluated as shell.
vendor_load_list() {
  local kind="$1" item
  shift
  python3 "$task_root/scripts/vendors.py" query ${vendor_query_args[@]+"${vendor_query_args[@]}"} --kind "$kind" --null "$@" > "$vendor_query_file" || return $?
  vendor_values=()
  while IFS= read -r -d '' item; do vendor_values+=("$item"); done < "$vendor_query_file"
}

vendor_configure() {
  local membership="$1" vendor_id="${2:-}" group="${3:-}" swift_membership="${4:-$1}" value
  vendor_selected_bridge=""
  vendor_output_root="${test_root:-${check_root:-}}"
  [[ -n "$vendor_output_root" ]] || { echo 'vendor_configure requires test_root or check_root' >&2; return 1; }
  mkdir -p "$vendor_output_root/native" "$vendor_output_root/modules"
  vendor_query_file="$vendor_output_root/vendor-query.nul"
  vendor_query_args=(--root "$task_root" --membership "$membership")
  [[ -z "$vendor_id" ]] || vendor_query_args+=(--vendor "$vendor_id")
  [[ -z "$group" ]] || vendor_query_args+=(--group "$group")
  python3 "$task_root/scripts/vendors.py" validate ${vendor_query_args[@]+"${vendor_query_args[@]}"} >/dev/null || return $?
  if [[ -z "$vendor_id" ]]; then python3 "$task_root/scripts/vendors.py" generate --root "$task_root" >/dev/null || return $?; fi
  vendor_load_list swift-sources --membership "$swift_membership" || return $?
  vendor_swift_sources=(${vendor_values[@]+"${vendor_values[@]}"})
  vendor_load_list native-sources || return $?
  vendor_native_sources=(${vendor_values[@]+"${vendor_values[@]}"})
  vendor_load_list header-dirs || return $?
  vendor_header_dirs=(${vendor_values[@]+"${vendor_values[@]}"})
  vendor_load_list defines || return $?
  vendor_defines=(${vendor_values[@]+"${vendor_values[@]}"})
  vendor_load_list library-dirs || return $?
  vendor_library_dirs=(${vendor_values[@]+"${vendor_values[@]}"})
  vendor_load_list link-flags || return $?
  vendor_link_args=(${vendor_values[@]+"${vendor_values[@]}"})
  vendor_load_list embed-json || return $?
  vendor_embed_json="${vendor_values[0]}"
  vendor_native_args=()
  vendor_swift_native_args=()
  for value in ${vendor_header_dirs[@]+"${vendor_header_dirs[@]}"}; do
    vendor_native_args+=(-I "$value")
    vendor_swift_native_args+=(-Xcc "-I$value")
  done
  for value in ${vendor_defines[@]+"${vendor_defines[@]}"}; do
    vendor_native_args+=("-D$value")
    vendor_swift_native_args+=(-Xcc "-D$value")
  done
  for value in ${vendor_library_dirs[@]+"${vendor_library_dirs[@]}"}; do
    vendor_link_args+=(-L "$value")
    # Global test/UI/monitor tools are standalone executables, not app bundles.
    if [[ -z "$vendor_id" ]]; then vendor_link_args+=(-Xlinker -rpath -Xlinker "$value"); fi
  done
  if [[ -n "$vendor_id" ]]; then
    vendor_load_list sdk-root || return $?
    vendor_sdk_root="${vendor_values[0]}"
    vendor_load_list bridge-header || return $?
    vendor_selected_bridge="${vendor_values[0]}"
  fi
  vendor_bridge="${vendor_selected_bridge:-$task_root/Sources/DeviceAPI/GeneratedBridgingHeader.h}"
}

vendor_compile_native() {
  local log="$1" source_file object_file token
  vendor_native_objects=()
  : > "$log"
  for source_file in ${vendor_native_sources[@]+"${vendor_native_sources[@]}"}; do
    token="$(printf '%s' "$source_file" | shasum -a 256 | cut -c1-20)"
    object_file="$vendor_output_root/native/$token.o"
    vendor_compile_args=(-Wall -Wextra -Werror -fmodules-cache-path="$vendor_output_root/modules")
    case "$source_file" in
      *.mm) vendor_compile_args+=(-std=c++17 -fobjc-arc) ;;
      *.cpp) vendor_compile_args+=(-std=c++17) ;;
      *.m) vendor_compile_args+=(-fobjc-arc) ;;
    esac
    xcrun clang++ ${vendor_compile_args[@]+"${vendor_compile_args[@]}"} ${vendor_native_args[@]+"${vendor_native_args[@]}"} -c "$source_file" -o "$object_file" >> "$log" 2>&1 || { cat "$log"; return 1; }
    vendor_native_objects+=("$object_file")
  done
}

vendor_embed_into() {
  python3 - "$vendor_embed_json" "$1" <<'PY'
import json, pathlib, shutil, sys
root = pathlib.Path(sys.argv[2])
for entry in json.loads(sys.argv[1]):
    target = root / entry['subfolder']
    target.mkdir(parents=True, exist_ok=True)
    shutil.copy2(entry['path'], target / pathlib.Path(entry['path']).name)
PY
}
