#!/bin/bash
# Archive Shell in Release for one platform and export an App Store package.
#
# Usage: ./scripts/archive.sh <ios|ipados|visionos|maccatalyst> [output-dir]
#
# `ios` and `ipados` are the same archive — Shell targets device families 1 and
# 2, so one iOS build serves iPhone and iPad; `ipados` is accepted as an alias
# so callers can name what they mean. There is no watchOS archive: ShellWatch is
# embedded in Shell.app by the iOS build and ships with it.
#
# Signing is resolved by Xcode itself via -allowProvisioningUpdates against an
# App Store Connect API key, so no provisioning profile is committed or stored
# in CI. The matching distribution certificate must already be in the keychain:
# Apple Distribution for iOS/visionOS, Apple Distribution plus a Mac
# Installer certificate for Mac Catalyst, whose export is a .pkg rather than an
# .ipa.
#
# Required environment:
#   ASC_KEY_ID          App Store Connect API key id
#   ASC_ISSUER_ID       App Store Connect API issuer id
#   ASC_KEY_PATH        Path to the AuthKey_<id>.p8 private key
# Optional:
#   BUILD_NUMBER        Value for CURRENT_PROJECT_VERSION (default: 1)
#   BUILD_SETTINGS      Extra `NAME=value` xcodebuild overrides, space separated
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM="${1:?usage: archive.sh <ios|ipados|visionos|maccatalyst> [output-dir]}"

case "$PLATFORM" in
    ios|ipados) SCHEME=shell;      DESTINATION='generic/platform=iOS' ;;
    visionos)   SCHEME=shell;      DESTINATION='generic/platform=visionOS' ;;
    maccatalyst) SCHEME=shell;     DESTINATION='generic/platform=macOS,variant=Mac Catalyst' ;;
    *) echo "unknown platform: $PLATFORM" >&2; exit 2 ;;
esac

OUT="${2:-$ROOT/.derivedData/export-$PLATFORM}"
ARCHIVE="$ROOT/.derivedData/Shell-$PLATFORM.xcarchive"
LOG="$ROOT/.derivedData/archive-$PLATFORM.log"

: "${ASC_KEY_ID:?set ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
: "${ASC_KEY_PATH:?set ASC_KEY_PATH}"

mkdir -p "$OUT" "$(dirname "$LOG")"
rm -rf "$ARCHIVE"

AUTH=(
    -allowProvisioningUpdates
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
    -authenticationKeyPath "$ASC_KEY_PATH"
)

# Word splitting is what BUILD_SETTINGS is for: it carries zero or more
# `NAME=value` overrides.
# shellcheck disable=SC2206
OVERRIDES=(CURRENT_PROJECT_VERSION="${BUILD_NUMBER:-1}" ${BUILD_SETTINGS:-})

archive_status=0
xcodebuild \
    -project "$ROOT/shell.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "$DESTINATION" \
    -archivePath "$ARCHIVE" \
    -derivedDataPath "$ROOT/.derivedData" \
    "${OVERRIDES[@]}" \
    "${AUTH[@]}" \
    archive > "$LOG" 2>&1 || archive_status=$?

if [[ $archive_status -ne 0 ]]; then
    grep "error:" "$LOG" \
        | sed "s|$ROOT/||" \
        | sed 's/:[0-9]*:[0-9]*: error: /: /' \
        | sort \
        | uniq -c \
        | sort -rn \
        | head -60
    echo "--- error count: $(grep -c 'error:' "$LOG") ---"
    exit $archive_status
fi

cat > "$OUT/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>export</string>
    <key>teamID</key>
    <string>D97ZME3ET2</string>
    <key>uploadSymbols</key>
    <true/>
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$OUT" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" \
    "${AUTH[@]}"

# iOS and visionOS export an .ipa; a Mac App Store export is a .pkg.
package="$(ls "$OUT"/*.ipa "$OUT"/*.pkg 2>/dev/null | head -1)"
if [[ -z "$package" ]]; then
    echo "no .ipa or .pkg in $OUT" >&2
    exit 1
fi
echo "package: $package"
