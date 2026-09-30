#!/bin/bash
set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(dirname "$script_dir")"
temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT

"$script_dir/prepare-apple-source.sh"

xcodebuild build \
    -quiet \
    -project "$repo_root/jq_ios/jq_ios.xcodeproj" \
    -scheme jq_ios \
    -configuration Release \
    -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath "$temporary_dir/DerivedData" \
    CODE_SIGNING_ALLOWED=NO

products="$temporary_dir/DerivedData/Build/Products/Release"
framework="$products/jq_ios.framework"
[[ -d "$framework" ]] || { echo "error: native test framework was not produced" >&2; exit 1; }

xcrun clang \
    -std=c11 \
    -Wall \
    -Wextra \
    -Werror \
    -F "$products" \
    "$repo_root/Tests/jq_ios_parity.c" \
    -framework jq_ios \
    -lpthread \
    -Wl,-export_dynamic \
    -Wl,-rpath,"$products" \
    -o "$temporary_dir/jq_ios_parity"

DYLD_FRAMEWORK_PATH="$products" "$temporary_dir/jq_ios_parity"
