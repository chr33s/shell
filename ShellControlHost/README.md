# ShellControlHost

The bundled, sandboxed Control host of
[`docs/specs/agent-relay.md`](../docs/specs/agent-relay.md) section 18: a background-only
macOS app-like wrapper, embedded **only** in the Mac Catalyst build of Shell
and registered by the app as a per-user LaunchAgent through
`SMAppService.agent(plistName:)`. iOS, iPadOS, visionOS, and watchOS builds
contain none of it.

```text
Shell.app/Contents/
  MacOS/Shell
  Library/LaunchAgents/
    dev.chr33s.shell.control-host.plist      (this directory's plist, verbatim)
    ShellControlHost.app/Contents/MacOS/ShellControlHost
```

| File | Purpose |
|---|---|
| `main.swift` | Entry point: storage, single-writer lock, XPC listener, `HostRuntime`, signals, `dispatchMain`. |
| `Info.plist` | `dev.chr33s.shell.control-host`, `LSBackgroundOnly`, `LSUIElement`. |
| `ShellControlHost.entitlements` | App Sandbox, App Group `group.dev.chr33s.shell.control`, `network.server`, `network.client`. No `com.apple.security.inherit`. |
| `dev.chr33s.shell.control-host.plist` | The launchd declaration of spec 19.3 (bundle-relative `BundleProgram`, `RunAtLoad`, `KeepAlive`, `MachServices`). |
| `build-control-host.sh` | Run by the "Build Control Host" phase of the `shell` target: builds the `ShellControlHost` target in a nested `xcodebuild`, copies the `.app` into `Contents/Library/LaunchAgents`, and re-signs it. |

## How it is built and embedded

`ShellControlHost` is a native macOS target in `shell.xcodeproj`, but the
Catalyst `shell` target does **not** depend on it directly. Instead the
"Build Control Host" run-script phase invokes `build-control-host.sh`, which
runs a separate `xcodebuild -target ShellControlHost` with its own
`SYMROOT`/`OBJROOT` under the app's build directory and copies the product in.
The phase is a no-op on every platform except Mac Catalyst.

The separate build graph is deliberate. During an archive Xcode places Swift
package object files in `UninstalledProducts/<PLATFORM_NAME>/`, and
`PLATFORM_NAME` is `macosx` for both Mac Catalyst and native macOS. Because
`shell` and `ShellControlHost` both build `ShellControlProtocol`,
`ShellControlSecurity`, and `ShellControlClient`, a single build graph fails
with `Multiple commands produce ....o` at archive time (regular builds use
per-variant product directories and never collide). Building the host in its
own invocation is the only known workaround
([Apple forums thread 814686](https://developer.apple.com/forums/thread/814686)).
The trade-off is that compiler diagnostics from the host and its packages
appear in the phase's log rather than inline in the issue navigator; to see
them inline, build the `ShellControlHost` target on its own.

The logic lives in the `ShellControlHostRuntime` library of [`../cmd`](../cmd/README.md)
("Bundled Control host"), which composes the broker and daemon libraries in
one process and never links the legacy installer (`ShellControlManagement`).
The Catalyst UI is `shell/Features/Control/ControlHostLifecycle.swift` and
`ControlHostView.swift`.

## Running it by hand

The binary runs outside launchd for development; nothing it needs is found
through `$HOME`:

```sh
.../ShellControlHost.app/Contents/MacOS/ShellControlHost --storage-dir /tmp/sch --port 18743 --no-xpc
```

`--storage-dir` keeps the ledger, journal, identity, and adapter socket under
one directory; `--no-xpc` skips publishing the Mach service, which only launchd
can vend. A second instance against the same storage exits with 75. SIGTERM
drains and exits 0.

## Evidence boundary

Validated locally: the Catalyst archive layout and the absence of the host
from iOS builds, the runtime and XPC tests in `cmd`, and the unsigned binary
above. **Not** validated locally, and release gates before Phase 0A can be
called done (agent-relay spec section 20): provisioning and signing both bundle
identities with the App Group, TestFlight processing and a clean-Mac install,
the background-item consent prompts, sandbox enforcement of the App Group
socket for an external provider hook, quit/relogin/sleep behaviour, and the
A37–A52 scenarios of agent-relay spec section 20.
