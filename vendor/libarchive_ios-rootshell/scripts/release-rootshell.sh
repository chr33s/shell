#!/bin/bash
set -euo pipefail

version="${1:-}"
if [[ ! "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: $0 vMAJOR.MINOR.PATCH" >&2
    exit 1
fi

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(dirname "$script_dir")"
sibling_root="$(dirname "$repo_root")"
libarchive_repo="${LIBARCHIVE_SOURCE_DIR:-$sibling_root/libarchive}"
xz_repo="${XZ_SOURCE_DIR:-$sibling_root/xz}"
xz_ios_repo="${XZ_IOS_SOURCE_DIR:-$sibling_root/xz_ios}"
ios_system_repo="${IOS_SYSTEM_SOURCE_DIR:-$sibling_root/ios_system}"
libarchive_revision="4613cc9d7926bc175d25ca07ddecfee22f0d45fa"
xz_revision="cdae0df31e4c2dfb1e885941cd1998e5a2b6e39d"
xz_ios_revision="d15706de071d154eaf55fd6e6010285c40428170"
ios_system_revision="8f84ebfc7ee44cb05402cabdd1a82b4214a173cd"
temp_root=""

cleanup() {
    if [[ -n "$temp_root" ]]; then
        git -C "$libarchive_repo" worktree remove --force "$temp_root/libarchive" >/dev/null 2>&1 || true
        git -C "$xz_repo" worktree remove --force "$temp_root/xz" >/dev/null 2>&1 || true
        git -C "$xz_ios_repo" worktree remove --force "$temp_root/xz_ios" >/dev/null 2>&1 || true
        git -C "$ios_system_repo" worktree remove --force "$temp_root/ios_system" >/dev/null 2>&1 || true
        rm -rf "$temp_root"
    fi
}
trap cleanup EXIT

cd "$repo_root"

git diff --quiet && git diff --cached --quiet || {
    echo "error: release requires a clean libarchive_ios worktree" >&2
    exit 1
}
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || {
    echo "error: release requires a clean libarchive_ios worktree" >&2
    exit 1
}
[[ -z "$(git ls-files .github)" && ! -d .github ]] || {
    echo "error: .github must not exist in the rootshell fork" >&2
    exit 1
}
git rev-parse --verify "refs/tags/$version" >/dev/null 2>&1 && {
    echo "error: tag already exists: $version" >&2
    exit 1
}
[[ "$(git remote get-url origin)" == "git@github.com:kitknox/libarchive_ios-rootshell.git" ]] || {
    echo "error: origin must be git@github.com:kitknox/libarchive_ios-rootshell.git" >&2
    exit 1
}

for command in gh swift xcodebuild cmake nm xcrun zip perl; do
    command -v "$command" >/dev/null || {
        echo "error: required command not found: $command" >&2
        exit 1
    }
done
gh auth status >/dev/null

for repo in "$libarchive_repo" "$xz_repo" "$xz_ios_repo" "$ios_system_repo"; do
    git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || {
        echo "error: required checkout not found: $repo" >&2
        exit 1
    }
done

git -C "$libarchive_repo" cat-file -e "$libarchive_revision^{commit}"
git -C "$xz_repo" cat-file -e "$xz_revision^{commit}"
git -C "$xz_ios_repo" cat-file -e "$xz_ios_revision^{commit}"
git -C "$ios_system_repo" cat-file -e "$ios_system_revision^{commit}"

temp_root="$(mktemp -d "${TMPDIR:-/tmp}/libarchive-rootshell-release.XXXXXX")"
git -C "$libarchive_repo" worktree add --detach "$temp_root/libarchive" "$libarchive_revision"
git -C "$xz_repo" worktree add --detach "$temp_root/xz" "$xz_revision"
git -C "$xz_ios_repo" worktree add --detach "$temp_root/xz_ios" "$xz_ios_revision"
git -C "$ios_system_repo" worktree add --detach "$temp_root/ios_system" "$ios_system_revision"

echo "Building ios_system at $ios_system_revision"
(
    cd "$temp_root/ios_system"
    swift run --package-path xcfs build ios_system
)

echo "Building xz_ios at $xz_ios_revision"
(
    cd "$temp_root/xz_ios"
    IOS_SYSTEM_SOURCE_DIR="$temp_root/ios_system" \
    XZ_SOURCE_DIR="$temp_root/xz" \
    swift run --package-path xcfs build
)

echo "Building libarchive_ios at $libarchive_revision"
LIBARCHIVE_SOURCE_DIR="$temp_root/libarchive" \
XZ_SOURCE_DIR="$temp_root/xz" \
XZ_IOS_SOURCE_DIR="$temp_root/xz_ios" \
IOS_SYSTEM_SOURCE_DIR="$temp_root/ios_system" \
swift run --package-path xcfs build

xcframework="$repo_root/.build/libarchive_ios.xcframework"
asset="$repo_root/.build/libarchive_ios.xcframework.zip"
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

device_binary="$xcframework/ios-arm64/libarchive_ios.framework/libarchive_ios"
for symbol in tar_main cpio_main bsdcat_main unzip_main; do
    nm -gU "$device_binary" | grep " _$symbol$" >/dev/null || {
        echo "error: $symbol is not exported" >&2
        exit 1
    }
done
xcrun otool -L "$device_binary" | grep '@rpath/ios_system.framework/ios_system' >/dev/null || {
    echo "error: ios_system runtime dependency is missing" >&2
    exit 1
}
for symbol in lzma_auto_decoder lzma_easy_encoder archive_read_support_filter_xz; do
    nm "$device_binary" | grep " _$symbol$" >/dev/null || {
        echo "error: statically linked xz support is missing: $symbol" >&2
        exit 1
    }
done

checksum="$(swift package compute-checksum "$asset")"
VERSION="$version" CHECKSUM="$checksum" perl -0pi -e '
    s{/releases/download/v[^/]+/libarchive_ios\.xcframework\.zip}{/releases/download/$ENV{VERSION}/libarchive_ios.xcframework.zip};
    s{checksum: "[a-f0-9]+"}{checksum: "$ENV{CHECKSUM}"};
' Package.swift

swift package dump-package >/dev/null
git diff --check
git add Package.swift
if ! git diff --cached --quiet; then
    git commit -m "Prepare $version binary release"
fi

git tag -a "$version" -m "libarchive_ios-rootshell $version"
git push origin main
git push origin "$version"
gh release create "$version" "$asset#libarchive_ios.xcframework.zip" \
    --repo kitknox/libarchive_ios-rootshell \
    --title "libarchive_ios-rootshell $version" \
    --notes-file "$release_notes" \
    --verify-tag

echo "Published $version with SwiftPM checksum $checksum"
