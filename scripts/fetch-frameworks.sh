#!/bin/bash
# Download the prebuilt xcframeworks Shell links (GhosttyKit + ios_system) into
# the local override package at .local-packages/ShellBinaries/Frameworks.
#
# The committed Xcode project resolves these through their upstream Swift
# packages; this script exists for builds that must run without network access
# at build time, or on machines where SwiftPM's credential lookup blocks on a
# keychain prompt. Pair it with ./scripts/use-local-frameworks.sh.
#
# Every archive is checksum-verified against the value published in the
# upstream Package.swift manifests.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/.local-packages/ShellBinaries/Frameworks"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

GHOSTTY_VERSION="v0.2.8"
IOS_SYSTEM_VERSION="v0.1.0"

# name|url|sha256
ARTIFACTS=(
"GhosttyKitAppStore|https://github.com/kitknox/ghosttykit-rootshell/releases/download/${GHOSTTY_VERSION}/GhosttyKitAppStore.xcframework.zip|bfb74bd98d18336845c1ed445c45e277d2ae42963c84c55e238965eb2447492b"
"ios_system|https://github.com/kitknox/ios_system-rootshell/releases/download/${IOS_SYSTEM_VERSION}/ios_system.xcframework.zip|ce6a816ab9a901fe5df31ad6d819e19b773db32d25f612aa8318da11c6bc2cba"
"awk|https://github.com/kitknox/ios_system-rootshell/releases/download/${IOS_SYSTEM_VERSION}/awk.xcframework.zip|4e65e4f31a1a6b9270de0b7d2bb8514933c4693686f9659beb35db51043c324e"
"files|https://github.com/kitknox/ios_system-rootshell/releases/download/${IOS_SYSTEM_VERSION}/files.xcframework.zip|a55e031b73974e94b209d43343e0608a188baf887f91d45eb7a7f9d112197c90"
"shell|https://github.com/kitknox/ios_system-rootshell/releases/download/${IOS_SYSTEM_VERSION}/shell.xcframework.zip|7d6c39a0c5ca8bedef3c2ba97ebf8be01b0c62f3960feaa16a1a9fcb5cba2aa6"
"text|https://github.com/kitknox/ios_system-rootshell/releases/download/${IOS_SYSTEM_VERSION}/text.xcframework.zip|8a3bb33c303ff3c51c3ddb23748bd989afc24d88353153dd7484e0a561ea3f11"
)

mkdir -p "$DEST"

for entry in "${ARTIFACTS[@]}"; do
    IFS='|' read -r name url want <<< "$entry"

    if [[ -d "$DEST/$name.xcframework" ]]; then
        echo "have    $name.xcframework"
        continue
    fi

    echo "fetch   $name.xcframework"
    zip="$WORK/$name.zip"
    curl -fsSL -o "$zip" "$url"

    got="$(shasum -a 256 "$zip" | awk '{print $1}')"
    if [[ "$got" != "$want" ]]; then
        echo "ERROR: checksum mismatch for $name" >&2
        echo "  expected $want" >&2
        echo "  actual   $got" >&2
        exit 1
    fi

    rm -rf "$DEST/$name.xcframework"
    unzip -q "$zip" -d "$DEST"
done

echo "frameworks ready in $DEST"
