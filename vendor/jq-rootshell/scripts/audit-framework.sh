#!/bin/bash
set -euo pipefail

xcframework="${1:-}"
if [[ -z "$xcframework" || ! -d "$xcframework" ]]; then
    echo "usage: $0 /path/to/jq_ios.xcframework" >&2
    exit 1
fi

slices=(
    ios-arm64
    ios-arm64-simulator
    ios-arm64_x86_64-maccatalyst
    xros-arm64
    xros-arm64-simulator
)

required_symbols=(
    _jq_main
    _jq_process_string
    _jq_process_to_stream
    _jq_ios_stdin
    _jq_ios_stdout
    _jq_ios_stderr
    _jq_ios_thread_cleanup
)

required_host_symbols=(
    _ios_stdin
    _ios_stdout
    _ios_stderr
    _ios_isatty
)

reference_headers=""
reference_modulemap=""

for identifier in "${slices[@]}"; do
    framework="$xcframework/$identifier/jq_ios.framework"
    binary="$framework/jq_ios"
    headers="$framework/Headers"
    modulemap="$framework/Modules/module.modulemap"

    [[ -f "$binary" ]] || { echo "error: missing binary for $identifier" >&2; exit 1; }
    [[ -f "$headers/jq_ios.h" ]] || { echo "error: missing jq_ios.h for $identifier" >&2; exit 1; }
    [[ -f "$headers/jq_tls.h" ]] || { echo "error: missing jq_tls.h for $identifier" >&2; exit 1; }
    [[ -f "$modulemap" ]] || { echo "error: missing module map for $identifier" >&2; exit 1; }

    expected_architectures="arm64"
    if [[ "$identifier" == "ios-arm64_x86_64-maccatalyst" ]]; then
        expected_architectures="arm64 x86_64"
    fi
    actual_architectures="$(lipo -archs "$binary" | tr ' ' '\n' | sort | xargs)"
    if [[ "$actual_architectures" != "$expected_architectures" ]]; then
        echo "error: $identifier architectures are '$actual_architectures'" >&2
        exit 1
    fi

    for symbol in "${required_symbols[@]}"; do
        nm -gU "$binary" | awk '{print $NF}' | grep -Fxq "$symbol" || {
            echo "error: $identifier does not export $symbol" >&2
            exit 1
        }
    done

    for symbol in "${required_host_symbols[@]}"; do
        nm -u "$binary" | awk '{print $NF}' | grep -Fxq "$symbol" || {
            echo "error: $identifier does not retain host lookup for $symbol" >&2
            exit 1
        }
    done

    if [[ -z "$reference_headers" ]]; then
        reference_headers="$headers"
        reference_modulemap="$modulemap"
    else
        cmp -s "$reference_headers/jq_ios.h" "$headers/jq_ios.h" || {
            echo "error: jq_ios.h differs in $identifier" >&2
            exit 1
        }
        cmp -s "$reference_headers/jq_tls.h" "$headers/jq_tls.h" || {
            echo "error: jq_tls.h differs in $identifier" >&2
            exit 1
        }
        cmp -s "$reference_modulemap" "$modulemap" || {
            echo "error: module map differs in $identifier" >&2
            exit 1
        }
    fi
done

library_count="$(/usr/libexec/PlistBuddy -c 'Print :AvailableLibraries' "$xcframework/Info.plist" | grep -c 'Dict {' | tr -d ' ')"
[[ "$library_count" == "5" ]] || { echo "error: expected 5 libraries, found $library_count" >&2; exit 1; }

echo "Audit passed: five slices, stable headers, expected ABI, and ios_system host lookups"
