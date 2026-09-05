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
3. **Native tmux control mode** — `tmux -CC`, with windows mapped to tabs and panes
   mapped to splits.
4. **iCloud sync** — CloudKit for profiles, known hosts, public identity metadata,
   certificates, and a small set of preferences; iCloud Keychain for secrets.
   Secure Enclave private keys never leave the device that created them.

The design rule the fork is held to:

> If a feature does not make the terminal render, establish a secure SSH identity,
> make SSH connect, make tmux work, or make those configurations sync, it does not
> belong in the fork.

See [spec.md](spec.md) for the full extraction spec this fork implements.

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

### Source layout

```text
shell/App/          app entry point and window scenes
shell/Core/         Ghostty bridge, terminal, persistence, CloudKit, settings sync
shell/Features/     LocalShell, SSH, Tmux, Profiles
shell/UI/           Terminal, Tabs, Settings, Window, Sidebar, Keyboard
shell/Entitlements/ App Sandbox, network client, iCloud/CloudKit, Keychain
```

## SSH identity

Software keys are Ed25519 or ECDSA P-256, stored in the Keychain and optionally
synchronized through iCloud Keychain. Secure Enclave identities are P-256 keys whose
private material is generated inside the Secure Enclave, gated by Face ID / Touch ID /
passcode, and never exportable as application data.

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

- **Terminal** — font size, theme, scrollback, `TERM`, keyboard shortcuts
- **SSH** — profiles, SSH identities, known hosts
- **tmux** — default mode, default session name, close-window behavior
- **Sync** — iCloud sync toggles per data class, plus last-sync status

## Sync

CloudKit carries `SSHProfile`, `SSHIdentityMetadata` (public only), `KnownHost`, and a
short list of app settings through the user's private database, using fork-specific
record types. Terminal contents, scrollback, live sessions, shell/command history, and
analytics are never synced.

## Building

```sh
./scripts/build.sh          # build for the iOS Simulator, print a de-duplicated error summary
```

`shell.xcodeproj` resolves its binary dependencies (GhosttyKit, ios_system) and Citadel
through Swift Package Manager. When SwiftPM cannot reach the network, fetch the
xcframeworks once and build against a local override instead:

```sh
./scripts/fetch-frameworks.sh
./scripts/use-local-frameworks.sh on
./scripts/build.sh
./scripts/use-local-frameworks.sh off   # restore the upstream packages before committing
```

## Open Source

Shell is open source under the [MIT License](LICENSE). Upstream rootshell is
MIT-licensed by Rootshell LLC; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
for the terminal, SSH, and shell components it builds on.
