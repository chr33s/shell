#!/bin/bash
set -euo pipefail

# Build the Zig GhosttyKit App Store variant and install it into a local Swift
# package override. Normal app builds use the pinned remote binary package.
#
# Usage:
#   ./scripts/build-framework.sh [appstore]
#       [--ghostty-source <path>] [--zig <path>] [--clean]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

VARIANT="appstore"
GHOSTTY_SOURCE="${GHOSTTY_SOURCE_DIR:-${GHOSTTY_DIR:-}}"
ZIG_BIN="${ZIG_BIN:-}"
CLEAN="${CLEAN:-false}"
SENTRY="${SENTRY:-false}"

if [[ $# -gt 0 && "$1" != --* ]]; then
    VARIANT="$1"
    shift
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ghostty-source)
            GHOSTTY_SOURCE="${2:-}"
            shift 2
            ;;
        --zig)
            ZIG_BIN="${2:-}"
            shift 2
            ;;
        --clean)
            CLEAN=true
            shift
            ;;
        -h|--help)
            sed -n '4,9p' "$0"
            exit 0
            ;;
        *)
            echo "ERROR: unknown option: $1" >&2
            exit 1
            ;;
    esac
done

case "$VARIANT" in
    appstore) ;;
    *)
        echo "ERROR: expected appstore; got '$VARIANT'" >&2
        exit 1
        ;;
esac

if [[ -z "$GHOSTTY_SOURCE" && -f "$PROJECT_DIR/../ghostty/build.zig" ]]; then
    GHOSTTY_SOURCE="$PROJECT_DIR/../ghostty"
fi
if [[ -z "$GHOSTTY_SOURCE" ]]; then
    echo "ERROR: Ghostty source not found." >&2
    echo "Pass --ghostty-source <path> or set GHOSTTY_SOURCE_DIR." >&2
    exit 1
fi
GHOSTTY_SOURCE="$(cd "$GHOSTTY_SOURCE" 2>/dev/null && pwd)" || {
    echo "ERROR: Ghostty source directory does not exist: $GHOSTTY_SOURCE" >&2
    exit 1
}
if [[ ! -f "$GHOSTTY_SOURCE/build.zig" ]]; then
    echo "ERROR: not a Ghostty source checkout: $GHOSTTY_SOURCE" >&2
    exit 1
fi

if [[ -z "$ZIG_BIN" ]]; then
    if command -v brew >/dev/null 2>&1; then
        ZIG_016_PREFIX="$(brew --prefix zig@0.16 2>/dev/null || true)"
        if [[ -x "$ZIG_016_PREFIX/bin/zig" ]]; then
            ZIG_BIN="$ZIG_016_PREFIX/bin/zig"
        fi
    fi
fi
if [[ -z "$ZIG_BIN" ]]; then
    ZIG_BIN="$(command -v zig || true)"
fi
if [[ -z "$ZIG_BIN" || ! -x "$ZIG_BIN" ]]; then
    echo "ERROR: Zig was not found. Pass --zig <path> or set ZIG_BIN." >&2
    exit 1
fi
ZIG_VERSION="$($ZIG_BIN version)"
if [[ "$ZIG_VERSION" != 0.16.* ]]; then
    echo "ERROR: GhosttyKit currently requires Zig 0.16.x; found $ZIG_VERSION" >&2
    exit 1
fi

# Zig 0.16 supports visionOS and the `.maccatalyst` OS tag upstream; no stdlib
# patch is needed, so we build against the stock toolchain.
LOCAL_BUILD_DIR="$PROJECT_DIR/.build/ghosttykit"
LOCAL_PACKAGE_DIR="$PROJECT_DIR/.local-packages/ghosttykit-rootshell"
ARTIFACTS_DIR="$LOCAL_PACKAGE_DIR/Artifacts"
mkdir -p "$ARTIFACTS_DIR/AppStore"

if [[ "$CLEAN" == true ]]; then
    echo "Cleaning Ghostty build outputs..."
    rm -rf "$GHOSTTY_SOURCE/.zig-cache" "$GHOSTTY_SOURCE/zig-out"
fi

echo "Ghostty source: $GHOSTTY_SOURCE"
echo "Ghostty revision: $(git -C "$GHOSTTY_SOURCE" rev-parse --short HEAD 2>/dev/null || echo unknown)"
echo "Zig: $ZIG_BIN ($ZIG_VERSION)"
echo "Local package: $LOCAL_PACKAGE_DIR"

strip_and_audit() {
    local framework="$1"
    local library path_count
    while IFS= read -r library; do
        xcrun strip -S "$library"
        path_count="$(strings "$library" | grep -Ec '/Users/|/home/[^/]+/' || true)"
        if [[ "$path_count" -ne 0 ]]; then
            echo "ERROR: build-machine path remains in $library" >&2
            strings "$library" | grep -E -m 10 '/Users/|/home/[^/]+/' >&2 || true
            exit 1
        fi
    done < <(find "$framework" -type f -name '*.a' -print)
}

verify_variant() {
    local variant="$1" framework="$2"
    local catalyst
    catalyst="$(find "$framework" -path '*-maccatalyst*' -type f -name '*.a' -print -quit)"
    if [[ -z "$catalyst" ]]; then
        echo "ERROR: no Mac Catalyst library in $framework" >&2
        exit 1
    fi

    local cgs_count breakpad_count
    cgs_count="$(nm -g "$catalyst" 2>/dev/null | grep -c CGS || true)"
    breakpad_count="$(find "$framework" -type f -name '*.a' -exec nm {} + 2>/dev/null | grep -c google_breakpad || true)"
    if [[ "$SENTRY" == false && "$breakpad_count" -ne 0 ]]; then
        echo "ERROR: Breakpad symbols found with SENTRY=false" >&2
        exit 1
    fi
    if [[ "$variant" == appstore && "$cgs_count" -ne 0 ]]; then
        echo "ERROR: App Store GhosttyKit contains $cgs_count CGS symbols" >&2
        exit 1
    fi
    local init_count
    init_count="$(nm -g "$catalyst" 2>/dev/null | grep -c '_ghostty_init' || true)"
    if [[ "$init_count" -eq 0 ]]; then
        echo "ERROR: staged library does not export ghostty_init" >&2
        exit 1
    fi
}

build_variant() {
    local variant="$1" target output_name package_name package_subdir appstore
    case "$variant" in
        appstore)
            target=rootshell_appstore
            output_name=GhosttyKitAppStore.xcframework
            package_name=GhosttyKitAppStore.xcframework
            package_subdir=AppStore
            appstore=true
            ;;
    esac

    echo "Building GhosttyKit $variant..."
    (
        cd "$GHOSTTY_SOURCE"
        "$ZIG_BIN" build \
            -Dxcframework-target="$target" \
            -Doptimize=ReleaseFast \
            -Dappstore="$appstore" \
            -Dsentry="$SENTRY" \
            --prefix "$GHOSTTY_SOURCE/zig-out"
    )

    local built="$GHOSTTY_SOURCE/macos/$output_name"
    if [[ ! -d "$built" ]]; then
        echo "ERROR: Ghostty did not produce $built" >&2
        exit 1
    fi

    local build_id revision
    revision="$(git -C "$GHOSTTY_SOURCE" rev-parse --short HEAD 2>/dev/null || echo local)"
    build_id="${revision}-$(date -u +%Y%m%d%H%M%S)"
    local destination="$ARTIFACTS_DIR/$package_subdir/$build_id/$package_name"
    mkdir -p "$(dirname "$destination")"
    ditto "$built" "$destination"
    strip_and_audit "$destination"
    verify_variant "$variant" "$destination"
    printf '%s\n' "$build_id" > "$ARTIFACTS_DIR/$package_subdir/current"
}

build_variant appstore

if [[ -d "$GHOSTTY_SOURCE/zig-out/share/terminfo" ]]; then
    while IFS= read -r source_entry; do
        entry_name="$(basename "$source_entry")"
        destination_entry="$PROJECT_DIR/Resources/terminfo/$entry_name"
        rm -rf "$destination_entry"
        cp -RL "$source_entry" "$destination_entry"
    done < <(find "$GHOSTTY_SOURCE/zig-out/share/terminfo" -mindepth 1 -maxdepth 1 -type d -print)
fi

APPSTORE_ID="$(cat "$ARTIFACTS_DIR/AppStore/current" 2>/dev/null || true)"
if [[ -z "$APPSTORE_ID" ]]; then
    echo "Built $VARIANT, but no App Store build id was recorded." >&2
    exit 0
fi

cat > "$LOCAL_PACKAGE_DIR/Package.swift" <<EOF
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ghosttykit-rootshell",
    platforms: [.iOS(.v17), .macCatalyst(.v17), .visionOS(.v1)],
    products: [
        .library(name: "GhosttyKitAppStore", targets: ["GhosttyKitAppStore"]),
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyKitAppStore",
            path: "Artifacts/AppStore/$APPSTORE_ID/GhosttyKitAppStore.xcframework"
        ),
    ]
)
EOF

echo "GhosttyKit local package is ready: $LOCAL_PACKAGE_DIR"
