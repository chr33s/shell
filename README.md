<p align="center">
  <img src="icon.png" alt="Shell" width="160" height="160">
</p>

<h1 align="center">Shell</h1>

<p align="center">A minimal, Metal-accelerated terminal emulator for iPhone, iPad, Vision Pro, and Mac.</p>

## About

Shell is a minimal fork of [rootshell](https://github.com/kitknox/rootshell), reduced to
four capabilities and nothing else:

1. **Local terminal** — GPU-accelerated rendering powered by libghostty, tabs, splits,
   scrollback, search, copy/paste, and session restoration.
2. **SSH** — password, saved-password, private-key, and keyboard-interactive auth,
   host-key verification, known hosts, saved profiles, reconnect, and an optional
   jump host. Secure Enclave keys and OpenSSH user certificates are first-class.
   Host-key verification is known-hosts only: trusting a certificate authority to
   vouch for *host* keys is out of scope, and is a different feature from the
   OpenSSH *user* certificates.
3. **Native tmux control mode** — `tmux -CC`, with windows mapped to tabs and panes
   mapped to splits.
4. **iCloud sync** — CloudKit for profiles, known hosts, public identity metadata,
   certificates, and most preferences (89 of 115 registered settings keys are
   syncable); iCloud Keychain for secrets.
   Secure Enclave private keys never leave the device that created them.

The design rule the fork is held to:

> If a feature does not make the terminal render, establish a secure SSH identity,
> make SSH connect, make tmux work, or make those configurations sync, it does not
> belong in the fork.

**Amendment: the optional control companion.** That rule is extended, once and
explicitly, to allow **Shell Watch** — an independent watchOS app for reviewing
and answering permission requests raised by programs running on a host, plus the
broker and host service it needs. It does not restore the upstream AI or push
feature set: there is no terminal on the Watch, no SSH client, no stored SSH
identity, no unrestricted remote input, and no automatic or bulk approval. The
companion is optional at every layer — the terminal app builds and runs exactly
as before without a broker configured.

See [spec.md](spec.md) for the extraction spec this fork implements,
[spec.connectivity.md](spec.connectivity.md) for mobile connectivity and session
recovery, and [spec.watch.md](spec.watch.md) for the control companion.

## Requirements

iOS 26+, iPadOS 26+, macOS 26+ (Mac Catalyst), visionOS 26+. Only the current and
next OS majors are supported: the deployment target is 26.0 on every platform, and
the sources call 26-only API with no `#available` gates, so the floor cannot be
lowered without putting those gates back.

## Architecture

```text
+-----------------------------------------+
|                  Shell                  |
+-----------------------------------------+
|               libghostty                |
|                                         |
|   Local PTY --+                         |
|               +-- Terminal Surface      |
|   SSH PTY ----+                         |
|               |                         |
|   tmux -CC ---+                         |
+-----------------------------------------+
| SSH Identity Layer                      |
|   Software Keys                         |
|   Secure Enclave P-256                  |
|   OpenSSH User Certificates             |
+-----------------------------------------+
| CloudKit profiles/settings/cert metadata|
| iCloud Keychain software credentials    |
+-----------------------------------------+
```

Ghostty owns terminal rendering and tmux control-mode protocol parsing; Swift consumes
reconcile actions and maps them onto native tabs and splits. No surviving module may
import AI, VNC, VPN, Mosh, TSSH, cloud-provider, Kubernetes, push, GPG, Git,
file-browser, YubiKey, FIDO2, or OpenPubkey code — that is an architectural invariant,
not a style preference.

On Mac Catalyst the AppKit surface lives in a second binary. `ShellMacSupport.bundle`
is built against the macOS SDK, embedded only in the Catalyst build, and reached
through the `@objc MacBridge` protocol: window and titlebar configuration, the glass
backdrop, the Dock and Services menus, input sources, and the native PTY. iOS and
visionOS builds do not contain it.

### Control companion

```text
Watch  --HTTPS-->  Shell Control broker  <--HTTPS--  shell-controld  --IPC-->  adapter
        APNs alert                                        (execution host)
```

The Watch owns its own P-256 key, APNs registration, and HTTPS client, and
enrols independently over OAuth device authorization: it works with the iPhone
app absent. TestFlight onboarding is phone-first: Settings → Control starts
setup on this device, opens Safari to confirm, and WatchConnectivity only
forwards the Watch's enrollment code so the same Safari page can approve the
Watch. It never copies private keys or session tokens. A decision is a JWS
(`ES256`, JCS payload) that commits to one request digest and the versions the
reviewer saw; the host claims that decision exactly once and reports a receipt
saying what it actually applied. A push notification is a hint — the ledger is
the snapshot and change stream.

```text
Packages/ShellControlCore/   portable protocol, security, and client code
ShellWatch/                  the watchOS app
ShellWatchTests/             its unit tests, hosted by ShellWatch.app
shell/Features/Control/      optional phone setup, larger review, handoff
services/shell-control/      the broker: durable store, HTTP front end, APNs outbox
cmd/                         shell-controld (host service) and shell-control (CLI)
adapters/                    example blocking-hook integrations
protocol/                    published schemas and interoperability fixtures
```

`ShellControlCore` links no UIKit, Ghostty, Citadel, SSH, or CloudKit code, and
the Watch target does not inherit the iOS bridging header, bundle identity, or
Ghostty linker flags. Configuration lives in `Configuration/Watch.xcconfig`,
which deliberately does not include `Base.xcconfig`.

### Trying the companion locally

Debug builds of the phone and Watch apps point at `http://localhost:8443`, which
is what `./scripts/run-broker.sh` serves — so Xcode's Run button works against a
local broker with no extra setup. Release builds carry the placeholder
`https://control.invalid`, which the app recognises as "not configured" and says
so rather than dialling it, so nothing ships pointing at a laptop. A TestFlight
build bakes a real HTTPS host via `SHELL_CONTROL_BROKER_URL` (see Releasing).

```sh
./scripts/run-broker.sh                 # dev broker on http://localhost:8443
./scripts/run-watch.sh                  # build + install + launch, pointed at it
./scripts/dev-confirm.sh <USER-CODE>    # confirm the code the Watch shows
```

`run-broker.sh` generates an account id, an admin secret, and a cursor secret
into `.derivedData/dev-broker.env` on first run. The simulator shares the Mac's
network stack, and loopback is the one case the client accepts without TLS.

Enrollment is confirmed by an account administrator, not by the enrolling
device. Testers run the companion CLI from a checkout (or `npx github:chr33s/shell`):

```sh
npx @chr33s/shell          # broker on 127.0.0.1 + HTTPS tunnel + origin + pairing QR
```

Once setup reports readiness, closing that CLI or terminal does **not** stop the
broker, origin daemon, or managed tunnel. `npx @chr33s/shell down` is what stops
them, and they stay stopped until `up`. Quick tunnels are a development
convenience: a lost `*.trycloudflare.com` hostname is never replaced silently
(`setup --rotate-url` plus re-pairing). Login persistence is opt-in via
`service install` and requires a named tunnel or an external reverse proxy to
the same local broker.

On the phone: **Settings → Control → Scan QR** (or paste the printed URL).
The CLI prints each device fingerprint; type `y` to approve. It will not
auto-approve — a public tunnel would otherwise enrol strangers.
`npx @chr33s/shell down` stops the broker and prevents automatic relaunch.
Without `cloudflared`, the broker stays on loopback.

Locally without the npm CLI, open the printed verification URI in a browser,
check the key fingerprint against the one on the device, and approve.
`dev-confirm.sh` does the same thing from the shell.

For a persistent address, create `Configuration/Local.xcconfig` (untracked):

```text
SHELL_CONTROL_BROKER_URL = https:/$()/control.example
```

The `$()` splits the `//`, which xcconfig would otherwise read as a comment.

### Source layout

```text
shell/App/          app entry point and window scenes
shell/Core/         Ghostty bridge, terminal, persistence, CloudKit, settings sync
shell/Features/     LocalShell, SSH, Tmux, Profiles
shell/UI/           Terminal, Tabs, Shell, Settings, Window, Keyboard, Shared,
                    Overlays, Sidebar
shell/Entitlements/ App Sandbox, network client, user-selected files,
                    iCloud/CloudKit, Keychain access group
Shared/             MacBridge, the @objc protocol compiled into both targets
ShellMacSupport/    Catalyst-only macOS bundle: AppKit windows, menus, native PTY
tests/              ShellTests unit-test bundle, plus a standalone Mac smoke test
```

## SSH identity

Software keys are generated in-app as Ed25519, ECDSA P-256/P-384/P-521, or RSA
2048/3072/4096 — Ed25519 is the default and the recommendation — and are stored in the
Keychain, optionally synchronized through iCloud Keychain. Secure Enclave identities
are P-256 keys whose private material is generated inside the Secure Enclave, gated
by Face ID / Touch ID / passcode, and never exportable as application data.

An OpenSSH user certificate (`*-cert.pub`) can be attached to either kind of identity.
Shell parses and displays the key ID, serial, principals, validity window, CA key type,
and CA fingerprint; validates that the certificate's public key matches the selected
identity; flags expired, not-yet-valid, and soon-to-expire certificates; and presents
the certificate during authentication. Certificates are public credentials, so their
metadata follows the identity across devices.

Storage rules:

```text
software private key       -> Keychain (optionally iCloud Keychain)
Secure Enclave private key -> Secure Enclave, device-bound
public key metadata        -> local persistence + CloudKit
OpenSSH certificate        -> identity metadata + CloudKit
saved password             -> Keychain
```

A Secure Enclave identity that syncs to a second device shows there as unavailable —
Shell never implies the private key moved, and never silently falls back to password
auth.

## Settings

Four sections, nothing else:

- **Terminal** — font size, theme, scrollback, session restore, `TERM` (local and
  remote), keyboard
- **SSH** — profiles, SSH identities, known hosts, saved passwords, recovery
- **tmux** — default mode, default session name, close-window behavior
- **Sync** — iCloud sync toggles per data class, plus last-sync status
- **Control** — optional Watch companion: pair a Mac broker (`npx @chr33s/shell`
  QR or paste), enroll this device, confirm the Watch

## Losing the network

Mobile connections drop. Shell treats a lost connection and a lost session as
different things, and never claims more than it can prove.

- **tmux is what preserves a session.** In control mode, recovery reattaches to
  the *same* session — verified by server and session metadata, not by name, so
  a renamed session still matches and a name reused by a different session does
  not. If that session cannot be verified, Shell asks which session to attach to
  rather than creating one and calling it restored. Regular tmux mode has no
  control channel to gather that evidence from, so it reattaches by name; it
  still never creates, and a missing session becomes a prompt rather than a new
  empty session.
- **Plain SSH cannot resume.** A replacement connection is a new shell, and it
  is labelled "Open New Shell", never "Resume session". The previous screen is
  kept as read-only history. Configure tmux on a profile if you want session
  continuity.
- **Commands are never silently re-run.** If a connection fails around a
  one-shot command, Shell reports "Command outcome unknown" and leaves it to
  you. There is no exactly-once execution promise, and a missing exit status is
  not evidence that a command did not run.
- **Recovery status stays out of the terminal.** It renders in a native strip
  above the surface, so a full-screen remote application's output is unchanged
  by a reconnection.
- **Attempts are counted honestly.** "Attempts per Recovery Burst" bounds one
  rapid burst; after it, the intent survives and attempts continue at a slower
  rate while the app is in the foreground and a route is plausible. Waiting,
  network events, and backgrounding spend no attempts.
- **Background connectivity is not guaranteed.** iOS suspends apps, and Shell
  does not pretend otherwise: it retains the intent to reconnect and acts on it
  when you come back.

## Sync

CloudKit carries `SSHProfile`, `SSHIdentityMetadata` (public only), `KnownHost`, and
app settings — one record per settings key — through the user's private database, using
fork-specific record types. Each setting declares whether it syncs, starts pinned to
this device, or never leaves it. An identity record is owned by the device that
published it, so a device only tombstones identities it created itself. Terminal
contents, scrollback, live sessions, shell/command history, and analytics are never
synced.

## Building

```sh
./scripts/build.sh          # build for the iOS Simulator, print a de-duplicated error summary
./scripts/test.sh           # run the ShellTests bundle (124 tests) on the iOS Simulator
./scripts/build-watch.sh    # build ShellWatch for the watchOS Simulator
./scripts/test-watch.sh     # run the ShellWatchTests bundle (16 tests) on the watchOS Simulator
./scripts/test-control.sh   # run the control packages: core, broker, host
./scripts/test-lifecycle.sh # isolated CLI lifecycle tests (never touch real enrollment)
```

Xcode 26 or newer is required. The 26.0 deployment target aside, Citadel's
post-quantum key exchange uses CryptoKit's `MLDSA65`, `MLDSA87` and `MLKEM768`,
which exist only in the 26 SDKs; an older toolchain fails with `no type named
'MLKEM768' in module 'CryptoKit'`, which points at CryptoKit rather than at the
toolchain that is actually at fault. Xcode Cloud workflows must therefore pin
Xcode 26 or "Latest Release", never an older fixed version.

The Watch target is built separately from the iOS target on purpose: they share
no configuration file, and the control packages are plain SwiftPM packages that
test on the Mac toolchain without a simulator. `ShellWatchTests` is hosted by
`ShellWatch.app` and, like `ShellTests`, is a synchronized file-system group, so
a new file under `ShellWatchTests/` needs no project edit.

`ShellTests` is a hosted unit-test target whose sources are a synchronized file-system
group, so a new file under `tests/ShellTests/` needs no project edit. It runs on the iOS
Simulator and not on Mac Catalyst: the whole local-shell stack sits behind
`#if !targetEnvironment(macCatalyst)` and does not compile there. `tests/MacSupportSmoke.swift`
is separate — a standalone AppKit binary, compiled and run by hand against the built
`ShellMacSupport.bundle`:

```sh
xcrun swiftc Shared/MacBridge.swift tests/MacSupportSmoke.swift -o /tmp/shell-mac-support-smoke
/tmp/shell-mac-support-smoke .derivedData/Build/Products/Debug/ShellMacSupport.bundle
```

## Dependencies

Every external Swift package — GhosttyKit, ios_system, Citadel, and their
transitive Apple and third-party packages — is vendored under `vendor/`, so a
build never resolves anything over the network and there is no `Package.resolved`
to drift. `vendor/manifest` pins each package to an upstream tag;
`scripts/vendor.py` fetches those pins, rewrites each package's `Package.swift`
so it depends on its vendored siblings by path, keeps only the xcframework
targets named in the manifest (SwiftPM fetches each zip and verifies the
upstream SHA-256, so the binaries are content-pinned without bloating the
repository), and strips the dependencies this project never builds (marked
`drop=`). Every local
change is mechanical and regenerated on each sync, so pulling an upstream
release is a one-line pin bump with nothing to merge:

```sh
./scripts/vendor.py status                              # pinned vs newest upstream tag
./scripts/vendor.py update Citadel-rootshell 0.12.5     # bump a pin, refetch, relocalize, stage
./scripts/vendor.py sync                                # make vendor/ match the manifest
./scripts/vendor.py verify                              # offline consistency check (CI runs this)
```

A pinned package's contents are replaced wholesale on update, so hand edits to
vendored code go in `vendor/patches/<package>/*.patch` (plain `git diff` output
taken at the repository root); they are re-applied after localization, and a
patch that no longer applies stops the sync so it can be rebased rather than
silently dropped. `vendor/manifest.lock` records the resolved commits and binary
checksums and is written by the tool. The xcframework zips are the only thing a
build fetches; Xcode caches them in DerivedData. Upstream submodules are not fetched: the
ios_system tree is carried for provenance, not compiled — the app links its
xcframeworks.

## Releasing

CI and TestFlight distribution run on **Xcode Cloud**. Its workflows are defined
in App Store Connect (or Xcode's Report navigator), not in this repository — what
the repository provides is the shared schemes those workflows build and the
`ci_scripts/` hooks Xcode Cloud invokes by name:

| Script | When | What it does |
| --- | --- | --- |
| `ci_scripts/ci_post_clone.sh` | after clone | Runs `./scripts/vendor.py verify` so a build fails fast if `vendor/` and `vendor/manifest` disagree, then writes `Configuration/Local.xcconfig` from the `SHELL_CONTROL_BROKER_URL` environment variable, so Release Watch builds reach a real broker instead of the `control.invalid` placeholder |
| `ci_scripts/ci_pre_xcodebuild.sh` | before build | Stamps `CI_BUILD_NUMBER` into `CURRENT_PROJECT_VERSION` in `Configuration/Base.xcconfig` and `Configuration/Watch.xcconfig` |
| `ci_scripts/ci_post_xcodebuild.sh` | after build | Runs `./scripts/test-control.sh` on test actions — the control packages are plain SwiftPM packages that no Xcode scheme covers |

`MARKETING_VERSION` stays under version control and is bumped by hand; the build
number comes from Xcode Cloud.

### Workflows to configure

Both schemes are shared (`shell.xcodeproj/xcshareddata/xcschemes/`), which is
what makes them selectable in Xcode Cloud.

**CI** — start condition: pull requests targeting `main`, plus branch changes on
`main`. Actions: Test the `shell` scheme on an iOS simulator, and Test the
`ShellWatch` scheme on a watchOS simulator. The SwiftPM control packages come
along via `ci_post_xcodebuild.sh`.

**TestFlight** — start condition: branch changes on `main`. Put the same two Test
actions *before* the archives in the same workflow: Xcode Cloud runs a workflow's
actions in order and stops on failure, which is how a red build is kept from
reaching testers. Then three Archive actions, all with the TestFlight (Internal
Testing) post-action:

| Archive action | Scheme | Platform |
| --- | --- | --- |
| iOS and iPadOS | `shell` | iOS |
| visionOS | `shell` | visionOS |
| Mac Catalyst | `shell` | macOS (Mac Catalyst) |

iPhone and iPad share one archive because Shell targets device families 1 and 2.
The Watch app has no archive of its own: the `shell` target's "Embed Watch
Content" phase copies `ShellWatch.app` into `Shell.app/Watch`, so it ships with
the iOS build under one App Store Connect record, and testers get it when they
install from TestFlight. That build file and the target dependency both carry
`platformFilter = ios`, because a Mac Catalyst or visionOS app cannot contain
watch content. Those two reuse `dev.chr33s.shell`, which works by universal
purchase once the platforms are enabled on the app record.

Embedding is a distribution choice and does not weaken the independence
spec.watch.md requires: `WKRunsIndependentlyOfCompanionApp` in
`ShellWatch/Info.plist` keeps the Watch app usable with the phone app absent.
The cost is a version lock — an embedded watch app must carry the same
`MARKETING_VERSION` as its host, so `Configuration/Base.xcconfig` and
`Configuration/Watch.xcconfig` have to be bumped together.

Signing and upload are Xcode Cloud's own — there are no certificates, API keys,
or repository secrets to manage. The one setting worth adding is the environment
variable `SHELL_CONTROL_BROKER_URL` on the TestFlight workflow (mark it secret if
the endpoint is not public).

### Archiving by hand

`scripts/archive.sh` does the same archive and export locally, for a build that
should not go through Xcode Cloud. It signs with an App Store Connect API key:

```sh
export ASC_KEY_ID=... ASC_ISSUER_ID=... ASC_KEY_PATH=~/private_keys/AuthKey_....p8
./scripts/archive.sh ios            # or ipados, visionos, maccatalyst
```

The key needs App Manager access, since `-allowProvisioningUpdates` creates
provisioning profiles with it.

## Open Source

Shell is open source under the [MIT License](LICENSE). Upstream rootshell is
MIT-licensed by Rootshell LLC; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
for the terminal, SSH, and shell components it builds on.
