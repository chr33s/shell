#!/bin/sh
# Xcode Cloud: runs immediately before the build action. Xcode Cloud finds this
# by name — do not rename it.
#
# Stamp the Xcode Cloud build number into CURRENT_PROJECT_VERSION. The xcconfigs
# carry a placeholder of 1, and App Store Connect requires a build number that
# rises within a marketing version; CI_BUILD_NUMBER is exactly that counter.
# MARKETING_VERSION stays under version control and is bumped by hand.
set -eu

cd "$CI_PRIMARY_REPOSITORY_PATH"

: "${CI_BUILD_NUMBER:?not running under Xcode Cloud}"

for config in Configuration/Base.xcconfig Configuration/Watch.xcconfig; do
    sed -i '' "s|^CURRENT_PROJECT_VERSION = .*|CURRENT_PROJECT_VERSION = $CI_BUILD_NUMBER|" "$config"
    grep -n "^CURRENT_PROJECT_VERSION" "$config"
done
