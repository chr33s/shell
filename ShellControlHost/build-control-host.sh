#!/bin/sh
#
# Builds ShellControlHost (a native macOS app) in its own xcodebuild
# invocation and copies it into the Mac Catalyst Shell.app at
# Contents/Library/LaunchAgents, where the launchd plist expects it.
#
# Why this is a script rather than a target dependency: during an archive,
# Xcode writes the object files of Swift package targets to
# UninstalledProducts/<PLATFORM_NAME>/, and PLATFORM_NAME is "macosx" for both
# Mac Catalyst and native macOS. Shell (Catalyst) and ShellControlHost (macOS)
# both build ShellControlProtocol, ShellControlSecurity, and ShellControlClient,
# so a single build graph fails with "Multiple commands produce ....o". Debug
# builds place products in per-variant directories and never hit this. A
# separate build graph for the helper is the only known workaround
# (developer.apple.com/forums/thread/814686).
#
# Run by the "Build Control Host" phase of the shell target. It is a no-op for
# every platform except Mac Catalyst, so iOS, visionOS, and watchOS builds
# contain no trace of the host.

set -eu

if [ "${EFFECTIVE_PLATFORM_NAME:-}" != "-maccatalyst" ]; then
    echo "note: ShellControlHost is only embedded in Mac Catalyst builds; skipping for ${PLATFORM_NAME:-unknown}${EFFECTIVE_PLATFORM_NAME:-}"
    exit 0
fi

HOST_SYMROOT="${BUILD_DIR}/ControlHost"
HOST_OBJROOT="${OBJROOT}/ControlHost"
HOST_PRODUCT="${HOST_SYMROOT}/${CONFIGURATION}/ShellControlHost.app"
DESTINATION_DIR="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Library/LaunchAgents"
DESTINATION="${DESTINATION_DIR}/ShellControlHost.app"

# env -i keeps the parent build's exported settings (Catalyst SDK and platform,
# DEPLOYMENT_LOCATION and DSTROOT during archives, signing inputs) from leaking
# into the nested build. Only the toolchain selection is passed through.
env -i \
    PATH="${PATH}" \
    HOME="${HOME}" \
    TMPDIR="${TMPDIR:-/tmp}" \
    ${DEVELOPER_DIR:+DEVELOPER_DIR="${DEVELOPER_DIR}"} \
    xcodebuild \
        -project "${PROJECT_FILE_PATH}" \
        -target ShellControlHost \
        -configuration "${CONFIGURATION}" \
        -sdk macosx \
        SYMROOT="${HOST_SYMROOT}" \
        OBJROOT="${HOST_OBJROOT}" \
        -quiet \
        build

mkdir -p "${DESTINATION_DIR}"
rm -rf "${DESTINATION}"
ditto "${HOST_PRODUCT}" "${DESTINATION}"

# Mirror the "Code Sign On Copy" behaviour of the Copy Files phase this
# replaces: the nested bundle is re-signed with the app's identity while
# keeping its own identifier, entitlements, and hardened-runtime flags.
if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    if [ "${ACTION:-build}" = "install" ]; then
        TIMESTAMP_FLAG="--timestamp"
    else
        TIMESTAMP_FLAG="--timestamp=none"
    fi
    codesign --force \
        --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
        --preserve-metadata=identifier,entitlements,flags \
        --generate-entitlement-der \
        "${TIMESTAMP_FLAG}" \
        "${DESTINATION}"
fi
