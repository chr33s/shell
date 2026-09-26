<p align="center">
  <img src="icon.png" alt="Shell" width="160" height="160">
</p>

<h1 align="center">Shell</h1>

<p align="center">A minimal, Metal-accelerated terminal emulator for iPhone, iPad, Vision Pro, and Mac.</p>

## About

Shell is a minimal fork of [rootshell](https://github.com/kitknox/rootshell), reduced to
four capabilities:

1. **Local terminal**: libghostty rendering, tabs, splits, scrollback, search, and session restore.
2. **SSH**: password, key, and keyboard-interactive auth, known hosts, profiles, jump host,
   Secure Enclave keys, and OpenSSH user certificates.
3. **Native tmux control mode**: `tmux -CC`, with windows as tabs and panes as splits.
4. **iCloud sync**: CloudKit for profiles, known hosts, public identity metadata, and settings;
   iCloud Keychain for secrets. Secure Enclave keys never leave their device.

> If a feature does not make the terminal render, establish a secure SSH identity,
> make SSH connect, make tmux work, or make those configurations sync, it does not
> belong in the fork.

The one explicit exception is the optional **Control companion**: Shell Watch and the iPhone
review permission requests raised on a Mac (including Claude Code and Codex prompts), through a
Mac-local authority reached over Tailscale. It adds no terminal, SSH, or bulk approval to the
Watch, and the terminal app builds and runs without it.

## Specifications

| Spec | Enables |
| --- | --- |
| [shell.md](docs/specs/shell.md) | The fork itself: terminal, SSH identity, tmux, sync, settings, Mac build, dependency rule |
| [mobile-connectivity.md](docs/specs/mobile-connectivity.md) | Surviving network loss: tmux session recovery, honest SSH reconnect, no silent command re-runs |
| [control-protocol.md](docs/specs/control-protocol.md) | `shell-control/1` and the iPhone gateway: pairing, signed decisions, consume/receipts, Watch via iPhone, push |
| [control-setup.md](docs/specs/control-setup.md) | Guided setup, `doctor` diagnostics, safe test review, no-relay mode |
| [control-cli.md](docs/specs/control-cli.md) | The native `shell-control` CLI: install state, launchd lifecycle, Tailscale Serve, status |
| [agent-relay.md](docs/specs/agent-relay.md) | Answering Claude Code and Codex permission prompts and questions from iPhone and Watch |
| [simplification.md](docs/specs/simplification.md) | Implementation simplification: stable action targets, connection-flow and session ownership, typed commands, sync durability |

## Requirements

iOS, iPadOS, macOS (Mac Catalyst), and visionOS 26+, built with Xcode 26 or newer. The
26 SDKs are required: Citadel uses CryptoKit's `MLKEM768`/`MLDSA*`, and the sources call
26-only API without `#available` gates. Xcode Cloud workflows must pin Xcode 26 or
"Latest Release".

## Layout

```text
shell/                       the app: App, Core, Features (LocalShell, SSH, Tmux, Profiles, Control), UI
Shared/, ShellMacSupport/    MacBridge and the Catalyst-only AppKit bundle
ShellWatch/                  the watchOS app (config: Configuration/Watch.xcconfig)
Packages/ShellControlCore/   portable control protocol, security, gateway, and client code
services/shell-control/      Mac-local broker
services/push-relay/         optional stateless push relay
cmd/                         shell-controld, the shell-control CLI, and the host runtime
ShellControlHost/            sandboxed Control host LaunchAgent (Catalyst only)
adapters/, protocol/         example hook integrations; published schemas and fixtures
tests/, ShellWatchTests/     unit tests
vendor/                      every external Swift package, vendored and pinned
```

## Control companion

Prerequisites: Tailscale on the Mac and iPhone, with MagicDNS and HTTPS certificates
enabled. Download the signed Shell Control disk image and run:

```sh
bin/shell-control setup --guided             # preflight, services, iPhone pairing, safe test review
bin/shell-control agent install claude-code  # or codex: relay agent permission prompts
bin/shell-control doctor                     # read-only diagnostics
```

On the iPhone use **Settings → Control**. The Watch is enrolled afterwards from the Watch
app. See [`cmd/README.md`](cmd/README.md) for every command and
[`services/push-relay/README.md`](services/push-relay/README.md) for remote alerts.

Local development:

```sh
./scripts/run-broker.sh                 # dev broker on http://127.0.0.1:8443
./scripts/dev-pair.sh                   # loopback pairing link for Settings → Control
./scripts/dev-confirm.sh <USER-CODE>    # confirm the code the phone or Watch shows
./scripts/run-watch.sh                  # Watch app on the paired simulator
```

To test remote alerts, set `SHELL_CONTROL_PUSH_RELAY_URL = https:/$()/relay.example` in the
untracked `Configuration/Local.xcconfig`. The `$()` stops xcconfig reading `//` as a comment.

## Building

```sh
./scripts/build.sh          # iOS Simulator build with a de-duplicated error summary
./scripts/test.sh           # ShellTests on the iOS Simulator
./scripts/build-watch.sh    # ShellWatch for the watchOS Simulator
./scripts/test-watch.sh     # ShellWatchTests on the watchOS Simulator
./scripts/test-control.sh   # control SwiftPM packages: core, broker, host
./scripts/test-lifecycle.sh # isolated CLI lifecycle tests
```

The test targets are synchronized file-system groups, so a new test file needs no project
edit. `ShellTests` runs on the iOS Simulator only, because the local-shell stack is excluded
from Catalyst builds. `tests/MacSupportSmoke.swift` is a standalone binary for
`ShellMacSupport.bundle`:

```sh
xcrun swiftc Shared/MacBridge.swift tests/MacSupportSmoke.swift -o /tmp/shell-mac-support-smoke
/tmp/shell-mac-support-smoke .derivedData/Build/Products/Debug/ShellMacSupport.bundle
```

## Dependencies

All packages are vendored under `vendor/`, pinned by `vendor/manifest`, and managed by
`scripts/vendor.py`. Builds never resolve packages over the network; xcframework zips are
fetched and checked against their SHA-256. Hand edits go in `vendor/patches/<package>/*.patch`
and are re-applied on each sync.

```sh
./scripts/vendor.py status                           # pinned vs newest upstream tag
./scripts/vendor.py update Citadel-rootshell 0.12.5  # bump a pin
./scripts/vendor.py sync                             # make vendor/ match the manifest
./scripts/vendor.py verify                           # offline consistency check (CI)
```

## Releasing

CI and TestFlight run on **Xcode Cloud**. Workflows are configured in App Store Connect, and
this repository provides the shared `shell` and `ShellWatch` schemes plus these hooks:

| Script | What it does |
| --- | --- |
| `ci_scripts/ci_post_clone.sh` | `vendor.py verify`; writes `Local.xcconfig` from `SHELL_CONTROL_PUSH_RELAY_URL` if set |
| `ci_scripts/ci_pre_xcodebuild.sh` | Stamps `CI_BUILD_NUMBER` into both xcconfigs |
| `ci_scripts/ci_post_xcodebuild.sh` | Runs `test-control.sh` on test actions |

- **CI** runs on PRs to `main` and on pushes to `main`. It tests `shell` (iOS) and `ShellWatch` (watchOS).
- **TestFlight** runs on pushes to `main`. It runs the same tests, then archives `shell` for iOS, visionOS, and Mac Catalyst and sends each archive to internal testing.
- The Watch app is embedded in the iOS archive (`platformFilter = ios`), so `MARKETING_VERSION`
  must be bumped by hand in both `Base.xcconfig` and `Watch.xcconfig`.

To archive locally, use `scripts/archive.sh ios|ipados|visionos|maccatalyst`. It needs
`ASC_KEY_ID`, `ASC_ISSUER_ID`, and `ASC_KEY_PATH` for an App Store Connect key with App
Manager access.

## Open Source

Shell is open source under the [MIT License](LICENSE). Upstream rootshell is
MIT-licensed by Rootshell LLC; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
for the terminal, SSH, and shell components it builds on.
