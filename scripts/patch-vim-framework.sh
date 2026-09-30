#!/bin/sh
#
# Repoints the embedded Mac Catalyst vim.framework away from Homebrew's
# libsodium and ships a stub in its place.
#
# The arm64 Mac Catalyst slice of vim-rootshell v0.1.0 (vendor/vim-rootshell)
# was built on a Mac with Homebrew libsodium installed, so its binary carries
#     LC_LOAD_DYLIB /opt/homebrew/opt/libsodium/lib/libsodium.26.dylib
# Without that file dyld refuses to launch Shell.app at all ("Library not
# loaded"). The other slices and the other command frameworks are clean.
#
# This script runs after Xcode has embedded the package frameworks. It compiles
# scripts/libsodium-stub.c into Contents/Frameworks/libsodium.26.dylib, rewrites
# vim's load command to @rpath/libsodium.26.dylib, and re-signs both. It is a
# no-op for every platform except Mac Catalyst and is idempotent, so rerunning
# it on an already patched build only refreshes the stub.
#
# Usage: from a Run Script phase of the shell target (uses the build settings),
# or standalone as `scripts/patch-vim-framework.sh path/to/Shell.app`, which
# signs with the identity the app is already signed with.

set -eu

HOMEBREW_SODIUM=/opt/homebrew/opt/libsodium/lib/libsodium.26.dylib
STUB_INSTALL_NAME=@rpath/libsodium.26.dylib
STUB_SOURCE="$(cd "$(dirname "$0")" && pwd)/libsodium-stub.c"

if [ $# -ge 1 ]; then
    APP="$1"
    STANDALONE=1
else
    if [ "${EFFECTIVE_PLATFORM_NAME:-}" != "-maccatalyst" ]; then
        echo "note: vim.framework needs patching only in Mac Catalyst builds; skipping for ${PLATFORM_NAME:-unknown}${EFFECTIVE_PLATFORM_NAME:-}"
        exit 0
    fi
    APP="${TARGET_BUILD_DIR}/${WRAPPER_NAME}"
    STANDALONE=
fi

FRAMEWORKS="${APP}/Contents/Frameworks"
VIM_FRAMEWORK="${FRAMEWORKS}/vim.framework"
VIM_BINARY="${VIM_FRAMEWORK}/vim"
STUB="${FRAMEWORKS}/libsodium.26.dylib"

if [ ! -f "${VIM_BINARY}" ]; then
    echo "warning: ${VIM_BINARY} not found; vim.framework was not embedded before this script ran, so its libsodium load command is still unpatched"
    exit 0
fi

# Architectures and SDK: from the build when run as a phase, from the embedded
# binary when run standalone. Catalyst builds do not export the iOS deployment
# target to script phases; the stub only has to load into the process, so the
# package's own floor (macCatalyst 14) is used as the minimum OS.
if [ -n "${STANDALONE}" ]; then
    ARCHS="$(lipo -archs "${VIM_BINARY}")"
    SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
fi
: "${ARCHS:?ARCHS is not set}"
: "${SDKROOT:?SDKROOT is not set}"
STUB_MIN_OS="${IPHONEOS_DEPLOYMENT_TARGET:-14.0}"

# Signing identity: the build's, or the one the app already carries when run
# standalone. Ad-hoc signing is the last resort; it is enough for a local run.
if [ -n "${STANDALONE}" ]; then
    IDENTITY="$(codesign -dvv "${APP}" 2>&1 | sed -n 's/^Authority=//p' | head -n 1)"
    IDENTITY="${IDENTITY:--}"
    CODE_SIGNING_ALLOWED=YES
elif [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY}"
else
    IDENTITY=
fi
if [ "${ACTION:-build}" = "install" ]; then
    TIMESTAMP_FLAG="--timestamp"
else
    TIMESTAMP_FLAG="--timestamp=none"
fi

# sign PATH [extra codesign flags...]
# OTHER_CODE_SIGN_FLAGS is how the build system passes e.g. a keychain to
# codesign; it is intentionally unquoted so it splits into arguments.
sign() {
    target="$1"
    shift
    if [ -z "${IDENTITY}" ]; then
        echo "warning: ${target##*/} left unsigned because code signing is disabled for this build"
        return 0
    fi
    codesign --force \
        --sign "${IDENTITY}" \
        "${TIMESTAMP_FLAG}" \
        ${OTHER_CODE_SIGN_FLAGS:-} \
        "$@" \
        "${target}"
}

# 1. Build the stub for every architecture of this build and place it next to
#    the command frameworks, where @rpath (@executable_path/../Frameworks)
#    resolves it.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/libsodium-stub.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

slices=
for arch in ${ARCHS}; do
    slice="${TMP}/libsodium.26.${arch}.dylib"
    xcrun clang \
        -target "${arch}-apple-ios${STUB_MIN_OS}-macabi" \
        -isysroot "${SDKROOT}" \
        -dynamiclib -O2 -Wall -Wextra \
        -install_name "${STUB_INSTALL_NAME}" \
        -compatibility_version 29 -current_version 29 \
        -o "${slice}" "${STUB_SOURCE}"
    slices="${slices} ${slice}"
done
# shellcheck disable=SC2086 # slices is a space-separated list of paths
lipo -create ${slices} -output "${TMP}/libsodium.26.dylib"
ditto "${TMP}/libsodium.26.dylib" "${STUB}"
sign "${STUB}"

# 2. Rewrite vim's load command. install_name_tool edits every slice that has
#    the old name and leaves the others alone; the new name is shorter, so no
#    header padding is needed.
if otool -L "${VIM_BINARY}" | grep -q "${HOMEBREW_SODIUM}"; then
    # install_name_tool warns that the edit invalidates the signature, which
    # Xcode would show as a build warning; the check below and the re-sign
    # cover both, so its stderr is dropped.
    install_name_tool -change "${HOMEBREW_SODIUM}" "${STUB_INSTALL_NAME}" "${VIM_BINARY}" 2>/dev/null
    if otool -L "${VIM_BINARY}" | grep -q "${HOMEBREW_SODIUM}"; then
        echo "error: install_name_tool did not remove ${HOMEBREW_SODIUM} from ${VIM_BINARY}"
        exit 1
    fi
    # Editing the binary invalidated the framework's signature; re-sign it
    # keeping the identifier and flags Xcode gave it when embedding.
    sign "${VIM_FRAMEWORK}" --preserve-metadata=identifier,entitlements,flags
    echo "note: vim.framework now loads ${STUB_INSTALL_NAME} instead of ${HOMEBREW_SODIUM}"
else
    echo "note: vim.framework already free of ${HOMEBREW_SODIUM}"
fi
