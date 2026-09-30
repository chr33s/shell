# Vim Apple-platform integration guide

This guide describes consuming the Rootshell Vim 9.2 fork on iOS, Mac
Catalyst, and visionOS. The release contains dynamic Vim and xxd XCFrameworks;
both depend on a compatible `ios_system.framework` at runtime.

## 1. Add the Swift package

Add the following package dependency and select its `vim` library product:

```text
https://github.com/kitknox/vim-rootshell.git
```

Use an exact Rootshell release such as `0.1.0`. The product contains both the
`vim` and `xxd` binary targets, and Xcode handles linking and embedding their
dynamic frameworks. The consuming app must separately link and embed the
compatible ios_system build used by the release.

## 2. Register commands with ios_system

Register the desired commands in the ios_system command dictionary. Both
frameworks export `main` as their entry point. Rootshell currently registers
Vim and vi as follows:

```xml
<key>vim</key>
<array>
    <string>vim.framework/vim</string>
    <string>main</string>
    <string>bCc:dDeEfgHhi:lLmMnNoOpPqrRsSTu:UvVwW:xXyZ</string>
    <string>file</string>
</array>
<key>vi</key>
<array>
    <string>vim.framework/vim</string>
    <string>main</string>
    <string>bCc:dDeEfgHhi:lLmMnNoOpPqrRsSTu:UvVwW:xXyZ</string>
    <string>file</string>
</array>
```

An app that exposes xxd can register `xxd.framework/xxd` with the `main`
symbol in the same way. Command dictionary loading is an ios_system concern,
not part of the Swift package.

## 3. Bundle the Vim runtime

`VimRuntime.bundle` is intentionally not part of the binary Swift package.
Generate it from this repository with `./prepare_runtime.sh`, add it to the
app's Copy Bundle Resources phase, and set `VIMRUNTIME` before invoking Vim:

```swift
import ios_system

if let bundlePath = Bundle.main.path(forResource: "VimRuntime", ofType: "bundle") {
    ios_setenv("VIMRUNTIME", "\(bundlePath)/Contents/Resources/vim", 1)
}
ios_setenv("TERM", "xterm-256color", 1)
```

Rootshell keeps a synchronized copy of this bundle in its own repository so
normal application builds do not need the Vim source checkout.

## 4. Configure the session

Set the per-session standard streams before calling `ios_system()`. The C API
accepts `FILE *` streams:

```c
ios_setStreams(input, output, error);
int status = ios_system("vim filename.txt");
```

Set `HOME` to an app-writable directory if users should have persistent
`.vimrc`, swap, backup, or undo files. On sandboxed Apple platforms, writable
locations are limited to the app container, such as Documents, Library, and
tmp.

Vim expects an interactive terminal implementation with ANSI control
sequences, cursor-position responses, and correctly connected stdin, stdout,
and stderr. This fork supports true-color output through `termguicolors`.

## Threading and lifecycle

The port isolates Vim global state and ios_system streams with thread-local
storage. Each concurrent instance must run on its own thread with its own
streams and ios_system session state. Do not invoke two Vim instances on the
same thread at the same time.

The build enables `EXITFREE` so returning from an in-process Vim invocation
cleans up state needed by later sessions. Arbitrary child-process creation is
not available in the App Store sandbox; shell operations are routed through
ios_system, while channels, Vim's terminal feature, and other fork/exec-based
features are disabled.

## Building from source

The build expects a sibling `ios_system` checkout with Apple-platform
frameworks already built:

```bash
swift run --package-path xcfs build
```

Outputs are written under `.build/` and include both XCFrameworks, their zip
archives, and `release.md`. Supported slices are iOS arm64 device and simulator,
Mac Catalyst arm64/x86_64, and visionOS arm64 device and simulator.

## Troubleshooting

### Vim hangs or input keys behave incorrectly

- Confirm stdin, stdout, and stderr belong to the current ios_system session.
- Confirm the terminal answers cursor-position queries (`CSI 6 n`).
- Confirm `TERM` matches the terminal capabilities exposed by the app.
- Use a build containing the fork's Backspace termcap fix.

### Runtime files are unavailable

- Confirm `VimRuntime.bundle` is in Copy Bundle Resources.
- Confirm `VIMRUNTIME` points to `Contents/Resources/vim` inside that bundle.
- Use `:scriptnames` to inspect loaded runtime scripts.

### Colors are limited

- Set `TERM` to a true-color-capable terminal type used by the app.
- Enable `set termguicolors` in Vim when the terminal supports 24-bit color.

## Current version and features

- Base source: Vim 9.2.0038 plus upstream security fix 9.2.0272
- Feature set: huge
- Enabled: syntax highlighting and `termguicolors`
- Disabled: channels, Vim terminal, cscope, Lua, Python, GUI, and X11
- Terminal library: Vim built-in implementation rather than ncurses
