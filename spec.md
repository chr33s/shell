# Shell Minimal Fork — Extraction Spec

## 1. Goal

Create a minimal fork of `kitknox/rootshell` whose entire product surface is:

1. Local terminal
2. SSH
3. Native tmux control mode
4. iCloud sync

The SSH identity foundation must include from the first extraction phase:

5. Secure Enclave SSH keys
6. OpenSSH user certificates

Everything not required to support those capabilities should be removed.

The fork should continue using Rootshell's existing Ghostty-based terminal architecture. Keep the existing libghostty terminal surface and tmux control-mode bridge rather than replacing either with a new implementation.

---

## 2. Product Definition

### 2.1 Local Terminal

#### Required

- Metal/Ghostty terminal rendering
- Local shell session
- ANSI/VT terminal support supplied by Ghostty
- Keyboard input
- Mouse/trackpad input
- Copy/paste
- Text selection
- Scrollback
- Search
- Resize
- Basic tabs
- Basic splits
- Session restoration
- One default font
- One default theme
- Basic font-size setting
- Basic TERM setting

Keep the existing terminal surface/controller architecture under `Core/Ghostty` and `UI/Terminal` rather than introducing another emulator.

#### Remove

- 450+ theme browser
- custom theme editor
- day/night themes
- custom shaders
- cursor effects
- animated backgrounds
- photo/video backgrounds
- HDR boost
- Visor
- Tab Exposé
- hover previews
- project tabs
- elaborate tab sidebar
- tab carousel animations
- custom imported fonts
- Nerd Font catalog unless one packaged font is required
- cosmetic terminal effects
- agent-status decoration
- screen-sharing tabs

Tab *groups* stay. A tab's group is derived from what it is attached to — local,
remote host, remote domain, remote network, tmux gateway, or `other`
(`TabGroupID.Kind`) —
so there is no project to create, name or manage; the tab context menu can move
one tab to another group and back to "Automatic", and that is the whole of it.
Grouped mode is a checkable Tabs-menu toggle, and Tabs ▸ Previous/Next Group
(⌘⌥[ / ⌘⌥]) steps between groups.

Removing a feature means removing its commands. Nine menu items and keybinds
outlived their features and stayed installed while silently doing nothing — AI
Agent, Voice Agent, Vertical Tab Bar, Tab Exposé, Background Effect, Clipboard
Manager, Theme Picker, Auto-Redact, and brightness boost. They are gone along
with their `KeybindAction` cases.

#### Minimal UX

Main window:

```text
[ + ] [Local] [server-1] [server-2]
```

Terminal occupies the rest of the window.

Commands:

- New Local Tab
- New SSH Connection
- Split Horizontal
- Split Vertical
- Close Pane
- Close Tab
- Settings

No secondary dashboards unless tmux requires one.

---

## 3. SSH

### 3.1 Required SSH capabilities

Keep:

- host
- port
- username
- password auth
- saved password
- SSH private-key auth
- Secure Enclave key auth
- OpenSSH user certificate auth
- keyboard-interactive auth
- host-key verification
- known-host storage
- connection profiles
- reconnect
- terminal resize
- SSH PTY
- optional jump host / ProxyJump
- basic SSH key import/generation

A jump host is a whole hop, not a field: it has its own username, its own
identity or saved password, its own keyboard-interactive prompts (titled
`[Jump Host]`), and its own known-hosts check against the bastion's key.
Connection Info reports it alongside the target.

Remove:

- host certificate authorities (OpenSSH `@cert-authority` host trust)

Host-key verification is known-hosts only: a presented key either matches a stored entry or the user is prompted. Trusting a CA to vouch for *host* keys is a different feature from the OpenSSH *user* certificate auth kept above, and is deliberately out of scope — not a gap to be filled later.

The current `SSHConfig` is broader than this fork needs. Replace it with a reduced model rather than carrying forward agent forwarding, GPG forwarding, port forwarding, cloud labels, HSS, herdr/zmx, TSSH state, VPN state, or unrelated transport configuration.

### Proposed minimal profile model

```swift
struct SSHProfile: Codable, Identifiable {
    var id: UUID
    var name: String

    var host: String
    var port: Int
    var username: String

    var auth: SSHAuth
    var jumpHost: SSHJumpHost?

    var terminalType: String?

    var tmuxMode: TmuxMode
    var tmuxSessionName: String?
}
```

```swift
enum SSHAuth: Codable {
    case password
    case savedPassword
    case key(UUID)
    case keyboardInteractive
}
```

A key referenced by `.key(UUID)` may be:

- a software private key
- a Secure Enclave P-256 key
- either of the above with an attached OpenSSH user certificate

The profile references the identity; it must not duplicate certificate or private-key material.

```swift
struct SSHJumpHost: Codable {
    var host: String
    var port: Int
    var username: String
    var auth: SSHAuth
}
```

```swift
enum TmuxMode: String, Codable {
    case off
    case regular
    case control
}
```

As built the proposal is split in two. `SSHProfile` carries `id`, `name`, sync
metadata and usage stats; everything about the endpoint lives in its
`sshConfig: SSHConfig` — host, port, username, `authMethod`, `jumpHost`,
`terminalType`, and the tmux selection. The two auth types are nested in
`SSHConfig` rather than free-standing: `AuthMethod` (`password`, `savedPassword`,
`key(UUID)`, `keyboardInteractive`, plus an `unknown(rawType:)` case that
preserves a profile written by a newer version instead of dropping or rewriting
it) and `JumpHostConfig`. `TmuxMode` is a computed view over the stored
`tmuxAutoEnable` / `tmuxAutoMode` pair.

---

## 4. SSH Identity & Key Storage

The minimal fork must retain a compact but strong SSH identity subsystem.

### 4.1 Required identity types

#### Software keys

Required:

- Ed25519
- ECDSA P-256

RSA may remain if removing it creates unnecessary work.

As built, `GenerateKeyType` offers seven: Ed25519, ECDSA P-256/P-384/P-521, and RSA
2048/3072/4096. RSA stayed, and the two larger NIST curves came with P-256.
`SSHKey.KeyType` adds `secureEnclaveP256` for the hardware-backed identities below.

#### Secure Enclave

Required from Phase 1.

Support generation and use of hardware-protected P-256 keys whose private material never leaves the Secure Enclave.

Required operations:

- generate Secure Enclave key
- derive/store public key
- display fingerprint
- use key for SSH authentication
- require Face ID / Touch ID / passcode according to configured policy
- delete identity
- identify Secure Enclave keys clearly in UI

Retain the existing design where public key metadata is persisted while the device-bound private-key reference remains protected by the Keychain / Secure Enclave.

#### OpenSSH user certificates

Required from Phase 1.

Support attaching an OpenSSH user certificate (`*-cert.pub`) to a software or Secure Enclave-backed SSH identity.

Required operations:

- import certificate
- parse certificate metadata
- verify that certificate public key matches the selected identity
- store certificate public data with identity metadata
- present certificate during SSH authentication
- replace/rotate certificate
- remove certificate
- expose validity status
- detect expired certificates
- detect not-yet-valid certificates
- detect soon-to-expire certificates
- export certificate line if needed for debugging/interoperability

Preserve the existing Rootshell certificate model or a reduced equivalent containing at least certificate blob, type, serial, key ID, principals, validity interval, CA key type, and CA fingerprint.

### 4.2 Minimal identity model

```swift
struct SSHIdentity: Codable, Identifiable {
    var id: UUID
    var name: String
    var keyType: SSHKeyType
    var fingerprint: String
    var storage: SSHKeyStorage
    var secureEnclave: SecureEnclaveIdentityInfo?
    var certificate: SSHUserCertificate?
}
```

```swift
enum SSHKeyStorage: String, Codable {
    case deviceOnly
    case backupOnly
    case iCloudSync
}
```

```swift
struct SecureEnclaveIdentityInfo: Codable {
    var publicKeyX963: Data
    var createdAt: Date
}
```

```swift
struct SSHUserCertificate: Codable {
    var certificateBlob: Data
    var certificateType: String
    var keyID: String
    var serial: UInt64
    var principals: [String]
    var validAfter: UInt64
    var validBefore: UInt64
    var caKeyType: String
    var caFingerprint: String
    var comment: String?
}
```

### 4.3 Storage rules

```text
software private key
    -> Keychain

Secure Enclave private key
    -> Secure Enclave / Keychain reference

public key metadata
    -> local persistence

OpenSSH certificate
    -> local metadata / CloudKit-safe public data

password
    -> Keychain
```

OpenSSH certificates are public credentials and may sync with identity metadata.

Secure Enclave private keys are device-bound and must not be represented as synchronizable private keys.

For a Secure Enclave identity synced to another device:

```text
Profile + identity metadata arrives
Private key unavailable on this device
-> identity shown as unavailable
-> user may generate/import another identity
```

Do not imply that Secure Enclave private material can move between devices.

### 4.4 Remove

Remove from the minimal fork:

- YubiKey
- FIDO2 security keys
- external SSH agents
- OpenPubkey/OIDC
- GPG integration
- GPG keygrips
- SSH agent server
- SSH agent forwarding

Preserve the existing device-only / backup-only / iCloud-sync storage abstraction for synchronizable software keys.

Secure Enclave identities must always remain device-bound regardless of sync metadata.

---

## 5. tmux

tmux means native tmux control mode, not merely opening `tmux` inside a terminal.

### Required

Support:

```bash
tmux -CC
```

Map:

- tmux session -> attached terminal session
- tmux window -> app tab
- tmux pane -> app split
- active window changes -> selected tab
- pane resize -> native split resize
- window title -> tab title

Keep the existing Rootshell/Ghostty control-mode architecture where Ghostty owns protocol parsing and pane terminal state while Swift consumes reconcile actions.

### Required actions

- attach
- create session
- detach
- switch session
- create window
- close window
- rename window
- create pane
- close pane
- zoom pane
- select pane
- resize pane

### SSH integration

Per SSH profile:

```text
tmux:
  Off
  tmux
  tmux Control Mode
```

For control mode:

```bash
tmux -CC new-session -A -s <session>
```

### Remove from tmux v1

- Tab Exposé integration
- elaborate tmux session previews
- herdr
- zellij
- zmx
- multiplexer discovery beyond tmux
- session thumbnails
- advanced pane/window administration menus

Keep underlying controller functionality if removing individual operations creates more coupling than it saves, but do not expose unnecessary UI.

Two items first listed here were kept, because removing them cost more than it
saved:

- **Hidden windows.** A tmux window can be hidden rather than killed — the
  `hideTab` close action and the tmux tab menu both reach it. The window keeps
  running on the server and the tab strip skips it. The hidden set is stored in
  the session's `@hidden` user option in the conventional control-mode wire
  format (`TmuxHiddenWindowsCodec`), so it survives reattach and is shared with
  other control-mode clients of the same session. tmux emits no notification for
  a user-option change, so a second client picks it up at its next attach.
- **Gateway grouping.** A `-CC` gateway and its projected window tabs form one
  derived tab group, `TabGroupID.tmux(ownerID:)`. That is the derived grouping of
  §2.1 applied to tmux, not a separate feature.

The remaining session surface is `TmuxSessionDashboardView`: list the server's
sessions and their windows, switch the gateway's attached session, create,
rename or kill a session, and detach. No previews, no thumbnails.

---

## 6. iCloud Sync

Use two independent mechanisms.

### 6.1 CloudKit

Sync non-secret application data through the user's private CloudKit database.

#### SSHProfile

```text
id
name
host
port
username
authType
identityID?
jumpHost?
terminalType?
tmuxMode
tmuxSessionName?
modifiedAt
deleted
```

#### SSHIdentityMetadata

```text
id
name
keyType
fingerprint
storageType
publicKey
certificate?
secureEnclaveDeviceBound
modifiedAt
deleted
```

For Secure Enclave identities:

```text
secureEnclaveDeviceBound = true
```

Only public metadata is synchronized.

Never upload the Secure Enclave private-key reference as though it were portable key material.

#### KnownHost

```text
id
hostname
port
keyType
publicKey
fingerprint
firstSeen
lastSeen
modifiedAt
deleted
```

#### AppSetting

One record per settings key, named by its `UserDefaults` key and carrying a
self-describing `CodableValue` JSON payload, so adding a setting never changes
the record schema.

Which keys travel is a property of the setting rather than a list kept here.
Every key is declared once in `SettingsRegistry` with a `SyncPolicy`:

```text
synced          syncs unless the user pins it to this device
localByDefault  syncs, but starts pinned — device-shape or platform specific
deviceOnly      never leaves the device and has no pin UI
```

Of the 115 registered settings, 63 are `synced`, 26 are `localByDefault`, and 26
are `deviceOnly` (sync state, device ID, change token, restoration counters).
`tests/ShellTests/SettingsRegistryInventoryTests.swift` holds the inventory, so
a policy flip that starts pushing a key to iCloud shows up as a diff.

Reuse the existing CloudKit synchronization mechanics where useful, including offline queueing, sync state, conflict handling, and deterministic records, but do not reuse the broad Rootshell production schema.

Create fork-specific record types.

### Do not sync

- terminal contents
- scrollback
- active shell processes
- active SSH sessions
- tmux contents
- shell history
- command history
- analytics
- usage counters

---

## 7. Secret Sync

Passwords and private keys must never be stored as plaintext CloudKit fields.

Use:

```text
CloudKit
    profiles
    known hosts
    preferences
    public identity metadata
    OpenSSH user certificates

iCloud Keychain
    saved passwords
    synchronizable software private SSH keys

Secure Enclave
    device-bound private keys
```

A profile may contain:

```text
auth = key(<UUID>)
```

while the corresponding identity resolves locally.

Possible states:

```text
Software key synchronized
-> usable

Software key metadata synchronized but Keychain key pending
-> "SSH key not yet available"

Secure Enclave identity created on this device
-> usable

Secure Enclave identity metadata from another device
-> "Secure Enclave key belongs to another device"
```

Never silently fall back to password authentication.

Certificates should follow identity metadata because they contain no private-key material.

---

## 8. Fork-Specific Apple Configuration

Do not keep Rootshell's identifiers.

Create new:

```text
Bundle ID
Keychain access group
CloudKit container
iCloud container
App Group, only if genuinely needed
```

As built (`Configuration/Base.xcconfig`, `shell/Entitlements/Shell.entitlements`):

```text
Bundle ID              dev.chr33s.shell
Keychain access group  $(AppIdentifierPrefix)dev.chr33s.shell
CloudKit container     iCloud.dev.chr33s.shell
```

No App Group: nothing outside the app process needs one.

Minimal entitlements should be approximately:

```text
App Sandbox
Network Client
iCloud
CloudKit
Keychain
User-selected files, if key/certificate import requires it
```

Secure Enclave should use the normal Security/Keychain path and must not bring YubiKey/NFC/smartcard entitlements into the fork.

Remove:

```text
aps-environment
NFC
smartcard
associated-domains
networkextension
multicast
multipath
wifi-info
```

Remove application groups if no extension/shared process needs them.

### Deployment target

```text
IPHONEOS_DEPLOYMENT_TARGET = 26.0   iOS, iPadOS, and Mac Catalyst
XROS_DEPLOYMENT_TARGET     = 26.0   visionOS
```

Only the current and next OS majors are supported: 26 and 27. There is no
`[sdk=macosx*]` override, because Catalyst takes its macOS version from
`IPHONEOS_DEPLOYMENT_TARGET`.

Treat this as an architectural constraint, not a build setting. The pre-26
availability rail is gone: no `#available` check survives anywhere in the
sources, they call 26-only API un-gated, and the only `@available` attributes
left are four `@available(*, unavailable)` `required init?(coder:)` traps.
Lowering the floor will not compile.

---

## 9. The Mac Build

The Mac build is Mac Catalyst, not native macOS.

```text
SUPPORTED_PLATFORMS    = iphoneos iphonesimulator xros xrsimulator
SUPPORTS_MACCATALYST   = YES
TARGETED_DEVICE_FAMILY = 1,2,7
```

Deployment targets are in §8. `UIDesignRequiresCompatibility` appears in no plist,
xcconfig or project file, so Catalyst runs the Mac idiom rather than scaled iPad.
Do not set it; it changes control metrics app-wide.

### The AppKit support bundle

`NSApplication`, `NSWindow` and `NSMenu` are unavailable to Catalyst at compile
time. `ShellMacSupport` is a second target — `SDKROOT = macosx`,
`MACOSX_DEPLOYMENT_TARGET = 26.0`, product `ShellMacSupport.bundle` — embedded by
a build phase filtered to `maccatalyst` and loaded on first use through
`Bundle.principalClass` (`shell/UI/Window/MacSupport.swift`). iOS and visionOS do
not depend on it. `ShellMacSupport/` and `Shared/` are top-level directories.

`Shared/MacBridge.swift` is the only ABI: the `MacBridge` protocol plus the two
`@objc` handle protocols it hands back, `MacShellProcess` and `MacMenuEntry`. Every
call runs on the main thread; AppKit objects stay opaque to Catalyst as `NSObject`.
It provides window furniture; appearance (glass backdrop, blur, app appearance);
menus (Dock, Services, and the entries native context menus are built from);
terminal events (scroll, hover, menu); the local PTY (`createShell` /
`MacShellProcess`); and Text Input Services. It exists so the app gets typed AppKit
instead of KVC string
reflection, which also removes the App Store review risk of KVC into undeclared
AppKit surface. Add a bridge method, never a reflection site: three
`NSClassFromString` sites remain, all in `CatalystAppDelegate` and all about other
subsystems, and the bundle's only undeclared surface is Ghostty's private
`_cornerRadius`.

Two mechanisms, recorded so nobody re-derives the wrong one. Per-window
restoration is keyed by scene session id through
`CatalystSceneDelegate.stateRestorationActivity(for:)`, never
`NSWindow.restorationClass` — AppKit window restoration is not the mechanism under
Catalyst, where UIKit scene sessions own it. The Dock menu adds the missing
`applicationDockMenu(_:)` to the class of the delegate UIKit vends with
`class_addMethod`, which declines if a future UIKit implements it, so nothing is
swizzled.

Settings is its own `UIWindowScene` (`shell/UI/Settings/MacSettingsWindow.swift`),
not a SwiftUI `Settings` scene. About, Close Tab, Close Window and tab navigation
go through the bridge; File ▸ Open Recent lists saved SSH profiles.

### Native macOS is out of scope

Hard blocker: libghostty ships no native macOS slice.
`GhosttyKitAppStore.xcframework` carries exactly `ios-arm64`,
`ios-arm64-simulator`, `ios-arm64_x86_64-maccatalyst`, `xros-arm64` and
`xros-arm64-simulator`, and `scripts/build-framework.sh` regenerates that same
three-platform package and audits only for a `-maccatalyst` library. Catalyst
binaries cannot link into an `SDKROOT = macosx` target, so a native port begins by
rebuilding and republishing GhosttyKit with a `macos-arm64_x86_64` slice.

Second, the UI layer is a rewrite rather than a port. Counted 2026-09-06 as source
lines mentioning each symbol across `shell/`, `Shared/`, `ShellMacSupport/` and
`tests/`; re-run rather than trust:

```text
375 Swift files, 107 import UIKit (358 / 104 excluding tests/)
446 targetEnvironment(macCatalyst) across 101 files, 18 Representable bridges
UIKeyCommand 221  UIView 227 (151 at word boundaries)  UIApplication 181
UIColor 88  UIWindowScene 66  UIScrollView 55  UIFont 31  UIDevice 29
UITextInput 27  UIMenu 24  UIPasteboard 22  UIGestureRecognizer 18
```

The terminal view, key routing, window and scene management, menus, cursor,
clipboard and every touch affordance would all be replaced: roughly 60 files of new
AppKit UI, multi-month, blocked on the GhosttyKit rebuild. Weigh that on the whole
list, not on `UIKeyCommand` alone: its count has fallen substantially, first when
the pre-26 availability rail of §8 took the below-26 keybind branch with it, then
again when §2.1's dead command chains took their bindings. Do not add a second
application target.

### Accepted limitations of Catalyst

The price of the decision above, not open work. Key handling stays `UIKeyCommand`,
so dead keys, some Option-composed characters and non-Latin input methods stay
slightly off versus `NSTextInputClient`; text input stays `UITextInput`, so
input-method candidate handling is an approximation; VoiceOver on the Mac stays
UIKit-derived.

### Native NSWindow tabs are not adopted

AppKit tabs are one window per tab, and a tab here is not a window's worth of
content: it owns a `SplitTree` of panes, carries the derived group identity of
§2.1, and a tmux gateway tab owns child window tabs that must move with it. One
scene per tab expresses none of that, so adopting native tabs means deleting tab
groups, tmux window tabs and splits-within-a-tab — a product decision, not a
refactor. The in-window tab bar stays custom.

The Window menu carries the affordances native tabs would have brought
(`shell/App/MacApplicationCommands.swift`): the fixed system chords ⌃⇥ / ⌃⇧⇥,
Previous/Next Tab on ⌘⇧[ / ⌘⇧] beside the rebindable actions in the Tabs menu, Move
Tab to New Window, and Merge All Windows. No hand-built window list is needed;
Catalyst's Window menu already lists open windows. Ghostty's `CAMetalLayer` on
tear-off is unreachable rather than untested — the incompatibility is in the tab
model, so there is nothing to prototype.

### Menu-bar state

`AppCommands.swift` owns the menu bar outright; there is no `UIMenuBuilder` rail.
Eight `MenuToggleItem`s are checkable, seven of them on the Mac — Full Screen is
gated to iPad because AppKit owns Enter Full Screen. Each is a SwiftUI `Toggle`
reading its own truth in its own body; no bridge surface was added for this and none
should be, because a title-walk over `NSApp.mainMenu` would match localized titles
and be wiped by UIKit's menu rebuilds.

Mixed state is inapplicable, not pending. Every toggle resolves to exactly one truth
and no action fans out — each dispatches `sendAction(_:to:from:for:)` with a nil
target, the fallback stamps the post with one scene session id, and
`shouldHandleNotification` filters every other window out — so unknown state
renders unchecked-and-disabled,
the correct macOS idiom. Do not reopen this as a task; it becomes reachable only if
an action starts acting on more than one object. The `-1` encoding in
`MacMenuEntry.state` stays regardless, because native context menus build entries
from `UIAction.state`.

### Touch affordances are fenced out of Catalyst

Every touch affordance is fenced with `!targetEnvironment(macCatalyst)`. The
selection loupe, the selection handles and status-bar styling are whole files behind
the fence; the pinch and long-press gestures and the general-purpose impact feedback
are fenced regions. The keyboard accessory and `KeyboardGeometryMonitor` are
neutered rather than removed — their types still compile on Catalyst and every
Catalyst path through them returns the empty answer — which is the shape to use
wherever shared code names the type. Do not add a touch affordance without a
Catalyst fence. `KeyboardTracker` must not be deleted wholesale: it also owns
physical modifier handling.

### Unverified

A human review pass on 2026-09-06 exercised the app and found it working. That was a
general review, not a per-item checklist against the list below: no item on it has a
recorded outcome, and every one is unresolved rather than failed.

Each needs a running Catalyst app — the AppKit titlebar, the glass backdrop, native
scroll, the context menu, the Dock menu, and multi-window restore across a quit and
relaunch; whether File shows both "Close Tab" and SwiftUI's own "Close"; whether a
Settings window left open at quit comes back; whether the Services item appears at
all, is enabled rather than greyed (AppKit greys it unless the responder chain
answers `validRequestor(forSendType:returnType:)`) and survives a menu rebuild;
whether a SwiftUI `Toggle` in a `CommandGroup` renders an `NSMenuItem` checkmark
under Catalyst 26 at all, which is the one load-bearing untested assumption behind
Menu-bar state above; whether `DynamicShortcut` still publishes the key-equivalent
glyph on a `Toggle`; and whether the checkmarks track focus as it moves between
panes, tabs and windows.

None of it has a unit-test home. The suite runs on the iOS Simulator (§17), and must:
13 of the 16 files in `shell/Core/Shell/` and most of `shell/Features/LocalShell/`
sit behind `#if !targetEnvironment(macCatalyst)`, so it does not compile on a
Catalyst destination. Catalyst-only behaviour is verified by hand or not at all.

The Catalyst work landed as a six-phase plan chosen over a native port. That plan,
its estimates, the native-versus-Catalyst deliberation and the dated implementation
changelog are in git history at `macos-native.md`, and are not repeated here.

---

## 10. Source Tree — Keep

Treat this as the initial retention set, not a guarantee that every file within each directory survives.

```text
rootshell/App/

rootshell/Core/Foundation/
rootshell/Core/Ghostty/
rootshell/Core/Connection/
rootshell/Core/Networking/
rootshell/Core/Persistence/
rootshell/Core/Preferences/
rootshell/Core/Keybinds/
rootshell/Core/CloudKit/
rootshell/Core/SettingsSync/

rootshell/Features/LocalShell/
rootshell/Features/SSH/
rootshell/Features/Tmux/

rootshell/UI/Terminal/
rootshell/UI/Tabs/
rootshell/UI/Settings/
rootshell/UI/Window/

rootshell/Entitlements/
rootshell/Resources/
rootshell.xcodeproj/
```

Within `Features/SSH`, retain primarily:

```text
SSH/Config
SSH/HostTrust
SSH/Keys
SSH/Session
SSH/Settings
SSH/Views
```

Within `SSH/Keys`, explicitly preserve components required for:

```text
software keys
Secure Enclave
OpenSSH user certificates
Keychain persistence
fingerprinting
authentication resolution
```

Heavily prune or remove:

```text
SSH/Agent
SSH/OpenPubkey
SSH/Discovery
```

unless a specific dependency proves necessary.

As built, `rootshell/` is `shell/`, and the retention set holds with three
adjustments: `Core/Networking/` did not survive as a directory — the surviving
helpers are in `Core/Connection/`; `Features/Profiles/` was added for the saved
profile model and its editor; and `Features/SSH/` contains exactly `Config`,
`HostTrust`, `Keys`, `Session`, `Settings` and `Views`, with `Agent`,
`OpenPubkey` and `Discovery` gone. `Core/` has also been subdivided past the list
above — `Animation`, `Prompt`, `Security`, `Shell`, `Sync`, `System`, `Terminal` and
`Theme` sit alongside the retained directories.

---

## 11. Source Tree — Delete

Delete entire feature families for:

```text
AI Agent
Agent Attention / Agent Inbox
Agent Usage
Automation
Cloud provider integrations
Kubernetes
VNC / Screen Sharing
Mosh
TSSH / Rootshell Roam
VPN
Port Forwarding
GPG
Git client
File Browser
Croc
Helix
Vim runtime
WASM tools
Effects / shaders
Live Activities
Push notifications
App Intents / Siri
Tailscale integration
NetBird
HSS
YubiKey
FIDO2
Transfer tools
Cloud consoles
```

Do not delete Secure Enclave or OpenSSH certificate support while pruning `Features/SSH/Keys`.

Also remove top-level targets/directories associated only with deleted features where no remaining dependency exists, including as applicable:

```text
CoreWLANPlugin
PushNotificationService
Packages/RootshellPushKit
SessionActivityWidget
VPNTunnelExtension
rootshellvpn
rootshellvpnTests
rootshellvpnUITests
push
tunnel
wasm
VimRuntime.bundle
```

None of those exist in the tree. Three targets remain: `shell`,
`ShellMacSupport` (the AppKit bridge bundle Catalyst loads through
`Shared/MacBridge.swift`), and `ShellTests`.

---

## 12. Dependency Rule

After extraction, the desired dependency graph is:

```text
App/UI
  |
  +-- Terminal
  |     +-- Ghostty/libghostty
  |
  +-- SSH
  |     +-- SSH transport library
  |     +-- Identity Store
  |     |      +-- Keychain
  |     |      +-- Secure Enclave
  |     |      +-- OpenSSH Certificates
  |     +-- Terminal
  |
  +-- tmux
  |     +-- Ghostty tmux control mode
  |     +-- SSH raw transport
  |
  +-- Sync
        +-- CloudKit
        +-- Keychain
```

No surviving core module may import:

```text
AI
VNC
VPN
Mosh
TSSH
CloudProviders
Kubernetes
Push
GPG
Git
FileBrowser
AgentAttention
YubiKey
FIDO2
OpenPubkey
```

This is an architectural invariant for the fork.

---

## 13. Settings

The entire Settings app should collapse to four sections.

### Terminal

```text
Font size
Theme
Scrollback lines
Session
  Restore Sessions on Launch
  Persist Scrollback History
TERM
  Local
  Remote
Force ASCII Keyboard
Keyboard shortcuts
```

### SSH

```text
Profiles
SSH Identities
Known Hosts
Saved Passwords

Auto Reconnect
Keep SSH Alive in Background
Force IPv4
Connection Health Monitoring    [on/off]
  Probe Interval
```

#### SSH Identity detail

```text
Name
Key Type
Fingerprint
Storage
Security

Secure Enclave: yes/no

OpenSSH Certificate
  Status
  Key ID
  Principals
  Serial
  Valid From
  Valid Until
  CA Fingerprint

Import / Replace Certificate
Remove Certificate
```

### tmux

```text
Default mode
Default session name
Close-window behavior
```

### Sync

```text
iCloud Sync                 [on/off]
Sync Profiles               [on/off]
Sync Known Hosts            [on/off]
Sync Settings               [on/off]
Sync Identity Metadata      [on/off]
Sync Software Keys          [on/off]

Last Sync: ...
Pending Changes: ...
Sync Now
```

Secure Enclave keys must be labelled as device-bound and excluded from private-key synchronization.

No other settings pages.

Settings are edited through these four sections only. The text-configuration
overlay — a Ghostty-style config file the settings store parsed, merged and
rewrote — is removed, and so is its `ConfigOverlay` machinery. Keybinds are the
one exception: they keep their own separate external config file at
`~/.ghostty/imported_keybinds.conf`, imported from Terminal ▸ Keyboard Shortcuts
and re-read by the built-in `reloadconfig` command.

---

## 14. Home / Connection UI

Minimal launch screen:

```text
+--------------------------+
| New Local Terminal       |
|                          |
| SSH                      |
| ------------------------ |
| production               |
| home-server              |
| dev-vm                   |
|                          |
| + Add SSH Host           |
+--------------------------+
```

Selecting an SSH profile immediately opens a terminal tab.

Profile edit screen:

```text
Name
Host
Port
Username
Authentication / Identity
Jump Host

Terminal
  TERM

tmux
  Off / tmux / Control Mode
  Session Name
```

Identity picker should distinguish:

```text
Ed25519
P-256
P-256 · Secure Enclave
P-256 · Secure Enclave · Certificate
Ed25519 · Certificate
```

Nothing else.

---

## 15. Persistence

Persist locally:

- tabs
- split layout
- split-pane zoom
- tab grouping state: grouped mode, active group, group order, per-group tab order
- SSH profile ID associated with each terminal
- local/SSH session type
- tmux attachment metadata
- terminal font size
- terminal theme
- window frame, on Mac Catalyst
- scrollback history, when Persist Scrollback History is on

Restoration as a whole is behind Terminal ▸ Restore Sessions on Launch; with it
off, nothing above is written or read back.

Do not attempt to restore dead SSH network connections directly.

On app relaunch:

```text
Local session -> create new shell
SSH session   -> reconnect
tmux -CC      -> reconnect SSH and reattach tmux
```

tmux is the source of remote session persistence.

---

## 16. Extraction Strategy

Do not begin by deleting hundreds of source files.

Use four phases.

### Phase 1 — Minimal terminal + SSH identity foundation

Bring up the application shell and security primitives first.

Include:

```text
App
Ghostty
Terminal
LocalShell
Tabs

SSH key model
Keychain-backed software key storage
Secure Enclave key generation/signing
OpenSSH certificate parsing/storage
Identity <-> certificate matching
Fingerprinting
Identity management UI
```

Phase 1 explicitly includes Secure Enclave and OpenSSH user certificates, even though remote SSH connections arrive in Phase 2.

This establishes the security model before simplifying `SSHConfig`, CloudKit, or profile persistence around it.

#### Acceptance criteria

Local terminal:

- app launches directly into a working local terminal
- local terminal supports input, scrolling, resizing, and copy/paste

Software identity:

- create/import an SSH key
- persist private key safely in Keychain
- display public-key fingerprint

Secure Enclave:

- generate P-256 Secure Enclave SSH identity
- private key never becomes exportable application data
- public key and fingerprint are available
- signing operation succeeds
- biometric/passcode policy works
- delete operation removes the Secure Enclave identity

OpenSSH certificate:

- import a valid `*-cert.pub`
- reject a certificate that does not match the selected identity
- display key ID, serial, principals, CA fingerprint, and validity
- detect expired/not-yet-valid certificates
- attach certificate to both software and Secure Enclave identities
- replace and remove certificate cleanly

Phase 1 is complete only when the identity subsystem works independently of an SSH network session.

### Phase 2 — SSH

Bring in:

```text
SSH Config
SSH Session
SSH Authentication
Known Hosts
Connection Profiles
Jump Hosts
```

Wire the Phase 1 identity system into SSH authentication.

Acceptance criterion:

> A host can be saved and connected using password, software-key, or Secure Enclave authentication, with or without an attached OpenSSH user certificate.

Additional acceptance:

- server sees the OpenSSH certificate during authentication when attached
- certificate auth works with Secure Enclave-backed keys
- expired/not-yet-valid certificates fail before connection with a useful error
- raw private keys are never substituted when policy requires the attached certificate

### Phase 3 — tmux

Bring in:

```text
Features/Tmux
required Ghostty tmux bridges
```

Acceptance criterion:

> SSH profile configured for control mode runs `tmux -CC`, with tmux windows appearing as native tabs and panes as native splits.

### Phase 4 — Sync

Bring in:

```text
CloudKit core
minimal SettingsSync
iCloud Keychain software-key storage
identity metadata sync
OpenSSH certificate sync
```

Use the fork's own CloudKit container and record schema.

Acceptance criterion:

> Add an SSH profile on Device A and it appears on Device B.

For software identities:

> A key marked for iCloud synchronization is usable once iCloud Keychain has synchronized it.

For OpenSSH certificates:

> Certificate metadata follows the identity across devices.

For Secure Enclave identities:

> Metadata may appear on another device, but the UI clearly reports that the device-bound private key is unavailable there.

Only after all four phases work should unused original source directories and Xcode targets be physically deleted.

---

## 17. Definition of Done

All four phases have landed. The app build is green — no errors, no warnings —
and `./scripts/test.sh` runs the `ShellTests` bundle, 117 tests across 15 test files
under `tests/ShellTests/` (a sixteenth file, `SourceTree.swift`, is a shared helper),
green. That script's destination must be the iOS
Simulator rather than Mac Catalyst: the whole local-shell stack sits behind
`#if !targetEnvironment(macCatalyst)` and does not exist there.
`tests/MacSupportSmoke.swift` is a separate standalone AppKit binary, run by hand.

A box below is ticked only where the claim has actually been checked. The
unticked ones are sign-offs not yet recorded, not known gaps.

### Terminal

Confirmed by a human running this build on a device.

- [x] launches local shell
- [x] typing works
- [x] resize works
- [x] scrolling works
- [x] copy/paste works
- [x] tabs work
- [x] splits work

### SSH Identity

- [ ] Ed25519 software keys work
- [ ] P-256 software keys work
- [ ] Secure Enclave P-256 generation works
- [ ] Secure Enclave signing works
- [ ] Secure Enclave private keys are non-exportable
- [ ] Keychain storage works
- [ ] identity fingerprinting works

### OpenSSH Certificates

- [ ] certificate import works
- [ ] certificate/key matching is validated
- [ ] certificate metadata is parsed
- [ ] certificate validity is checked
- [ ] certificate replacement works
- [ ] certificate removal works
- [ ] certificate authentication works
- [ ] certificate + Secure Enclave authentication works

### SSH

- [ ] password auth
- [ ] private-key auth
- [ ] Secure Enclave auth
- [ ] OpenSSH certificate auth
- [ ] keyboard-interactive auth
- [ ] host-key verification
- [ ] saved profiles
- [ ] known hosts
- [ ] reconnect
- [ ] optional jump host

### tmux

- [ ] regular tmux works
- [ ] `tmux -CC` works
- [ ] windows map to tabs
- [ ] panes map to splits
- [ ] pane resize works
- [ ] detach works
- [ ] reconnect + reattach works

### iCloud

- [ ] profiles sync
- [ ] known hosts sync
- [ ] selected settings sync
- [ ] identity metadata syncs
- [ ] OpenSSH certificates sync
- [ ] synchronizable software keys use iCloud Keychain
- [ ] Secure Enclave private keys never sync
- [ ] conflicts do not duplicate profiles
- [ ] deleted profiles propagate
- [ ] SSH secrets never enter plaintext CloudKit records

### Removal

Checked against the tree. The project has three targets — `shell`,
`ShellMacSupport`, `ShellTests` — and links three packages: GhosttyKit, Citadel,
and ios_system, whose binary targets are `ios_system`, `awk`, `files`, `shell`
and `text`. No vim, git or editor framework is linked.

- [x] no AI code in target
- [x] no VNC code
- [x] no VPN extension
- [x] no Mosh/TSSH
- [x] no push target
- [x] no widgets
- [x] no cloud-provider SDKs
- [x] no Kubernetes code
- [x] no GPG
- [x] no YubiKey/FIDO UI
- [ ] no OpenPubkey/OIDC — the feature and its UI are gone, but `KeychainManager`
      still carries three OpenPubkey secret-blob helpers; only the delete is
      called, from key deletion
- [x] no built-in Git/file-browser/editor tooling
- [x] no shader/effect system — no shader files ship and nothing loads one;
      `CursorManager` still carries an inert `CursorEffect` setting whose only
      reader is itself
- [x] no unused entitlements — sandbox, network client, user-selected files (four
      `fileImporter` call sites), keychain access group, iCloud/CloudKit

Comments in surviving files still name removed features. They are prose, not
code; the code is gone.

---

## 18. Final Target

The finished product should conceptually be:

```text
+-----------------------------------------+
|                  Shell                  |
+-----------------------------------------+
|                                         |
|               libghostty                |
|                                         |
|   Local PTY --+                         |
|               +-- Terminal Surface      |
|   SSH PTY ----+                         |
|               |                         |
|   tmux -CC ---+                         |
|                                         |
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

Design rule:

> If a feature does not make the terminal render, establish a secure SSH identity, make SSH connect, make tmux work, or make those configurations sync, it does not belong in the fork.
