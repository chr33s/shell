#!/bin/bash
# Build ssh_cmd.xcframework (OpenSSH ssh / scp / sftp for ios_system) from the
# vendored ios_system-rootshell source, for the local SSH agent bridge
# (ssh-agent-bridge-spec.md §19).
#
# Usage: ./scripts/build-openssh.sh [--force]
#
# Output: Packages/OpenSSHCommands/Artifacts/ssh_cmd.xcframework (untracked).
# Slices: iOS device, iOS Simulator, Mac Catalyst. There is no visionOS slice:
# the pinned OpenSSL release has none, so the app links OpenSSHCommands on iOS
# and Mac Catalyst only.
#
# ssh_cmd links OpenSSL and libssh2 dynamically. Those are the holzschu
# releases also pinned (URL + SHA-256) as binary targets in
# Packages/OpenSSHCommands/Package.swift; the archives are verified against the
# same checksums here before anything is built against them.
#
# vendor/ is never modified: the ios_system project is copied to .build/ and
# only that copy's framework references are repointed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="$ROOT/Packages/OpenSSHCommands"
OUTPUT="$PACKAGE/Artifacts/ssh_cmd.xcframework"
WORK="$ROOT/.build/openssh"
STAMP_FILE="$PACKAGE/Artifacts/.ssh_cmd.source-ref"
SOURCE="$ROOT/vendor/ios_system-rootshell"

OPENSSL_URL="https://github.com/holzschu/openssl-apple/releases/download/v1.1.1w/openssl-dynamic.xcframework.zip"
OPENSSL_SHA256="329e8317cf9bee8e138da5d032330a7a1bd2473cf44c9c083cb2f0636abb8b80"
LIBSSH2_URL="https://github.com/holzschu/libssh2-apple/releases/download/v1.11.0/libssh2-dynamic.xcframework.zip"
LIBSSH2_SHA256="cacfe1789b197b727119f7e32f561eaf9acc27bf38cd19975b74fce107f868a6"

# The vendored source revision is the cache key: a vendor update rebuilds.
STAMP="$(awk '$1 == "ios_system-rootshell" { print $3 }' "$ROOT/vendor/manifest")"

if [[ "${1:-}" != "--force" && -f "$STAMP_FILE" && "$(cat "$STAMP_FILE")" == "$STAMP" ]]; then
    echo "ssh_cmd.xcframework is current ($STAMP)"
    exit 0
fi

fetch() {  # url sha256 destdir
    local url="$1" sha="$2" dest="$3"
    local zip="$WORK/deps/$(basename "$url")"
    if [[ ! -f "$zip" ]] || ! echo "$sha  $zip" | shasum -a 256 -c - >/dev/null 2>&1; then
        curl -fsSL -o "$zip" "$url"
    fi
    echo "$sha  $zip" | shasum -a 256 -c - >/dev/null || {
        echo "ERROR: checksum mismatch for $url" >&2
        exit 1
    }
    rm -rf "$dest"
    mkdir -p "$dest"
    unzip -q "$zip" -d "$dest"
}

rm -rf "$WORK/src" "$WORK/archives"
mkdir -p "$WORK/deps" "$WORK/archives"
fetch "$OPENSSL_URL" "$OPENSSL_SHA256" "$WORK/deps/openssl"
fetch "$LIBSSH2_URL" "$LIBSSH2_SHA256" "$WORK/deps/libssh2"

rsync -a --exclude .build "$SOURCE/" "$WORK/src/"
sed -i '' \
    -e 's#path = "../openssl_ios/.build/libssl.xcframework"#path = "../deps/openssl/openssl.xcframework"#' \
    -e 's#path = "../libssh2-for-iOS/libssh2.xcframework"#path = "../deps/libssh2/libssh2.xcframework"#' \
    "$WORK/src/ios_system.xcodeproj/project.pbxproj"

ARGS=()
for destination in "generic/platform=iOS" "generic/platform=iOS Simulator" "generic/platform=macOS,variant=Mac Catalyst"; do
    name="$(echo "$destination" | tr -c 'A-Za-z0-9' '_')"
    archive="$WORK/archives/$name.xcarchive"
    echo "Archiving ssh_cmd for $destination..."
    xcrun xcodebuild archive \
        -project "$WORK/src/ios_system.xcodeproj" \
        -scheme ssh_cmd \
        -configuration Release \
        -destination "$destination" \
        -archivePath "$archive" \
        -derivedDataPath "$WORK/dd" \
        SKIP_INSTALL=NO \
        CODE_SIGNING_ALLOWED=NO \
        > "$WORK/archives/$name.log" 2>&1 || {
            echo "ERROR: archive failed; see $WORK/archives/$name.log" >&2
            grep -E "error:" "$WORK/archives/$name.log" | sort -u | head -20 >&2
            exit 1
        }
    ARGS+=(-framework "$archive/Products/Library/Frameworks/ssh_cmd.framework")
done

rm -rf "$OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"
xcrun xcodebuild -create-xcframework "${ARGS[@]}" -output "$OUTPUT" >/dev/null
echo "$STAMP" > "$STAMP_FILE"
echo "Built $OUTPUT ($STAMP)"
