#!/bin/sh
# Xcode Cloud: runs after the repository is cloned, before dependencies are
# resolved. Xcode Cloud finds this by name — do not rename it.
#
# Package resolution needs no network: every SwiftPM dependency is checked in
# under vendor/.
#
# The phone and Watch apps read the broker endpoint from a build setting that
# defaults to a `control.invalid` placeholder (Configuration/Base.xcconfig and
# Configuration/Watch.xcconfig). Point a build at a real service by defining
# SHELL_CONTROL_BROKER_URL as an environment variable on the Xcode Cloud
# workflow; this writes it into the untracked Local.xcconfig that both files
# optionally include, which is the same hook a developer uses locally.
set -eu

cd "$CI_PRIMARY_REPOSITORY_PATH"

# Every Swift package dependency is vendored under vendor/ (see
# scripts/vendor.py); fail fast if the checkout and vendor/manifest disagree
# rather than letting Xcode's resolve step report a missing local package.
./scripts/vendor.py verify

if [ -n "${SHELL_CONTROL_BROKER_URL:-}" ]; then
    # `$()` splits the `//`, which xcconfig would otherwise read as the start of
    # a comment and truncate the URL to "https:".
    url=$(printf '%s' "$SHELL_CONTROL_BROKER_URL" | sed 's|//|/$()/|')
    echo "SHELL_CONTROL_BROKER_URL = $url" > Configuration/Local.xcconfig
    echo "broker: $url"
else
    echo "broker: unset, Release Watch builds ship the placeholder"
fi
