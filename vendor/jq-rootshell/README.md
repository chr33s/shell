# jq-rootshell

This repository packages rootshell's existing jq integration as a public Swift binary package. It intentionally preserves the current jq source and ios_system behavior; it is not a jq upgrade.

- Upstream base: [`jqlang/jq@0eb3da11ed489189963045a3d4eb21ba343736cb`](https://github.com/jqlang/jq/commit/0eb3da11ed489189963045a3d4eb21ba343736cb)
- Binary product and module: `jq_ios`
- Platforms: iOS 15+, iOS Simulator, Mac Catalyst 15+, visionOS 1+, and visionOS Simulator
- Integration: `jq_main` uses ios_system's per-thread stream accessors; jq streams and color state remain thread-local

## Swift Package Manager

Add `https://github.com/kitknox/jq-rootshell.git` with an exact dependency on `0.1.0`, then link the `jq_ios` product. The package downloads the public `jq_ios.xcframework.zip` release asset.

```swift
.package(url: "https://github.com/kitknox/jq-rootshell.git", exact: "0.1.0")
```

The ios_system host must provide `ios_stdin()`, `ios_stdout()`, `ios_stderr()`, and `ios_isatty()`. These symbols are deliberately resolved from the application at runtime, matching the existing rootshell integration.

## Apple framework development

Initialize the pinned Oniguruma submodule, then build and audit all five platform slices:

```console
git submodule update --init
./scripts/build-framework.sh
```

Run the native concurrency harness to stress concurrent `jq_main`, stream routing, error routing, color isolation, and the convenience APIs:

```console
./scripts/test-integration.sh
```

Generated archives, XCFrameworks, zips, and autotools inputs remain untracked. `scripts/prepare-apple-source.sh` recreates jq's generated `builtin.inc` from the pinned source before every Apple build. Release maintainers can use `./scripts/release.sh v0.1.0` after authenticating GitHub CLI.

## Upstream jq

The remainder of this README is the upstream project documentation for the pinned source.

# jq

`jq` is a lightweight and flexible command-line JSON processor akin to `sed`,`awk`,`grep`, and friends for JSON data. It's written in portable C and has zero runtime dependencies, allowing you to easily slice, filter, map, and transform structured data.

## Documentation

- **Official Documentation**: [jqlang.org](https://jqlang.org)
- **Try jq Online**: [play.jqlang.org](https://play.jqlang.org)

## Installation

### Prebuilt Binaries

Download the latest releases from the [GitHub release page](https://github.com/jqlang/jq/releases).

### Docker Image

Pull the [jq image](https://github.com/jqlang/jq/pkgs/container/jq) to start quickly with Docker.

#### Run with Docker

##### Example: Extracting the version from a `package.json` file

```bash
docker run --rm -i ghcr.io/jqlang/jq:latest < package.json '.version'
```

##### Example: Extracting the version from a `package.json` file with a mounted volume

```bash
docker run --rm -i -v "$PWD:$PWD" -w "$PWD" ghcr.io/jqlang/jq:latest '.version' package.json
```

### Building from source

#### Dependencies

- libtool
- make
- automake
- autoconf

#### Instructions

```console
git submodule update --init    # if building from git to get oniguruma
autoreconf -i                  # if building from git
./configure --with-oniguruma=builtin
make clean                     # if upgrading from a version previously built from source
make -j8
make check
sudo make install
```

Build a statically linked version:

```console
make LDFLAGS=-all-static
```

If you're not using the latest git version but instead building a released tarball (available on the release page), skip the `autoreconf` step, and flex or bison won't be needed.

##### Cross-Compilation

For details on cross-compilation, check out the [GitHub Actions file](.github/workflows/ci.yml) and the [cross-compilation wiki page](https://github.com/jqlang/jq/wiki/Cross-compilation).

## Community & Support

- Questions & Help: [Stack Overflow (jq tag)](https://stackoverflow.com/questions/tagged/jq)
- Chat & Community: [Join us on Discord](https://discord.gg/yg6yjNmgAC)
- Wiki & Advanced Topics: [Explore the Wiki](https://github.com/jqlang/jq/wiki)

## License

`jq` is released under the [MIT License](COPYING). `jq`'s documentation is
licensed under the [Creative Commons CC BY 3.0](COPYING).
`jq` uses parts of the open source C library "decNumber", which is distributed
under [ICU License](COPYING)
