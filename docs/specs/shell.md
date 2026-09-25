# Shell

**Status:** Implemented. The minimal fork of `kitknox/rootshell` has been extracted (all four phases landed); device sign-off of the acceptance checklist (section 14) is partly outstanding.
**Scope:** The fork itself — local terminal, SSH, SSH identity, native tmux control mode, and iCloud sync — plus the Apple configuration, Mac build, and architectural rules that bound it. Extended by [`mobile-connectivity.md`](mobile-connectivity.md); the optional Control companion is specified in [`control-protocol.md`](control-protocol.md).

Capitalized MUST, MUST NOT, SHOULD, and MAY are normative.

## 1. Goal

Shell's entire product surface is:

1. Local terminal
2. SSH, with Secure Enclave SSH keys and OpenSSH user certificates as the identity foundation
3. Native tmux control mode
4. iCloud sync

Shell MUST keep Rootshell's Ghostty-based architecture: the libghostty terminal surface and the tmux control-mode bridge are not to be replaced.

```text
+-----------------------------------------+
|                  Shell                  |
+-----------------------------------------+
|   Local PTY --+                         |
|               +-- libghostty surface    |
|   SSH PTY ----+                         |
|   tmux -CC ---+                         |
+-----------------------------------------+
| SSH identity: software keys,            |
|   Secure Enclave P-256, user certs      |
+-----------------------------------------+
| CloudKit: profiles/settings/cert meta   |
| iCloud Keychain: software credentials   |
+-----------------------------------------+
```

**Design rule.** If a feature does not make the terminal render, establish a secure SSH identity, make SSH connect, make tmux work, or make those configurations sync, it does not belong in the fork.

**Control exception.** The optional Control companion (approvals from iPhone/Watch for a Mac execution host) is the one sanctioned addition outside the design rule. It is specified entirely in [`control-protocol.md`](control-protocol.md) and its sibling specs, MUST stay optional, and MUST NOT carry terminal traffic.

## 2. Local Terminal

### 2.1 Required

Metal/Ghostty rendering; local shell session; ANSI/VT support supplied by Ghostty; keyboard, mouse/trackpad input; copy/paste; text selection; scrollback; search; resize; basic tabs; basic splits; session restoration; one default font; one default theme (`Blackboard Dark`); font-size setting; TERM setting.

The terminal surface/controller architecture stays under `Core/Ghostty` and `UI/Terminal`. No other emulator.

### 2.2 Removed

Theme browser and editor, day/night themes, shaders, cursor effects, animated/photo/video backgrounds, HDR boost, Visor, Tab Exposé, hover previews, project tabs, elaborate tab sidebar and carousel animations, imported fonts and the Nerd Font catalog, cosmetic effects, agent-status decoration, screen-sharing tabs, the writing assistant (autocorrect/QuickType rewriting), configurable prompt systems, and shell integrations other than Bash and Zsh.

Removing a feature MUST remove its commands: no menu item or `KeybindAction` may outlive its feature (AI Agent, Voice Agent, Vertical Tab Bar, Tab Exposé, Background Effect, Clipboard Manager, Theme Picker, Auto-Redact, and brightness boost are gone).

### 2.3 Tabs and commands

Tab *groups* stay, but are derived, never managed. A tab's group comes from what it is attached to — local, remote host, remote domain, remote network, tmux gateway, or `other` (`TabGroupID.Kind`). The tab context menu can move a tab to another group and back to "Automatic". Grouped mode is a checkable Tabs-menu toggle; Tabs ▸ Previous/Next Group is ⌘⌥[ / ⌘⌥].

Main window: a tab strip (`[ + ] [Local] [server-1] …`) with the terminal filling the rest. Commands: New Local Tab, New SSH Connection, Split Horizontal, Split Vertical, Close Pane, Close Tab, Settings. No secondary dashboards beyond the tmux session view (section 5.4).

## 3. SSH

### 3.1 Capabilities

Required: host, port, username; password, saved password, software private-key, Secure Enclave key, OpenSSH user certificate, and keyboard-interactive auth; host-key verification; known-host storage; connection profiles; reconnect; terminal resize; SSH PTY; optional jump host (ProxyJump); basic key import/generation.

A jump host is a whole hop, not a field: its own username, identity or saved password, keyboard-interactive prompts (titled `[Jump Host]`), and known-hosts check against the bastion's key. Connection Info reports it alongside the target.

Host-key verification is known-hosts only: a presented key matches a stored entry or the user is prompted. Host certificate authorities (OpenSSH `@cert-authority`) are out of scope by decision, not a gap: Shell MUST NOT supply CA keys or advertise host-certificate algorithms. This is distinct from the user-certificate auth above.

Not carried forward from Rootshell's `SSHConfig`: agent forwarding, GPG forwarding, port forwarding, cloud labels, HSS, herdr/zmx, TSSH state, VPN state, unrelated transport configuration.

### 3.2 Profile model

`SSHProfile` (`Features/Profiles/SSHProfile.swift`; `ConnectionProfile` is an alias) carries `id`, `name`, sync metadata, and usage stats. Everything about the endpoint lives in `sshConfig: SSHConfig`:

| Field | Type |
| --- | --- |
| `host`, `port`, `username` | `String`, `Int`, `String` |
| `authMethod` | `SSHConfig.AuthMethod`: `password`, `savedPassword`, `key(UUID)`, `keyboardInteractive`, `unknown(rawType:)` |
| `jumpHost` | `SSHConfig.JumpHostConfig?` — host, port, username, auth |
| `terminalType` | `String?` |
| tmux selection | stored `tmuxAutoEnable` / `tmuxAutoMode`; `TmuxMode` (`off`, `regular`, `control`) is a computed view; plus session name |

`unknown(rawType:)` preserves a profile written by a newer version; it MUST NOT be dropped or rewritten.

`.key(UUID)` references an identity — software key or Secure Enclave P-256, either optionally with an attached user certificate. A profile MUST NOT duplicate certificate or private-key material.

## 4. SSH Identity & Key Storage

### 4.1 Key types

`GenerateKeyType` offers Ed25519, ECDSA P-256/P-384/P-521, and RSA 2048/3072/4096. Ed25519 and P-256 are the required minimum. `SSHKey.KeyType` adds `secureEnclaveP256`.

### 4.2 Secure Enclave

Hardware-protected P-256 keys whose private material never leaves the Secure Enclave. Operations: generate; derive and store public key; display fingerprint; authenticate; require Face ID / Touch ID / passcode per configured policy; delete; identify clearly as Secure Enclave in UI. Public-key metadata is persisted; the device-bound private-key reference stays protected by Keychain / Secure Enclave. Secure Enclave MUST use the normal Security/Keychain path, with no YubiKey/NFC/smartcard entitlements.

### 4.3 OpenSSH user certificates

A user certificate (`*-cert.pub`) MAY be attached to a software or Secure Enclave identity. Operations: import; parse metadata; verify the certificate's public key matches the identity (reject otherwise); store public certificate data with identity metadata; present it during authentication; replace/rotate; remove; expose validity status, detecting expired, not-yet-valid, and soon-to-expire; export the certificate line.

### 4.4 Identity model

```swift
struct SSHIdentity { id: UUID; name; keyType; fingerprint; storage: SSHKeyStorage
                     secureEnclave: SecureEnclaveIdentityInfo?; certificate: SSHUserCertificate? }
enum SSHKeyStorage { deviceOnly, backupOnly, iCloudSync }
struct SecureEnclaveIdentityInfo { publicKeyX963: Data; createdAt: Date }
struct SSHUserCertificate { certificateBlob: Data; certificateType; keyID; serial: UInt64
                            principals: [String]; validAfter, validBefore: UInt64
                            caKeyType; caFingerprint; comment: String? }
```

The certificate model MUST contain at least blob, type, serial, key ID, principals, validity interval, CA key type, and CA fingerprint.

### 4.5 Storage rules

| Material | Store |
| --- | --- |
| Software private key | Keychain (device-only / backup-only / iCloud-sync abstraction) |
| Secure Enclave private key | Secure Enclave, via Keychain reference |
| Public key metadata | Local persistence |
| OpenSSH certificate | Local metadata; CloudKit-safe public data |
| Password | Keychain |

Certificates are public credentials and MAY sync with identity metadata. Secure Enclave private keys are device-bound regardless of sync metadata and MUST NOT be represented as synchronizable. When a Secure Enclave identity's metadata reaches another device, the identity is shown as unavailable there and the user may generate or import another; nothing may imply the private material can move.

### 4.6 Removed

YubiKey, FIDO2, external SSH agents, OpenPubkey/OIDC, GPG and keygrips, SSH agent server, agent forwarding.

## 5. tmux

tmux means native control mode (`tmux -CC`), not merely running `tmux` in a terminal.

### 5.1 Mapping

tmux session → attached terminal session; window → tab; pane → split; active-window change → selected tab; pane resize → native split resize; window title → tab title. Ghostty owns protocol parsing and pane terminal state; Swift consumes reconcile actions.

### 5.2 Actions

Attach, create session, detach, switch session; create, close, rename window; create, close, zoom, select, resize pane.

### 5.3 SSH integration

Per profile: Off / tmux / tmux Control Mode, plus session name. Control mode starts with `tmux -CC new-session -A -s <session>`; reattachment after relaunch or recovery follows section 13.

### 5.4 Surface

`TmuxSessionDashboardView`: list the server's sessions and windows, switch the gateway's attached session, create/rename/kill a session, detach. No previews or thumbnails.

Kept because removal cost more than it saved:

- **Hidden windows.** A window can be hidden rather than killed (the `hideTab` close action and the tmux tab menu). It keeps running and the tab strip skips it. The hidden set is stored in the session's `@hidden` user option in the conventional control-mode wire format (`TmuxHiddenWindowsCodec`), so it survives reattach and is shared with other clients; tmux emits no notification for user-option changes, so another client picks it up at next attach.
- **Gateway grouping.** A `-CC` gateway and its window tabs form one derived group, `TabGroupID.tmux(ownerID:)` (section 2.3).

Removed: Tab Exposé integration, session previews and thumbnails, herdr, zellij, zmx, multiplexer discovery beyond tmux, advanced pane/window administration menus. Controller functionality MAY remain where removing it adds coupling, but MUST NOT be exposed as UI.

## 6. iCloud Sync

Two independent mechanisms: CloudKit for non-secret data (this section) and iCloud Keychain / Secure Enclave for secrets (section 7).

### 6.1 CloudKit records

Non-secret data syncs through the user's private database in the fork's own container, with fork-specific record types (not Rootshell's production schema). Rootshell's mechanics — offline queueing, sync state, conflict handling, deterministic records — are reused.

| Record | Fields |
| --- | --- |
| `SSHProfile` | id, name, host, port, username, authType, identityID?, jumpHost?, terminalType?, tmuxMode, tmuxSessionName?, modifiedAt, deleted |
| `SSHIdentityMetadata` | id, name, keyType, fingerprint, storageType, publicKey, certificate?, secureEnclaveDeviceBound, modifiedAt, deleted |
| `KnownHost` | id, hostname, port, keyType, publicKey, fingerprint, firstSeen, lastSeen, modifiedAt, deleted |
| `AppSetting` | one record per `UserDefaults` key, carrying a self-describing `CodableValue` JSON payload |

For Secure Enclave identities `secureEnclaveDeviceBound = true`; only public metadata syncs, and the private-key reference MUST NOT be uploaded as portable key material.

### 6.2 Setting sync policy

Adding a setting never changes the record schema. Every key is declared once in `SettingsRegistry` with a `SyncPolicy`:

| Policy | Behavior |
| --- | --- |
| `synced` | Syncs unless the user pins it to this device |
| `localByDefault` | Syncs, but starts pinned — device-shape or platform specific |
| `deviceOnly` | Never leaves the device; no pin UI (sync state, device ID, change token, restoration counters) |

`tests/ShellTests/SettingsRegistryInventoryTests.swift` holds the inventory, so a policy flip that starts pushing a key to iCloud shows up as a diff.

### 6.3 Do not sync

Terminal contents, scrollback, active shell processes, active SSH sessions, tmux contents, shell history, command history, analytics, usage counters.

## 7. Secret Sync

Passwords and private keys MUST NEVER be stored as plaintext CloudKit fields.

| Store | Contents |
| --- | --- |
| CloudKit | Profiles, known hosts, preferences, public identity metadata, OpenSSH user certificates |
| iCloud Keychain | Saved passwords, synchronizable software private keys |
| Secure Enclave | Device-bound private keys; never leave the device that created them |

A profile holds `auth = key(<UUID>)`; the identity resolves locally:

| State | Result |
| --- | --- |
| Software key synchronized | Usable |
| Software key metadata synced, Keychain item pending | "SSH key not yet available" |
| Secure Enclave identity created on this device | Usable |
| Secure Enclave metadata from another device | "Secure Enclave key belongs to another device" |

Shell MUST NEVER silently fall back to password authentication. Certificates follow identity metadata.

## 8. Apple Configuration

Rootshell's identifiers MUST NOT be reused. Defined in `Configuration/Base.xcconfig` and `shell/Entitlements/`:

| Item | Value |
| --- | --- |
| Bundle ID | `dev.chr33s.shell` |
| Keychain access group | `$(AppIdentifierPrefix)dev.chr33s.shell` |
| CloudKit container | `iCloud.dev.chr33s.shell` |
| App Group | none for the core app |

Core entitlements: App Sandbox, Network Client, iCloud + CloudKit, Keychain access group, user-selected files (key/certificate import via `fileImporter`).

MUST NOT be present for the core product: NFC, smartcard, associated-domains, networkextension, multicast, multipath (hence Network.framework TCP without MPTCP), wifi-info, and application groups not needed by a shared process.

Control exception: `aps-environment` exists only for Control approval hints from the optional push relay, and `ShellCatalyst.entitlements` adds the App Group `group.dev.chr33s.shell.control` shared with the bundled Control host ([`agent-relay.md`](agent-relay.md) §18.5). iOS, iPadOS, and visionOS carry no App Group.

### 8.1 Deployment target

```text
IPHONEOS_DEPLOYMENT_TARGET = 26.0   iOS, iPadOS, Mac Catalyst
XROS_DEPLOYMENT_TARGET     = 26.0   visionOS
```

Only OS majors 26 and 27 are supported. There is no `[sdk=macosx*]` override (Catalyst derives from `IPHONEOS_DEPLOYMENT_TARGET`). This is an architectural constraint: no `#available` checks exist, 26-only API is called un-gated, and the only `@available` attributes are `@available(*, unavailable)` `init?(coder:)` traps. Lowering the floor will not compile.

## 9. Mac Build

The Mac build is Mac Catalyst, not native macOS.

```text
SUPPORTED_PLATFORMS    = iphoneos iphonesimulator xros xrsimulator
SUPPORTS_MACCATALYST   = YES
TARGETED_DEVICE_FAMILY = 1,2,7
```

`UIDesignRequiresCompatibility` MUST NOT be set (Catalyst runs the Mac idiom; setting it changes control metrics app-wide).

### 9.1 AppKit support bundle

`ShellMacSupport` is a second target (`SDKROOT = macosx`, `MACOSX_DEPLOYMENT_TARGET = 26.0`, product `ShellMacSupport.bundle`), embedded by a build phase filtered to `maccatalyst` and loaded on first use via `Bundle.principalClass` (`shell/UI/Window/MacSupport.swift`). iOS and visionOS do not depend on it.

`Shared/MacBridge.swift` is the only ABI: the `MacBridge` protocol plus `@objc` handle protocols `MacShellProcess` and `MacMenuEntry`. Every call runs on the main thread; AppKit objects stay opaque `NSObject`s. It provides window furniture, appearance (glass backdrop, blur, app appearance), menus (Dock, Services, native context-menu entries), terminal events (scroll, hover, menu), the local PTY (`createShell`), and Text Input Services. New AppKit access MUST be a bridge method, never a KVC/reflection site; the remaining three `NSClassFromString` sites are in `CatalystAppDelegate`, and the bundle's only undeclared surface is Ghostty's private `_cornerRadius`.

- Per-window restoration is keyed by scene session id through `CatalystSceneDelegate.stateRestorationActivity(for:)`, never `NSWindow.restorationClass`.
- The Dock menu adds `applicationDockMenu(_:)` to UIKit's delegate class with `class_addMethod`, which declines if UIKit implements it; nothing is swizzled.
- Settings is its own `UIWindowScene` (`shell/UI/Settings/MacSettingsWindow.swift`), not a SwiftUI `Settings` scene. About, Close Tab, Close Window, and tab navigation go through the bridge; File ▸ Open Recent lists saved SSH profiles.

### 9.2 Menus and tabs

`AppCommands.swift` owns the menu bar; there is no `UIMenuBuilder` rail. Eight `MenuToggleItem`s are checkable (seven on the Mac; Full Screen is iPad-only because AppKit owns Enter Full Screen). Each is a SwiftUI `Toggle` reading its own truth; no bridge surface or `NSApp.mainMenu` title-walk MUST be added for this. Mixed state is inapplicable: each action dispatches `sendAction(_:to:from:for:)` with a nil target stamped with one scene session id, so unknown state renders unchecked-and-disabled. `MacMenuEntry.state` keeps its `-1` encoding for `UIAction.state`-built context menus.

Native `NSWindow` tabs are not adopted: a tab owns a `SplitTree` of panes, a derived group, and (for a tmux gateway) child window tabs, which one-scene-per-tab cannot express. The in-window tab bar stays custom. The Window menu (`shell/App/MacApplicationCommands.swift`) supplies ⌃⇥ / ⌃⇧⇥, Previous/Next Tab on ⌘⇧[ / ⌘⇧], Move Tab to New Window, and Merge All Windows; Catalyst already lists open windows.

### 9.3 Touch fence

Every touch affordance MUST be fenced with `!targetEnvironment(macCatalyst)`. Selection loupe, handles, and status-bar styling are whole fenced files; pinch/long-press gestures and impact feedback are fenced regions. The keyboard accessory and `KeyboardGeometryMonitor` compile on Catalyst but return empty answers — the pattern for shared code that names such types. `KeyboardTracker` MUST NOT be deleted wholesale: it owns physical modifier handling.

### 9.4 Native macOS is out of scope

libghostty ships no native macOS slice (`GhosttyKitAppStore.xcframework`: iOS, iOS simulator, Mac Catalyst, visionOS, visionOS simulator; `scripts/build-framework.sh` audits only for the Catalyst library), and the UIKit-based UI layer would be a multi-month rewrite. A second application target MUST NOT be added. Accepted Catalyst limitations: `UIKeyCommand` key handling (dead keys, some Option-composed and non-Latin input slightly off versus `NSTextInputClient`), `UITextInput` candidate handling approximated, UIKit-derived VoiceOver.

### 9.5 Unverified on Catalyst

A general human review (2026-09-06) found the app working, but these have no per-item outcome recorded: titlebar, glass backdrop, native scroll, context and Dock menus, multi-window and Settings-window restore across relaunch, duplicate "Close Tab"/"Close" in File, the Services item (present, enabled, surviving menu rebuilds), `Toggle` checkmarks and `DynamicShortcut` glyphs in `CommandGroup` menus (the load-bearing assumption of section 9.2), and checkmarks tracking focus. Catalyst-only behavior has no unit-test home (section 14) and is verified by hand.

## 10. Source Tree and Dependency Rule

### 10.1 Source tree

App sources are under `shell/`: `App/`; `Core/` (`CloudKit`, `Connection`, `Foundation`, `Ghostty`, `Keybinds`, `Persistence`, `Preferences`, `SettingsSync`, plus `Animation`, `Prompt`, `Security`, `Shell`, `Sync`, `System`, `Terminal`, `Theme`); `Features/` (`LocalShell`, `Profiles`, `SSH`, `Tmux`); `UI/` (`Terminal`, `Tabs`, `Settings`, `Window`); `Entitlements/`; `Resources/`. `Features/SSH/` contains exactly `Config`, `HostTrust`, `Keys`, `Session`, `Settings`, `Views`; `Keys` MUST retain software keys, Secure Enclave, user certificates, Keychain persistence, fingerprinting, and authentication resolution.

Deleted (extraction complete): AI agent and agent attention/inbox/usage, automation, cloud providers and consoles, Kubernetes, VNC/screen sharing, Mosh, TSSH/Roam, VPN, NetBird, Tailscale integration, port forwarding, GPG, Git client, file browser, Croc, Helix, Vim runtime, WASM tools, effects/shaders, Live Activities, push notification service, App Intents/Siri, HSS, YubiKey, FIDO2, transfer tools, `SSH/Agent`, `SSH/OpenPubkey`, `SSH/Discovery`, and their targets (push, widget, VPN tunnel, CoreWLAN plugin).

Targets: `shell`, `ShellMacSupport`, `ShellTests`, plus the Control companion targets (`ShellControlHost`, `ShellWatch`, `ShellWatchTests`). Linked packages: GhosttyKit, Citadel, ios_system (binary targets `ios_system`, `awk`, `files`, `shell`, `text`), plus `Packages/ShellControlCore` and `cmd` for Control. No vim, git, or editor framework is linked.

### 10.2 Dependency rule

```text
App/UI
  +-- Terminal  -- Ghostty/libghostty
  +-- SSH       -- transport library (Citadel), Terminal
  |               Identity Store -- Keychain, Secure Enclave, OpenSSH certificates
  +-- tmux      -- Ghostty tmux control mode, SSH raw transport
  +-- Sync      -- CloudKit, Keychain
```

Invariant: no surviving core module may import AI, VNC, VPN, Mosh, TSSH, CloudProviders, Kubernetes, Push, GPG, Git, FileBrowser, AgentAttention, YubiKey, FIDO2, or OpenPubkey.

## 11. Settings

Settings is four sections — Terminal, SSH, tmux, Sync — plus the optional Control companion as the one allowed extra (`SettingsSection`). No other settings pages. Settings are edited only here: the Ghostty-style text-configuration overlay (`ConfigOverlay`) is removed. Keybinds are the one exception, keeping an external file at `~/.ghostty/imported_keybinds.conf`, imported from Terminal ▸ Keyboard Shortcuts and re-read by the built-in `reloadconfig` command.

### 11.1 Terminal

Font size; Theme; Scrollback lines; Session (Restore Sessions on Launch, Persist Scrollback History); TERM (Local, Remote); Force ASCII Keyboard; Keyboard shortcuts.

### 11.2 SSH

Profiles; SSH Identities; Known Hosts; Saved Passwords; Auto Reconnect (Attempts per Recovery Burst); Try to Keep SSH Alive in Background; Force IPv4; Periodic Connection Health Checks (Probe Interval).

"Attempts per Recovery Burst" is per burst: once exhausted, the intent survives and attempts continue at a slower cooldown. Disabling health checks stops the probe loop, not recovery — a bounded single check still runs on foreground activation, path change, or transport error. Background keepalive is best-effort within iOS's finite allowance; there is no guaranteed background connection. See [`mobile-connectivity.md`](mobile-connectivity.md).

SSH Identity detail: Name, Key Type, Fingerprint, Storage, Security, Secure Enclave yes/no; OpenSSH Certificate (Status, Key ID, Principals, Serial, Valid From, Valid Until, CA Fingerprint); Import / Replace Certificate; Remove Certificate.

### 11.3 tmux

Default mode; Default session name; Close-window behavior.

### 11.4 Sync

iCloud Sync, Sync Profiles, Sync Known Hosts, Sync Settings, Sync Identity Metadata, Sync Software Keys (each on/off); Last Sync; Pending Changes; Sync Now. Secure Enclave keys MUST be labelled device-bound and excluded from private-key sync.

### 11.5 Control

Optional companion enrollment and Watch setup, per [`control-protocol.md`](control-protocol.md) §1.1 and §5.1 and [`control-setup.md`](control-setup.md).

## 12. Home / Connection UI

Launch screen (`SSHConnectionView`): New Local Terminal; an SSH list of saved profiles; + Add SSH Host. Selecting a profile immediately opens a terminal tab.

Profile edit screen (`ProfileEditorSheet`): Name, Host, Port, Username, Authentication / Identity, Jump Host; Terminal (TERM); tmux (Off / tmux / Control Mode, Session Name). Nothing else.

The identity picker MUST distinguish type, Secure Enclave, and certificate, e.g. `Ed25519`, `P-256`, `P-256 · Secure Enclave`, `P-256 · Secure Enclave · Certificate`, `Ed25519 · Certificate`.

## 13. Persistence

Persisted locally: tabs; split layout; split-pane zoom; tab grouping state (grouped mode, active group, group order, per-group tab order); SSH profile ID per terminal; local/SSH session type; tmux attachment metadata; font size; theme; window frame (Mac Catalyst); scrollback history when Persist Scrollback History is on. With Restore Sessions on Launch off, none of it is written or read.

Dead SSH connections MUST NOT be restored directly. On relaunch:

| Session | Relaunch behavior |
| --- | --- |
| Local | Create a new shell |
| SSH | Offer a new remote shell |
| `tmux -CC` | Reconnect SSH and reattach the verified existing session |

tmux is the source of remote session persistence. Relaunch restores *intent*, never a transport, a task, or an assumption of readiness. Outcomes are never conflated:

| Outcome | Meaning |
| --- | --- |
| Session restored | The intended existing tmux session was verified and reattached. |
| New shell opened | A new remote shell was explicitly requested; the old one was not resumed. |
| Command outcome unknown | A connection failed around a remote action whose completion cannot be established; it was not rerun. |

Plain SSH has no continuity: a replacement transport is a new shell and MUST be reported as such. Reattachment uses `attach-session` against a verified session id — never `new-session -A` — so a missing or unverifiable session asks the user. A one-shot command whose dispatch may have happened is never re-executed, including after relaunch; there is no exactly-once promise. Recovery status is drawn natively, outside the terminal byte stream. Full contract: [`mobile-connectivity.md`](mobile-connectivity.md).

## 14. Definition of Done

Extraction ran in four phases, each gating the next: (1) local terminal plus the identity subsystem — software keys, Secure Enclave, certificates — working independently of any SSH session; (2) SSH wired to that identity system; (3) tmux control mode; (4) sync. Unused source and targets were deleted only after all four worked. All have landed.

The build MUST be green with no errors and no warnings. `./scripts/test.sh` runs `ShellTests` (`tests/ShellTests/`) and MUST target the iOS Simulator, never Mac Catalyst, because the local-shell stack (`shell/Core/Shell/`, `Features/LocalShell/`) is behind `#if !targetEnvironment(macCatalyst)`. `tests/MacSupportSmoke.swift` is a standalone AppKit binary run by hand.

A box is ticked only where the claim was checked; unticked means sign-off not yet recorded, not a known gap.

### 14.1 Acceptance

**Terminal** (confirmed on device): [x] launches local shell · [x] typing · [x] resize · [x] scrolling · [x] copy/paste · [x] tabs · [x] splits.

**SSH identity:** [ ] Ed25519 software keys · [ ] P-256 software keys · [ ] Secure Enclave P-256 generation · [ ] Secure Enclave signing · [ ] Secure Enclave keys non-exportable · [ ] Keychain storage · [ ] fingerprinting · [ ] biometric/passcode policy · [ ] delete removes the Secure Enclave identity.

**OpenSSH certificates:** [ ] import valid `*-cert.pub` · [ ] mismatched identity rejected · [ ] metadata (key ID, serial, principals, CA fingerprint, validity) parsed and shown · [ ] expired/not-yet-valid detected · [ ] attaches to software and Secure Enclave identities · [ ] replace · [ ] remove · [ ] certificate auth (server sees the certificate) · [ ] certificate + Secure Enclave auth · [ ] expired/not-yet-valid fail before connecting with a useful error · [ ] raw key never substituted when the certificate is required.

**SSH:** [ ] password · [ ] private key · [ ] Secure Enclave · [ ] certificate · [ ] keyboard-interactive · [ ] host-key verification · [ ] saved profiles · [ ] known hosts · [ ] reconnect · [ ] optional jump host.

**tmux:** [ ] regular tmux · [ ] `tmux -CC` · [ ] windows map to tabs · [ ] panes map to splits · [ ] pane resize · [ ] detach · [ ] reconnect + reattach.

**iCloud:** [ ] profile added on device A appears on B · [ ] known hosts · [ ] selected settings · [ ] identity metadata · [ ] certificates follow identity · [ ] synchronizable software keys usable once iCloud Keychain syncs · [ ] Secure Enclave private keys never sync, and another device reports them unavailable · [ ] conflicts do not duplicate profiles · [ ] deletions propagate · [ ] no SSH secret in plaintext CloudKit records.

**Removal** (checked against the tree): [x] no AI · [x] VNC · [x] VPN extension · [x] Mosh/TSSH · [x] push target · [x] widgets · [x] cloud-provider SDKs · [x] Kubernetes · [x] GPG · [x] YubiKey/FIDO UI · [x] Git/file-browser/editor tooling · [x] shader/effect system · [x] unused entitlements · [ ] OpenPubkey/OIDC — feature and UI gone, but `KeychainManager` keeps three OpenPubkey secret-blob helpers (only the delete is called, from key deletion). Residual: `CursorManager` carries an inert `CursorEffect` setting read only by itself, and some comments still name removed features.
