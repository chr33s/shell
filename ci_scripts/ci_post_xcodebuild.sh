#!/bin/sh
# Xcode Cloud: runs after the build action. Xcode Cloud finds this by name — do
# not rename it.
#
# The control protocol package, the broker, and the host daemon are plain
# SwiftPM packages, not Xcode targets, so no Xcode Cloud scheme covers them.
# Run them alongside the app's test action; a failure here fails the build.
set -eu

cd "$CI_PRIMARY_REPOSITORY_PATH"

if [ "${CI_XCODEBUILD_ACTION:-}" != "test-without-building" ] && \
   [ "${CI_XCODEBUILD_ACTION:-}" != "test" ]; then
    echo "action ${CI_XCODEBUILD_ACTION:-none}: skipping the SwiftPM control packages"
    exit 0
fi

./scripts/test-control.sh
