# libarchive for rootshell

This repository packages rootshell's existing libarchive command integration
as a public Swift binary package. It preserves the source and behavior already
used by rootshell; it is not an automatically updated mirror of upstream
libarchive.

- Upstream base: [`libarchive/libarchive@4613cc9d`](https://github.com/libarchive/libarchive/commit/4613cc9d7926bc175d25ca07ddecfee22f0d45fa) (libarchive 3.9.0)
- Binary product and module: `libarchive_ios`
- C entry points: `tar_main`, `cpio_main`, `bsdcat_main`, and `unzip_main`
- Commands: `tar`, `bsdtar`, `cpio`, `bsdcpio`, `bsdcat`, `unzip`, and `bsdunzip`
- Platforms: iOS 14+, iOS Simulator, Mac Catalyst 14+, visionOS 1+, and visionOS Simulator

The integration makes mutable command state thread-local, routes standard
streams through ios_system, resets state between invocations, converts process
exits to recoverable control flow, and supports cooperative session
cancellation. liblzma is statically incorporated for xz archive support. The
framework dynamically links `ios_system.framework`; consumers must also link
and embed a compatible ios_system product.

## Swift Package Manager

Add this repository with an exact dependency on `0.1.0`, then link the
`libarchive_ios` product. The package downloads the public
`libarchive_ios.xcframework.zip` release asset.

```swift
.package(
    url: "https://github.com/kitknox/libarchive_ios-rootshell.git",
    exact: "0.1.0"
)
```

## Apple framework development

Check out libarchive, xz, xz_ios, and ios_system beside this repository at the
pinned revisions, build ios_system and xz_ios, and then build libarchive_ios:

```bash
git -C ../libarchive checkout 4613cc9d7926bc175d25ca07ddecfee22f0d45fa
git -C ../xz checkout v5.7.1alpha
git -C ../xz_ios checkout v0.1.0
git -C ../ios_system checkout v0.1.0
cd ../ios_system
swift run --package-path xcfs build ios_system
cd ../xz_ios
swift run --package-path xcfs build
cd ../libarchive_ios
swift run --package-path xcfs build
```

`LIBARCHIVE_SOURCE_DIR`, `XZ_SOURCE_DIR`, `XZ_IOS_SOURCE_DIR`, and
`IOS_SYSTEM_SOURCE_DIR` can point at other checkouts of the same pinned
revisions. Generated frameworks, archives, and release notes remain under the
ignored `.build` directory.

Release maintainers publish a clean, audited build with:

```bash
./scripts/release-rootshell.sh v0.1.0
```

The release script uses detached worktrees at the pinned source revisions, so
it does not alter existing sibling checkouts.

## Licensing and issues

libarchive remains licensed and maintained by the upstream project. Source
files retain their upstream license notices; see [COPYING](COPYING). Report
reproducible upstream libarchive problems there, and report rootshell
integration problems in the [rootshell issue tracker](https://github.com/kitknox/rootshell-app/issues).
