#!/bin/bash
set -euo pipefail

baseline="${1:-}"
candidate="${2:-}"
if [[ ! -d "$baseline" || ! -d "$candidate" ]]; then
    echo "usage: $0 BASELINE.xcframework CANDIDATE.xcframework" >&2
    exit 1
fi

temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT

slices=(
    ios-arm64
    ios-arm64-simulator
    ios-arm64_x86_64-maccatalyst
    xros-arm64
    xros-arm64-simulator
)

for slice in "${slices[@]}"; do
    baseline_framework="$baseline/$slice/jq_ios.framework"
    candidate_framework="$candidate/$slice/jq_ios.framework"
    baseline_binary="$baseline_framework/jq_ios"
    candidate_binary="$candidate_framework/jq_ios"

    baseline_architectures="$(lipo -archs "$baseline_binary" | tr ' ' '\n' | sort | xargs)"
    candidate_architectures="$(lipo -archs "$candidate_binary" | tr ' ' '\n' | sort | xargs)"
    [[ "$baseline_architectures" == "$candidate_architectures" ]]
    cmp "$baseline_framework/Headers/jq_ios.h" "$candidate_framework/Headers/jq_ios.h"
    cmp "$baseline_framework/Headers/jq_tls.h" "$candidate_framework/Headers/jq_tls.h"
    cmp "$baseline_framework/Modules/module.modulemap" "$candidate_framework/Modules/module.modulemap"

    nm -gU "$baseline_binary" | awk '{print $NF}' | sort -u > "$temporary_dir/baseline-exports"
    nm -gU "$candidate_binary" | awk '{print $NF}' | sort -u > "$temporary_dir/candidate-exports"
    diff -u "$temporary_dir/baseline-exports" "$temporary_dir/candidate-exports"

    nm -u "$baseline_binary" | awk '{print $NF}' | sort -u > "$temporary_dir/baseline-imports"
    nm -u "$candidate_binary" | awk '{print $NF}' | sort -u > "$temporary_dir/candidate-imports"
    diff -u "$temporary_dir/baseline-imports" "$temporary_dir/candidate-imports"

    otool -L "$baseline_binary" | tail -n +2 | sed 's/^[[:space:]]*//' | grep -v ' (architecture .*):$' > "$temporary_dir/baseline-links"
    otool -L "$candidate_binary" | tail -n +2 | sed 's/^[[:space:]]*//' | grep -v ' (architecture .*):$' > "$temporary_dir/candidate-links"
    diff -u "$temporary_dir/baseline-links" "$temporary_dir/candidate-links"
done

echo "Parity passed: architectures, headers, modules, exports, imports, and linked libraries match"
