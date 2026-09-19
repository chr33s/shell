#!/bin/sh
# Xcode Cloud: runs after the repository is cloned, before dependencies are
# resolved. Xcode Cloud finds this by name — do not rename it.
#
# Package resolution needs no network: every SwiftPM dependency is checked in
# under vendor/.
#
# The phone reads the optional Shell Push Relay from a build setting that
# defaults to a `relay.invalid` placeholder (Configuration/Base.xcconfig).
# Define SHELL_CONTROL_PUSH_RELAY_URL on the Xcode Cloud workflow to enable
# prompt approval alerts; this writes it into the untracked Local.xcconfig,
# the same hook a developer uses locally. There is no broker URL to bake: the
# phone pairs with its Mac over Tailscale from the setup QR.
set -eu

cd "$CI_PRIMARY_REPOSITORY_PATH"

# Every Swift package dependency is vendored under vendor/ (see
# scripts/vendor.py); fail fast if the checkout and vendor/manifest disagree
# rather than letting Xcode's resolve step report a missing local package.
./scripts/vendor.py verify

if [ -n "${SHELL_CONTROL_PUSH_RELAY_URL:-}" ]; then
    # `$()` splits the `//`, which xcconfig would otherwise read as the start of
    # a comment and truncate the URL to "https:".
    url=$(printf '%s' "$SHELL_CONTROL_PUSH_RELAY_URL" | sed 's|//|/$()/|')
    echo "SHELL_CONTROL_PUSH_RELAY_URL = $url" > Configuration/Local.xcconfig
    echo "push relay: $url"
else
    echo "push relay: unset, builds work without prompt remote alerts"
fi
