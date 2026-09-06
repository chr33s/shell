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
- grouped/project tabs
- elaborate tab sidebar
- tab carousel animations
- custom imported fonts
- Nerd Font catalog unless one packaged font is required
- cosmetic terminal effects
- agent-status decoration
- screen-sharing tabs

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

---

## 4. SSH Identity & Key Storage

The minimal fork must retain a compact but strong SSH identity subsystem.

### 4.1 Required identity types

#### Software keys

Required:

- Ed25519
- ECDSA P-256

RSA may remain if removing it creates unnecessary work.

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

- hidden-window synchronization
- Tab Exposé integration
- elaborate tmux session previews
- tmux gateway grouping
- herdr
- zellij
- zmx
- multiplexer discovery beyond tmux
- session thumbnails
- advanced pane/window administration menus

Keep underlying controller functionality if removing individual operations creates more coupling than it saves, but do not expose unnecessary UI.

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

Only sync settings that matter to this fork:

```text
fontSize
theme
terminalType
scrollbackLimit
tmuxDefaultMode
tmuxDefaultSession
```

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

Example:

```text
com.example.shell
iCloud.com.example.shell
```

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

---

## 9. Source Tree — Keep

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

---

## 10. Source Tree — Delete

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

---

## 11. Dependency Rule

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

## 12. Settings

The entire Settings app should collapse to four sections.

### Terminal

```text
Font size
Theme
Scrollback
TERM
Keyboard shortcuts
```

### SSH

```text
Profiles
SSH Identities
Known Hosts
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
```

Secure Enclave keys must be labelled as device-bound and excluded from private-key synchronization.

No other settings pages.

---

## 13. Home / Connection UI

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

## 14. Persistence

Persist locally:

- tabs
- split layout
- SSH profile ID associated with each terminal
- local/SSH session type
- tmux attachment metadata
- terminal font size
- terminal theme

Do not attempt to restore dead SSH network connections directly.

On app relaunch:

```text
Local session -> create new shell
SSH session   -> reconnect
tmux -CC      -> reconnect SSH and reattach tmux
```

tmux is the source of remote session persistence.

---

## 15. Extraction Strategy

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

## 16. Definition of Done

### Terminal

- [ ] launches local shell
- [ ] typing works
- [ ] resize works
- [ ] scrolling works
- [ ] copy/paste works
- [ ] tabs work
- [ ] splits work

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

- [ ] no AI code in target
- [ ] no VNC code
- [ ] no VPN extension
- [ ] no Mosh/TSSH
- [ ] no push target
- [ ] no widgets
- [ ] no cloud-provider SDKs
- [ ] no Kubernetes code
- [ ] no GPG
- [ ] no YubiKey/FIDO UI
- [ ] no OpenPubkey/OIDC
- [ ] no built-in Git/file-browser/editor tooling
- [ ] no shader/effect system
- [ ] no unused entitlements

---

## 17. Final Target

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
