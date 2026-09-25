#!/bin/sh
# Xcode Cloud: runs immediately before the build action. Xcode Cloud finds this
# by name — do not rename it.
#
# Stamp the Xcode Cloud build number into CURRENT_PROJECT_VERSION. The xcconfigs
# carry a placeholder of 1, and App Store Connect requires a build number that
# rises within a marketing version; CI_BUILD_NUMBER is exactly that counter.
# MARKETING_VERSION stays under version control and is bumped by hand.
#
# A target-level CURRENT_PROJECT_VERSION in shell.xcodeproj overrides the
# xcconfig value, so any such override is stamped as well; otherwise the
# archive keeps the number checked into the project (Build 15 shipped as
# CFBundleVersion 4 that way). The intended state is no overrides at all, and
# this keeps the stamp correct if one is reintroduced.
set -eu

cd "$CI_PRIMARY_REPOSITORY_PATH"

: "${CI_BUILD_NUMBER:?not running under Xcode Cloud}"

for config in Configuration/Base.xcconfig Configuration/Watch.xcconfig; do
    sed -i '' "s|^CURRENT_PROJECT_VERSION = .*|CURRENT_PROJECT_VERSION = $CI_BUILD_NUMBER|" "$config"
    grep -n "^CURRENT_PROJECT_VERSION" "$config"
done

project=shell.xcodeproj/project.pbxproj
sed -i '' -E "s|(CURRENT_PROJECT_VERSION = )[0-9]+;|\1$CI_BUILD_NUMBER;|" "$project"
if grep -n "CURRENT_PROJECT_VERSION = " "$project"; then
    echo "warning: $project overrides CURRENT_PROJECT_VERSION; stamped to $CI_BUILD_NUMBER, but the override should be removed so the xcconfig applies"
else
    echo "$project: no CURRENT_PROJECT_VERSION overrides"
fi
