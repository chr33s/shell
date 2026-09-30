#!/bin/bash
set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(dirname "$script_dir")"
source_file="$repo_root/src/builtin.jq"
output_file="$repo_root/src/builtin.inc"

if [[ ! -f "$repo_root/vendor/oniguruma/src/oniguruma.h" ]]; then
    echo "error: Oniguruma submodule is missing; run: git submodule update --init" >&2
    exit 1
fi

temporary_file="$(mktemp "$repo_root/src/builtin.inc.tmp.XXXXXX")"
trap 'rm -f "$temporary_file"' EXIT

LC_ALL=C od -v -A n -t o1 -- "$source_file" |
    sed -e 's/$/ /' \
        -e 's/\([0123456789]\) /\1, /g' \
        -e 's/ $//' \
        -e 's/ 0/  0/g' \
        -e 's/ \([123456789]\)/ 0\1/g' > "$temporary_file"

if [[ ! -f "$output_file" ]] || ! cmp -s "$temporary_file" "$output_file"; then
    mv "$temporary_file" "$output_file"
fi

echo "Prepared src/builtin.inc from pinned src/builtin.jq"
