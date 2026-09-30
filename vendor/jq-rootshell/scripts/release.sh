#!/bin/bash
set -euo pipefail

version="${1:-}"
if [[ ! "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: $0 vMAJOR.MINOR.PATCH" >&2
    exit 1
fi

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(dirname "$script_dir")"
cd "$repo_root"

git diff --quiet && git diff --cached --quiet || {
    echo "error: release requires a clean worktree" >&2
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
command -v gh >/dev/null || { echo "error: GitHub CLI is required" >&2; exit 1; }
gh auth status >/dev/null

"$script_dir/build-framework.sh"
asset="$repo_root/jq_ios/.build/jq_ios.xcframework.zip"
checksum="$(swift package compute-checksum "$asset")"

VERSION="$version" CHECKSUM="$checksum" perl -0pi -e '
    s{/releases/download/v[^/]+/jq_ios\.xcframework\.zip}{/releases/download/$ENV{VERSION}/jq_ios.xcframework.zip};
    s{checksum: "[a-f0-9A-Z_]+"}{checksum: "$ENV{CHECKSUM}"};
' Package.swift

swift package dump-package >/dev/null
git diff --check
git add Package.swift
if ! git diff --cached --quiet; then
    git commit -m "Prepare $version binary release"
fi

git tag -a "$version" -m "jq-rootshell $version"
git push origin main
git push origin "$version"
gh release create "$version" "$asset#jq_ios.xcframework.zip" \
    --repo kitknox/jq-rootshell \
    --title "jq-rootshell $version" \
    --notes "Swift binary package preserving the pinned rootshell jq and ios_system thread-local integration."

echo "Published $version with SwiftPM checksum $checksum"
