#!/bin/bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$repo_dir/build"
app_dir="$build_dir/Stay Here.app"

if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Stay Here must be built on macOS.' >&2
  exit 1
fi

mkdir -p "$app_dir/Contents/MacOS" "$build_dir/ModuleCache"
xcrun --sdk macosx clang -O2 -fobjc-arc -Wall -Wextra -Wno-unused-parameter \
  -fmodules -fmodules-cache-path="$build_dir/ModuleCache" \
  -mmacosx-version-min=26.0 -framework AppKit \
  "$repo_dir/Sources/StayHere.m" -o "$app_dir/Contents/MacOS/StayHere"
cp "$repo_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
plutil -lint "$app_dir/Contents/Info.plist"
codesign --force --sign - "$app_dir"
codesign --verify --strict "$app_dir"
echo "Built: $app_dir"
