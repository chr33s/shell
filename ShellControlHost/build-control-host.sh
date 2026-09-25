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
HOST_ENTITLEMENTS="${SRCROOT}/ShellControlHost/ShellControlHost.entitlements"
DESTINATION_DIR="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Library/LaunchAgents"
DESTINATION="${DESTINATION_DIR}/ShellControlHost.app"

# env -i keeps the parent build's exported settings (Catalyst SDK and platform,
# DEPLOYMENT_LOCATION and DSTROOT during archives, signing inputs) from leaking
# into the nested build. Only the toolchain selection is passed through.
# The helper is built for the same architectures as the app: the active one in
# a regular build, every one in an archive. Index data is disabled: Xcode
# indexes the ShellControlHost target itself, and with no index store
# directory configured the nested build would write one to a stray "-Xcc"
# folder inside the project bundle.
# Extra arguments are xcodebuild setting overrides.
build_host() {
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
            ARCHS="${ARCHS}" \
            ONLY_ACTIVE_ARCH=NO \
            COMPILER_INDEX_STORE_ENABLE=NO \
            -quiet \
            build \
            "$@"
}

# Two signing modes for the nested build:
#
#   project   The target's own automatic signing, as the former target
#             dependency did. Needs the development certificate and a profile
#             for dev.chr33s.shell.control-host on this Mac (its App Groups
#             entitlement requires a profile). The copy is then re-signed with
#             the app's identity while keeping Xcode's generated entitlements
#             and flags, which is what Copy Files "Code Sign On Copy" does.
#
#   explicit  The nested build is left unsigned and the copy is signed here
#             with the app's identity, the target's entitlements file, and
#             hardened runtime. Xcode Cloud's cloud-managed signing is not
#             reachable from a nested xcodebuild, so it always takes this path;
#             the distribution step re-signs and provisions nested bundles.
if [ -n "${CI_XCODE_CLOUD:-}" ]; then
    SIGNING=explicit
else
    SIGNING=project
fi

if [ "${SIGNING}" = project ]; then
    if ! build_host; then
        echo "note: ShellControlHost could not be built with its own signing; retrying unsigned and signing the copy explicitly"
        SIGNING=explicit
    fi
fi
if [ "${SIGNING}" = explicit ]; then
    build_host CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
fi

mkdir -p "${DESTINATION_DIR}"
rm -rf "${DESTINATION}"
ditto "${HOST_PRODUCT}" "${DESTINATION}"

if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    if [ "${ACTION:-build}" = "install" ]; then
        TIMESTAMP_FLAG="--timestamp"
    else
        TIMESTAMP_FLAG="--timestamp=none"
    fi
    # OTHER_CODE_SIGN_FLAGS is how the build system passes e.g. a keychain to
    # codesign; it is intentionally unquoted so it splits into arguments.
    if [ "${SIGNING}" = project ]; then
        codesign --force \
            --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
            --preserve-metadata=identifier,entitlements,flags \
            --generate-entitlement-der \
            "${TIMESTAMP_FLAG}" \
            ${OTHER_CODE_SIGN_FLAGS:-} \
            "${DESTINATION}"
    else
        codesign --force \
            --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
            --entitlements "${HOST_ENTITLEMENTS}" \
            --options runtime \
            --generate-entitlement-der \
            "${TIMESTAMP_FLAG}" \
            ${OTHER_CODE_SIGN_FLAGS:-} \
            "${DESTINATION}"
    fi
elif [ "${SIGNING}" = explicit ]; then
    echo "warning: ShellControlHost.app was embedded unsigned because code signing is disabled for this build"
fi
