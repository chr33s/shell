# Building ios_system XCFrameworks

This document describes how to build the binary frameworks published by the
rootshell fork of `ios_system`.

## Prerequisites

- Xcode 27 or later with the iOS and visionOS SDKs installed
- Frameworks target iOS / Mac Catalyst 18.0 and visionOS 26.0
- macOS 13 or later
- Git submodules initialized

From a fresh clone, initialize the public JOE dependency before building:

```sh
git submodule update --init --recursive
```

## Build all release frameworks

Run the builder from the repository root:

```sh
xcrun swift run --package-path xcfs build
```

Use `xcrun swift`, not a bare `swift`: a swiftly or other open-source toolchain
earlier on `PATH` cannot build against the Xcode 27 SDK (`unknown argument:
'-target-arch-variant'`, `no such module 'Combine'`).

The default build includes these schemes:

- `ios_system`
- `awk`
- `files`
- `joe`
- `shell`
- `text`

To build selected schemes, pass a comma-separated list:

```sh
xcrun swift run --package-path xcfs build ios_system,shell
```

## Supported platforms

Each XCFramework contains release builds for:

- iOS device and Simulator
- Mac Catalyst
- visionOS device and Simulator

The builder archives `ios_system` first for visionOS so dependent frameworks
can resolve it while their visionOS archives are created.

## Build output

Generated files are written under `.build/`:

- `<scheme>/<scheme>.xcframework` contains the assembled framework.
- `<scheme>.xcframework.zip` is the Swift package release asset.
- `release.md` lists the generated archives and their SHA-256 checksums.

XCFrameworks include their matching dSYMs. Treat the generated archives as
release artifacts and inspect them before publishing.

## Publishing a release

Build releases from a fresh checkout of the exact commit that will be tagged.
Do not reuse archives or DerivedData from an earlier source revision.

Publish the five core archives (`ios_system`, `awk`, `files`, `shell`, and
`text`) with the matching `ios_system-rootshell` release. Publish the JOE
archive with the matching `joe-rootshell` release.

Before creating the tag:

1. Update the binary target URLs and checksums in the appropriate
   `Package.swift` files.
2. Verify the checksums against `.build/release.md`.
3. Validate both package manifests:

   ```sh
   xcrun swift package dump-package
   xcrun swift package --package-path xcfs dump-package
   ```

4. Commit the manifest changes and tag that exact commit.
5. Upload the corresponding archives without rebuilding them.

## Troubleshooting visionOS builds

If a dependent framework cannot find `ios_system.framework`, pre-build the
core framework for both visionOS SDKs and rerun the builder:

```sh
xcodebuild build -project ios_system.xcodeproj -scheme ios_system \
    -sdk xros -configuration Release EXCLUDED_ARCHS=x86_64

xcodebuild build -project ios_system.xcodeproj -scheme ios_system \
    -sdk xrsimulator -configuration Release EXCLUDED_ARCHS=x86_64
```

The builder passes explicit `SDKROOT` and `SUPPORTED_PLATFORMS` values to the
visionOS archive commands so Xcode creates archives for the requested SDK.
