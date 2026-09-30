#!/bin/bash
set -euo pipefail

version="${1:-}"
if [[ ! "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: $0 vMAJOR.MINOR.PATCH" >&2
    exit 1
fi

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(dirname "$script_dir")"
ios_system_repo="${IOS_SYSTEM_SOURCE_DIR:-$(dirname "$repo_root")/ios_system}"
openssl_ios_repo="${OPENSSL_IOS_SOURCE_DIR:-$(dirname "$repo_root")/openssl_ios}"
openssl_repo="${OPENSSL_SOURCE_DIR:-$(dirname "$repo_root")/openssl}"
temp_root=""

cleanup() {
    if [[ -n "$temp_root" ]]; then
        git -C "$ios_system_repo" worktree remove --force "$temp_root/ios_system" >/dev/null 2>&1 || true
        git -C "$openssl_repo" worktree remove --force "$temp_root/openssl" >/dev/null 2>&1 || true
        rm -rf "$temp_root"
    fi
}
trap cleanup EXIT

cd "$repo_root"

git diff --quiet && git diff --cached --quiet || {
    echo "error: release requires a clean curl worktree" >&2
    exit 1
}
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || {
    echo "error: release requires a clean curl worktree" >&2
    exit 1
}
git rev-parse --verify "refs/tags/$version" >/dev/null 2>&1 && {
    echo "error: tag already exists: $version" >&2
    exit 1
}
git submodule status | grep -q '^-' && {
    echo "error: initialize submodules before releasing" >&2
    exit 1
}
git submodule status | grep -q '^+' && {
    echo "error: nghttp2 is not at the pinned submodule revision" >&2
    exit 1
}

for command in gh swift xcodebuild cmake python3; do
    command -v "$command" >/dev/null || {
        echo "error: required command not found: $command" >&2
        exit 1
    }
done
gh auth status >/dev/null

for repo in "$ios_system_repo" "$openssl_ios_repo" "$openssl_repo"; do
    [[ -d "$repo/.git" ]] || {
        echo "error: required checkout not found: $repo" >&2
        exit 1
    }
done
[[ -x "$openssl_ios_repo/build.sh" ]] || {
    echo "error: OpenSSL wrapper not found: $openssl_ios_repo/build.sh" >&2
    exit 1
}

git -C "$openssl_ios_repo" diff --quiet && git -C "$openssl_ios_repo" diff --cached --quiet || {
    echo "error: release requires a clean OpenSSL wrapper worktree" >&2
    exit 1
}
openssl_wrapper_revision="$(git -C "$openssl_ios_repo" rev-parse HEAD)"

ios_system_revision="$(git -C "$ios_system_repo" rev-parse 'v0.1.0^{commit}')"
openssl_revision="$(git -C "$openssl_repo" rev-parse 'openssl-3.5.4^{commit}')"
temp_root="$(mktemp -d "${TMPDIR:-/tmp}/curl-rootshell-release.XXXXXX")"
git -C "$ios_system_repo" worktree add --detach "$temp_root/ios_system" "$ios_system_revision"
git -C "$openssl_repo" worktree add --detach "$temp_root/openssl" "$openssl_revision"

echo "Building ios_system at $ios_system_revision"
(
    cd "$temp_root/ios_system"
    swift run --package-path xcfs build ios_system
)

echo "Building OpenSSL at $openssl_revision"
OPENSSL_SOURCE_DIR="$temp_root/openssl" "$openssl_ios_repo/build.sh"

python3 "$script_dir/verify-apple-compatibility.py" \
    --openssl-build "$openssl_ios_repo/.build"

echo "Building curl"
IOS_SYSTEM_SOURCE_DIR="$temp_root/ios_system" \
OPENSSL_IOS_SOURCE_DIR="$openssl_ios_repo" \
swift run --package-path xcfs build

xcframework="$repo_root/.build/curl_ios.xcframework"
asset="$repo_root/.build/curl_ios.xcframework.zip"
release_notes="$repo_root/.build/release.md"
expected_slices=(
    ios-arm64
    ios-arm64-simulator
    ios-arm64_x86_64-maccatalyst
    xros-arm64
    xros-arm64-simulator
)

for slice in "${expected_slices[@]}"; do
    [[ -d "$xcframework/$slice" ]] || {
        echo "error: missing required XCFramework slice: $slice" >&2
        exit 1
    }
done
[[ "$(find "$xcframework" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" == "5" ]] || {
    echo "error: unexpected XCFramework slice count" >&2
    exit 1
}

device_binary="$xcframework/ios-arm64/curl_ios.framework/curl_ios"
nm -gU "$device_binary" | grep ' _curl_main$' >/dev/null || {
    echo "error: curl_main is not exported" >&2
    exit 1
}
xcrun otool -L "$device_binary" | grep '@rpath/ios_system.framework/ios_system' >/dev/null || {
    echo "error: ios_system runtime dependency is missing" >&2
    exit 1
}

python3 "$script_dir/verify-apple-compatibility.py" --xcframework "$xcframework"

printf '\nOpenSSL wrapper revision: `%s`\n' "$openssl_wrapper_revision" >> "$release_notes"

checksum="$(swift package compute-checksum "$asset")"
VERSION="$version" CHECKSUM="$checksum" perl -0pi -e '
    s{/releases/download/v[^/]+/curl_ios\.xcframework\.zip}{/releases/download/$ENV{VERSION}/curl_ios.xcframework.zip};
    s{checksum: "[a-f0-9]+"}{checksum: "$ENV{CHECKSUM}"};
' Package.swift

swift package dump-package >/dev/null
git diff --check
git add Package.swift
if ! git diff --cached --quiet; then
    git commit -m "Prepare $version binary release"
fi

git tag -a "$version" -m "curl_ios-rootshell $version"
git push origin main
git push origin "$version"
gh release create "$version" "$asset#curl_ios.xcframework.zip" \
    --repo kitknox/curl_ios-rootshell \
    --title "curl_ios-rootshell $version" \
    --notes-file "$release_notes" \
    --verify-tag

echo "Published $version with SwiftPM checksum $checksum"
