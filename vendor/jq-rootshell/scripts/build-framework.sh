#!/bin/bash
set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(dirname "$script_dir")"
project="$repo_root/jq_ios/jq_ios.xcodeproj"
build_dir="${JQ_IOS_BUILD_DIR:-$repo_root/jq_ios/.build}"
scheme="jq_ios"

"$script_dir/prepare-apple-source.sh"

case "$build_dir" in
    "$repo_root"|"$repo_root/"|/|"")
        echo "error: refusing unsafe build directory: $build_dir" >&2
        exit 1
        ;;
esac

rm -rf "$build_dir"
mkdir -p "$build_dir"

archive() {
    local name="$1"
    shift
    xcodebuild archive \
        -quiet \
        -project "$project" \
        -scheme "$scheme" \
        -configuration Release \
        -archivePath "$build_dir/$name.xcarchive" \
        BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
        SKIP_INSTALL=NO \
        CODE_SIGNING_ALLOWED=NO \
        "$@"
}

echo "Building iOS device slice"
archive jq_ios-iphoneos -sdk iphoneos

echo "Building iOS Simulator slice"
archive jq_ios-iphonesimulator -sdk iphonesimulator EXCLUDED_ARCHS=x86_64

echo "Building visionOS device slice"
archive jq_ios-xros -sdk xros EXCLUDED_ARCHS=x86_64

echo "Building visionOS Simulator slice"
archive jq_ios-xrsimulator -sdk xrsimulator EXCLUDED_ARCHS=x86_64

echo "Building universal Mac Catalyst slice"
archive jq_ios-maccatalyst \
    -destination "generic/platform=macOS,variant=Mac Catalyst"

framework_arguments=()
for archive_name in \
    jq_ios-iphoneos \
    jq_ios-iphonesimulator \
    jq_ios-xros \
    jq_ios-xrsimulator \
    jq_ios-maccatalyst; do
    archive_path="$build_dir/$archive_name.xcarchive"
    framework_path="$archive_path/Products/Library/Frameworks/jq_ios.framework"
    dsym_path="$archive_path/dSYMs/jq_ios.framework.dSYM"
    framework_arguments+=( -framework "$framework_path" )
    if [[ -d "$dsym_path" ]]; then
        framework_arguments+=( -debug-symbols "$dsym_path" )
    fi
done

echo "Creating XCFramework"
xcodebuild -create-xcframework \
    "${framework_arguments[@]}" \
    -output "$build_dir/jq_ios.xcframework"

echo "Creating SwiftPM release archive"
(
    cd "$build_dir"
    /usr/bin/zip --symlinks -q -r jq_ios.xcframework.zip jq_ios.xcframework
)

"$script_dir/audit-framework.sh" "$build_dir/jq_ios.xcframework"

checksum="$(swift package compute-checksum "$build_dir/jq_ios.xcframework.zip")"
echo "XCFramework: $build_dir/jq_ios.xcframework"
echo "Release asset: $build_dir/jq_ios.xcframework.zip"
echo "SwiftPM checksum: $checksum"
