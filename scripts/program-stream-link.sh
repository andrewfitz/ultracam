#!/bin/bash
# Link receiver fixtures to the exact package products used by the Xcode app build.
program_stream_link_args() {
  local products module_map product
  products="$(cd "$1" && pwd)" || return 1
  module_map="$products/../../Intermediates.noindex/GeneratedModuleMaps/CProgramAV1.modulemap"
  if [[ ! -f "$module_map" ]]; then
    echo "Missing $module_map. Supply the Xcode products directory with its sibling build intermediates." >&2
    return 1
  fi
  stream_link_args=(-I "$products" -Xcc "-fmodule-map-file=$module_map")
  for product in Logboard.o HaishinKit.o RTMPHaishinKit.o ProgramAV1.o CProgramAV1.o libaom.a; do
    if [[ ! -f "$products/$product" ]]; then
      echo "Missing $product in $products. Build Ultracam and supply its Xcode products directory." >&2
      return 1
    fi
    stream_link_args+=("$products/$product")
  done
  stream_link_args+=(-lc++)
}
