# ShellControlHost

The bundled, sandboxed Control host of
[`spec.agent-relay.md`](../spec.agent-relay.md) section 19: a background-only
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
called done (spec section 21): provisioning and signing both bundle
identities with the App Group, TestFlight processing and a clean-Mac install,
the background-item consent prompts, sandbox enforcement of the App Group
socket for an external provider hook, quit/relogin/sleep behaviour, and the
A37–A52 scenarios of spec section 22.
