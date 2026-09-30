# Vim 9.2 Apple-platform port

This is the Rootshell-maintained fork of Vim 9.2. It builds Vim and xxd as
dynamic XCFrameworks for iOS, iOS Simulator, Mac Catalyst, and visionOS using
the `ios_system` framework. The Swift package is distributed from
`kitknox/vim-rootshell` and is versioned independently from upstream Vim.

## Building

### Prerequisites

1. A current Xcode installation with the iOS and visionOS SDKs
2. A sibling `ios_system` checkout with its Apple XCFrameworks already built

From the repository root, run:

```bash
swift run --package-path xcfs build
```

The build produces ignored artifacts under `.build/`:

- `vim.xcframework` and `xxd.xcframework`
- `vim.xcframework.zip` and `xxd.xcframework.zip`
- `release.md` with SwiftPM checksums and platform details

The release manifest in `Package.swift` exposes one `vim` library product that
contains both binary targets. For a release, rebuild the archives, update the
versioned GitHub URLs and checksums, validate with `swift package dump-package`,
tag the manifest commit, and attach both zip files to the matching release.

## Runtime bundle

```bash
./prepare_runtime.sh
```

This refreshes the checked-in `VimRuntime.bundle` containing syntax files,
colors, filetype plugins, autoload helpers, and Vim help. The binary Swift
package does not include this bundle. Rootshell keeps its copy in application
resources and sets `VIMRUNTIME` before invoking Vim.

## Integration

See `INTEGRATION.md` for consumer instructions. Rootshell uses the exact Swift
package release, links a compatible `ios_system.framework`, registers the Vim
and vi commands in `commandDictionary.plist`, and retains `VimRuntime.bundle`
as an app resource.

## Key Apple-platform adaptations

### Thread-local state

Global Vim state is made thread-local with `__thread` so multiple ios_system
sessions can run isolated Vim instances. Standard streams are provided through
the thread-local ios_system `thread_stdin`, `thread_stdout`, and
`thread_stderr` plumbing.

### Sandboxed process model

- Shell execution is routed through `ios_system()` instead of `fork()`/`exec()`.
- `EXITFREE` cleanup supports repeated in-process invocations.
- Channels, Vim's terminal feature, cscope, language interpreters, GUI, and X11
  are disabled by the XCFramework build.
- Vim's built-in terminal library is used instead of ncurses/termcap.

### Terminal behavior

- The build uses Vim's huge feature set and enables `termguicolors`.
- The cursor-position query (`KS_U7`) is enabled.
- The iOS termcap includes the Backspace key capability needed in Insert mode.
- Terminal output is flushed through the ios_system stream after writes.

## Maintenance utilities

`generate_ios_options.py` refreshes `src/optiondefs.h` and
`src/options_init.h`. It defaults to this checkout's `src` directory and can be
pointed at another source tree with `--src-dir`.

```bash
python3 generate_ios_options.py
python3 generate_ios_options.py --src-dir /path/to/vim/src
```

`compare_tls.py` compares thread-local markers with an older source tree. The
baseline is explicit; the new tree defaults to this checkout's `src`.

```bash
python3 compare_tls.py --old-src /path/to/older-vim/src
python3 compare_tls.py --old-src /path/to/older-vim/src --new-src /path/to/new-vim/src
```

## Supported slices

- iOS arm64 device
- iOS Simulator arm64
- Mac Catalyst arm64 and x86_64
- visionOS arm64 device
- visionOS Simulator arm64

## Current source baseline

The fork is based on Vim 9.2.0038 and also carries the upstream 9.2.0272
security fix, plus Rootshell's Apple-platform integration changes. The build
uses the huge feature set without Lua or Python interpreters.
