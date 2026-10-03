# Local SSH Agent Bridge

**Status:** Proposed  
**Repository:** `chr33s/shell`  
**Target:** iOS / iPadOS / visionOS / sandboxed Mac Catalyst local-shell interpreter  
**Source baseline:** `main`, inspected 2026-10-03  
**Scope:** Expose Shell-managed SSH identities to bundled local CLI tools through the standard OpenSSH `SSH_AUTH_SOCK` protocol, without exporting private key material and without enabling remote SSH agent forwarding.

Capitalized **MUST**, **MUST NOT**, **SHOULD**, and **MAY** are normative.

## 1. Goal

Shell already owns SSH identities in the Keychain and Secure Enclave, but the local `ios_system` shell cannot currently use those identities through the standard OpenSSH agent interface.

This feature adds a process-local SSH agent bridge so commands such as bundled `ssh`, `scp`, and `sftp` can authenticate using the same Shell-managed identities without writing private keys into `~/.ssh`.

```text
+------------------------------------------------------+
|                       Shell                          |
|                                                      |
|  Settings / SSH Keys                                 |
|        |                                             |
|        v                                             |
|  SSHKeyManager + SSHKeyAuthManager                   |
|        |                                             |
|        | software key -> Keychain                    |
|        | SE P-256    -> Secure Enclave               |
|        v                                             |
|  LocalSSHAgentService                                |
|        |  AF_UNIX / SSH agent protocol               |
|        v                                             |
|  $SSH_AUTH_SOCK                                      |
|        |                                             |
|        +--> ssh                                      |
|        +--> scp                                      |
|        +--> sftp                                     |
|        +--> future compatible local tools            |
+------------------------------------------------------+
```

The bridge MUST preserve Shell's existing key-storage and authentication guarantees. A Secure Enclave private key MUST remain non-exportable; the agent may request a signature but MUST never receive or materialize the private key outside the existing Secure Enclave-backed key object.

## 2. Non-goals

This feature does **not** restore the broad agent features removed from Rootshell.

The following remain out of scope:

- remote SSH agent forwarding (`ForwardAgent`, `auth-agent-req@openssh.com`);
- accepting an external/system SSH agent as Shell's identity source;
- forwarding the local agent into remote SSH sessions;
- `ssh-add`-style mutation of Shell's key store;
- FIDO2 / `sk-*` identities;
- PKCS#11, smartcards, NFC, YubiKey, GPG, or keygrips;
- a background daemon that survives app termination;
- exposing the socket outside Shell's app/container boundary;
- storing private keys or passphrases in shell-visible files.

## 3. Relationship to `docs/specs/shell.md`

`docs/specs/shell.md` §4.6 currently lists both `SSH agent server` and `agent forwarding` as removed.

This feature introduces a narrow exception:

> Shell MAY expose its own managed SSH identities to its own local interpreter through a process-local, read-only SSH agent bridge. This does not permit remote agent forwarding, external agents, agent mutation, or private-key export.

When this feature lands, §4.6 SHOULD be updated so the removed list distinguishes:

- **removed:** external SSH agents;
- **removed:** remote agent forwarding;
- **supported:** local in-process agent bridge for Shell-managed identities.

No other product-scope exception is created.

## 4. Existing components to reuse

The implementation MUST reuse the existing identity and authentication paths instead of introducing a second key store or crypto lifecycle.

Relevant existing components:

| Component | Existing responsibility | Agent use |
| --- | --- | --- |
| `SSHKeyManager` | identity metadata, Keychain loading, Secure Enclave reconstruction | source of exposed identities and private-key loading |
| `SSHKeyAuthManager` | `.none`, `.perSession`, `.perUse`, biometric/passcode deduplication | unchanged auth policy for agent signing |
| `SSHSecureEnclaveKeyFactory` | Secure Enclave P-256 creation/access control | unchanged hardware-backed signing |
| `SSHPublicKeyBlob` | SSH wire-format public key blobs | identity matching |
| `SSHUserCertificateInfo` | attached OpenSSH user certificates | optional agent certificate identities |
| Citadel `SSHAgentProtocol.swift` | agent message types, parser, serializer | protocol codec |
| `LocalShellSession+IOSSystem.swift` | local interpreter environment | exports `SSH_AUTH_SOCK` |

Vendored Citadel files SHOULD NOT be modified. New code should consume their public agent protocol types so future vendor refreshes remain mechanical.

## 5. User-visible behavior

### 5.1 Local shell

When the local backend is `.interpreter` and the local-agent feature is enabled:

```sh
echo "$SSH_AUTH_SOCK"
```

MUST return a live Unix-domain socket path owned by the Shell process.

Bundled OpenSSH clients MUST be able to authenticate through that socket without private-key files:

```sh
ssh user@example.com
scp file.txt user@example.com:/tmp/
sftp user@example.com
```

`SSH_AGENT_PID` MUST NOT be set. There is no child `ssh-agent` process.

### 5.2 Native Mac local shell

When `LocalShellBackend.current == .nativePTY`, Shell MUST NOT overwrite an existing host `SSH_AUTH_SOCK`.

The unsandboxed Catalyst/native-PTY path should continue to behave like the user's normal macOS shell and system agent environment.

### 5.3 Agent management

The agent is managed by Shell, not by shell clients.

The local agent's loaded key set MUST be derived from `SSHKeyManager.defaultKeyIDs`, in order. `savedKeys` represents stored credentials; `defaultKeyIDs` represents credentials intentionally available for generic authentication attempts.

This is analogous to the distinction between keys existing on disk and keys explicitly loaded into a desktop `ssh-agent`.

If `defaultKeyIDs` is empty, the agent MUST report zero identities.

## 6. Settings

Add one device-local setting:

```text
Connections > Local SSH Agent
```

Semantics:

| Value | Behavior |
| --- | --- |
| On | start the local agent for interpreter-backed local shells and export `SSH_AUTH_SOCK` |
| Off | do not start the agent and do not export `SSH_AUTH_SOCK` |

Recommended default: **On**.

The setting MUST use `SyncPolicy.deviceOnly`. It controls a device execution capability and MUST NOT propagate through iCloud.

Turning the setting off MUST close the listening socket and unlink its filesystem entry. Existing client connections MAY be closed immediately.

Turning it on MUST make the bridge available to newly launched local commands without requiring an app restart.

## 7. Identity exposure policy

### 7.1 Base identities

For each UUID in `SSHKeyManager.defaultKeyIDs`, the bridge MUST:

1. resolve the UUID against the current local `savedKeys` set;
2. require a cached `publicKeyBlob` or derive/backfill it through existing key-manager mechanisms;
3. exclude an identity whose private material is not usable on the current device;
4. preserve `defaultKeyIDs` ordering in `SSH_AGENT_IDENTITIES_ANSWER`.

A key that exists only as synced public metadata from another device MUST NOT be advertised.

A legacy key currently marked `keysNeedingUnlock` MUST NOT be advertised until it becomes locally usable.

### 7.2 OpenSSH user certificates

If a default identity has an attached certificate that is currently valid:

- the certificate identity MUST be advertised immediately before the raw public-key identity for the same private key;
- both identity blobs MUST resolve to the same private signing key;
- the certificate comment SHOULD be `Shell: <name> (certificate)`;
- the raw-key comment SHOULD be `Shell: <name>`.

Expired or not-yet-valid certificates MUST NOT be advertised.

Advertising both certificate and raw-key forms preserves certificate-first behavior while allowing raw-key fallback when a server does not accept the certificate.

### 7.3 Dynamic changes

Identity enumeration MUST be computed from current key-manager state or from an invalidatable snapshot.

Changes to any of the following MUST become visible without restarting the app:

- default-key ordering;
- key import/delete;
- key becoming available after iCloud Keychain sync;
- legacy-key unlock/migration;
- certificate attach/replace/remove/expiry.

The bridge MUST tolerate a key disappearing between `requestIdentities` and `signRequest`; the later sign request returns agent failure.

## 8. Protocol surface

The bridge implements the OpenSSH SSH agent protocol over a local `AF_UNIX` stream socket.

### 8.1 Supported requests

V1 supports exactly:

| Agent request | Behavior |
| --- | --- |
| `SSH2_AGENTC_REQUEST_IDENTITIES` / type `11` | return current exposed identity list |
| `SSH2_AGENTC_SIGN_REQUEST` / type `13` | authenticate/load matching key and return signature |
| extension request / type `27` | return `SSH_AGENT_EXTENSION_FAILURE` unless explicitly implemented later |

### 8.2 Unsupported requests

All mutation/control requests MUST fail:

- add identity;
- add constrained identity;
- remove identity;
- remove all identities;
- add/remove smartcard key;
- lock/unlock;
- unknown message types.

Unsupported non-extension requests MUST receive `SSH_AGENT_FAILURE`.

The connection MUST NOT silently ignore an unsupported request because OpenSSH clients may otherwise wait indefinitely for a response.

### 8.3 Framing

Agent messages are framed as:

```text
uint32_be payload_length
byte[payload_length] payload
```

The socket handler MUST support:

- fragmented headers;
- fragmented payloads;
- multiple complete messages in one read;
- multiple sequential requests on one connection.

A single frame MUST be capped at **256 KiB**. A length larger than the cap MUST terminate that client connection without allocating the declared size.

Malformed frames MUST fail closed and MUST NOT crash the app or agent service.

## 9. Socket service

Introduce a process-wide service, conceptually:

```swift
actor LocalSSHAgentService {
    static let shared = LocalSSHAgentService()

    func startIfNeeded() async throws -> String // returns socket path
    func stop() async
    var socketPath: String? { get }
}
```

The concrete isolation model MAY differ, but the service MUST satisfy the lifecycle rules below.

### 9.1 Socket path

Use a short path inside the app's temporary container, e.g.:

```text
<TMPDIR>/sa-<pid>.sock
```

Requirements:

- MUST reside inside Shell's writable app container;
- MUST fit Darwin `sockaddr_un.sun_path` limits before bind;
- MUST NOT use a predictable system-global path outside the sandbox;
- parent directory MUST not be made group/world writable by Shell;
- stale socket files at the selected path MUST be unlinked before bind;
- the socket entry SHOULD be mode `0600` after bind.

If no valid in-container Unix-socket path can be created, startup MUST fail closed and `SSH_AUTH_SOCK` MUST remain unset.

### 9.2 Listener implementation

The service SHOULD use the already-present SwiftNIO stack, with an `AF_UNIX` `ServerBootstrap` and one channel handler per connected client.

A new plain-byte handler is required; Citadel's existing `AgentChannelHandler` is for SSH `auth-agent@openssh.com` channel data and MUST NOT be reused as the Unix socket transport handler.

The new handler SHOULD reuse:

- `SSHAgentMessageParser`;
- `SSHAgentMessageSerializer`;
- `SSHAgentDelegate` or an equivalent adapter interface.

### 9.3 Concurrency

The listener and socket I/O MUST NOT run on `MainActor`.

Calls into `SSHKeyManager` / `SSHKeyAuthManager` MUST respect their actor isolation.

Multiple local clients MAY connect concurrently.

For a given key, concurrent authenticated loads MUST continue to share the existing `SSHKeyAuthManager.loadWithDeduplication` behavior so one burst of sign requests does not create duplicate biometric prompts.

## 10. Local-shell integration

`LocalShellSession` MUST export `SSH_AUTH_SOCK` only after the listener has successfully bound.

Pseudo-flow:

```text
create local interpreter session
        |
        v
is Local SSH Agent enabled?
        |
   yes  v
await LocalSSHAgentService.startIfNeeded()
        |
        +-- success -> ios_setenv("SSH_AUTH_SOCK", path, 1)
        |
        +-- failure -> ios_unsetenv("SSH_AUTH_SOCK") / leave unset
        v
start local shell
```

The implementation MUST NOT publish a socket path before bind completion; clients receiving a stale/unbound `SSH_AUTH_SOCK` create confusing intermittent failures.

If the service later restarts at a different path, new interpreter sessions MUST receive the new path. Existing running shell sessions MAY keep the old environment value; preferably the service SHOULD reuse its per-process path so restart does not require env mutation.

## 11. Signing adapter

Introduce a Shell-owned adapter, conceptually:

```swift
struct ShellSSHAgentDelegate: SSHAgentDelegate {
    func listIdentities() async throws -> [SSHAgentIdentity]

    func sign(
        publicKeyBlob: ByteBuffer,
        data: ByteBuffer,
        flags: UInt32
    ) async throws -> ByteBuffer?
}
```

### 11.1 Blob-to-key resolution

The bridge MUST resolve sign requests by exact public-key blob equality.

Accepted lookup blobs are:

- the identity's cached raw `publicKeyBlob`;
- a currently valid attached certificate's `certificateBlob`.

The bridge MUST NOT select a private key by display name, partial fingerprint, algorithm alone, or positional index.

### 11.2 Private-key loading

After resolving the key UUID, signing MUST use:

```swift
try await SSHKeyManager.shared.loadPrivateKey(id: keyID)
```

or a refactored shared async API with equivalent behavior.

The agent MUST NOT call the legacy synchronous loader for protected keys.

This preserves:

- Keychain ACL behavior;
- app-level authentication for iCloud-synchronized software keys;
- `.perSession` caching;
- `.perUse` authentication;
- biometric/passcode cancellation semantics;
- legacy encrypted-key migration;
- Secure Enclave authenticated reconstruction.

### 11.3 Signature encoding

The agent response MUST contain a standard SSH signature blob appropriate to the underlying key type.

V1 MUST support every software key type already supported for native SSH authentication:

- Ed25519;
- ECDSA P-256;
- ECDSA P-384;
- ECDSA P-521;
- RSA;
- Secure Enclave P-256.

Algorithm behavior MUST remain aligned with native Shell SSH authentication.

For RSA:

- flag `SSH_AGENT_RSA_SHA2_256` (`2`) MUST request `rsa-sha2-256`;
- flag `SSH_AGENT_RSA_SHA2_512` (`4`) MUST request `rsa-sha2-512`;
- if neither flag is present, the bridge MUST use the same permitted/default RSA-signature policy as Shell's native SSH stack;
- the bridge MUST NOT independently re-enable deprecated SHA-1 `ssh-rsa` signatures if native Shell authentication rejects them.

Certificate identity lookup changes only which public identity the client is presenting. The actual signing operation MUST use the corresponding private key and emit the signature format expected for that key/certificate flow.

### 11.4 Shared signing implementation

If current native SSH authentication does not expose a reusable algorithm-accurate signing helper, implementation SHOULD extract one rather than duplicate key-specific encoding in the agent.

Suggested boundary:

```swift
enum SSHPrivateKeySigner {
    static func signAgentPayload(
        key: SSHPrivateKeyVariant,
        keyType: SSHKey.KeyType,
        data: ByteBuffer,
        flags: SSHAgentSignatureFlags
    ) throws -> ByteBuffer
}
```

Native SSH and local-agent tests SHOULD exercise the same primitive wherever practical.

## 12. Authentication behavior

The agent MUST preserve each key's `KeyAuthRequirement`.

| Requirement | Agent behavior |
| --- | --- |
| `.none` | sign without extra user authentication once the key is loadable |
| `.perSession` | first protected use authenticates; later uses follow existing session timeout/cache behavior |
| `.perUse` | every signing use requires fresh authentication according to existing policy |

If the user cancels Face ID / Touch ID / passcode, the sign request MUST return `SSH_AGENT_FAILURE`.

Cancellation MUST NOT mark a `.perSession` key authenticated.

The bridge MUST NOT introduce a separate auth cache.

## 13. Secure Enclave behavior

Secure Enclave P-256 is a primary use case for the bridge.

For a Secure Enclave identity:

- `requestIdentities` returns only public metadata;
- `signRequest` reconstructs the existing device-bound reference through `SSHKeyManager`;
- the private scalar MUST never be exported, serialized into the socket, copied into a shell-visible file, or placed into a generic agent key structure;
- biometric/passcode access control remains enforced by the existing Secure Enclave flow;
- a Secure Enclave identity created on another device MUST not be exposed as usable locally.

The bridge therefore provides passkey-like local SSH ergonomics while remaining normal SSH ECDSA P-256 on the wire.

## 14. Security model

### 14.1 Trust boundary

Any program running inside Shell's local interpreter that can reach `SSH_AUTH_SOCK` can ask the agent to sign arbitrary data with exposed `.none` keys.

That is intrinsic to the SSH agent model and MUST be documented.

The bridge reduces risk by:

- exposing only Shell's default identities, not every stored key;
- remaining inside the app container;
- not forwarding the socket remotely;
- preserving biometric/passcode requirements;
- rejecting key-store mutation;
- never exporting private material.

Users who require confirmation before credential use SHOULD configure sensitive identities as `.perUse` or `.perSession` rather than `.none`.

### 14.2 No host attribution

A basic local agent receives a blob to sign, not a trusted hostname supplied by Shell's profile layer.

V1 MUST NOT display misleading UI such as “Allow signing for example.com” unless the destination can be cryptographically bound and verified.

Host/destination constraints based on OpenSSH `session-bind@openssh.com` are future work and are not required for the local-only bridge.

### 14.3 Logging

Logs MUST NOT include:

- private key bytes;
- passphrases;
- full sign-request payloads;
- generated signatures.

Logs MAY include:

- lifecycle state;
- connection count;
- message type;
- key UUID or fingerprint for debugging at appropriate privacy level;
- success/failure category.

## 15. Lifecycle

### 15.1 App launch

The bridge MAY start lazily when the first interpreter-backed local shell is created.

It SHOULD NOT be initialized merely because the SSH settings screen is opened.

### 15.2 Background/suspension

No background execution entitlement is required.

When iOS suspends the process, the agent naturally stops servicing requests because the app process is suspended. This is acceptable; local shell commands are suspended at the same time.

### 15.3 Process termination

The agent does not survive app termination.

On next launch, Shell MUST remove any stale socket entry before binding the process path again.

### 15.4 Protected-data changes

If private key material is unavailable because protected data is locked, signing MUST fail closed through the existing key-loading error path.

The bridge MUST NOT weaken Keychain accessibility to keep the agent usable while the device is locked.

## 16. Failure behavior

| Condition | Required result |
| --- | --- |
| no default identities | empty identity list |
| requested blob unknown | `SSH_AGENT_FAILURE` |
| key deleted after enumeration | `SSH_AGENT_FAILURE` |
| iCloud key metadata exists but secret not yet present | do not advertise / sign fails closed |
| auth cancelled | `SSH_AGENT_FAILURE` |
| Secure Enclave key unavailable on this device | do not advertise / sign fails closed |
| unsupported request | `SSH_AGENT_FAILURE` |
| unsupported extension | `SSH_AGENT_EXTENSION_FAILURE` |
| malformed request | fail request or close client; never crash service |
| oversized frame | close client |
| socket startup failure | leave `SSH_AUTH_SOCK` unset; local shell otherwise remains usable |

Agent failure MUST NOT terminate the local terminal session.

## 17. Proposed file layout

Suggested new files:

```text
shell/Features/SSH/Agent/
    LocalSSHAgentService.swift
    LocalSSHAgentConnectionHandler.swift
    ShellSSHAgentDelegate.swift
    SSHAgentIdentityIndex.swift
    SSHPrivateKeySigner.swift
```

Likely modified files:

```text
shell/Features/LocalShell/LocalShellSession+IOSSystem.swift
shell/Core/SettingsSync/Registry/Settings+Connections.swift   # or current SSH settings registry owner
shell/UI/Settings/SettingsSSHSection.swift                    # toggle
shell/Features/SSH/Keys/SSHKeyManager.swift                  # only if shared signer/index helpers are extracted

docs/specs/shell.md
```

Suggested tests:

```text
tests/ShellTests/LocalSSHAgentProtocolTests.swift
tests/ShellTests/LocalSSHAgentIdentityTests.swift
tests/ShellTests/LocalSSHAgentSigningTests.swift
tests/ShellTests/LocalSSHAgentLifecycleTests.swift
```

Do not add implementation code under `vendor/`.

## 18. Test requirements

### 18.1 Protocol/framing

Tests MUST cover:

- one request in one read;
- header split across reads;
- payload split across reads;
- multiple requests concatenated into one read;
- unknown message type;
- add/remove/lock requests returning failure;
- extension request returning extension failure;
- oversized length rejected before large allocation.

### 18.2 Identity enumeration

Tests MUST verify:

- only `defaultKeyIDs` are advertised;
- ordering equals `defaultKeyIDs`;
- deleted/missing UUIDs are skipped;
- unusable remote Secure Enclave metadata is skipped;
- legacy keys needing unlock are skipped;
- valid certificate is listed before raw key;
- expired/not-yet-valid certificate is omitted;
- raw blob and certificate blob both map to the correct key UUID.

### 18.3 Signing

Each supported algorithm MUST have an end-to-end sign-and-verify test:

- Ed25519;
- ECDSA P-256;
- ECDSA P-384;
- ECDSA P-521;
- RSA SHA-256;
- RSA SHA-512;
- Secure Enclave P-256 on supported device/test infrastructure.

The resulting agent signature blob MUST be verified independently using the corresponding public key, not merely compared to implementation output.

### 18.4 Authentication

Tests MUST cover:

- `.none` succeeds without auth prompt path;
- `.perSession` records auth only after success;
- `.perSession` reuses the existing authenticated session;
- `.perUse` invokes fresh auth for sequential uses;
- concurrent requests for the same key share the current deduplicated auth load;
- cancellation returns failure and does not cache success.

Biometric UI itself may require dependency injection/test seams, but the state-machine behavior MUST be deterministic in unit tests.

### 18.5 Integration

On a real iOS/iPadOS device, acceptance testing MUST verify:

1. create/import a key in Shell;
2. mark it as a default identity;
3. open a local shell;
4. verify `SSH_AUTH_SOCK` is set;
5. run bundled `ssh` against a server whose `authorized_keys` contains the public key;
6. authenticate without a private key file in `~/.ssh`;
7. repeat with `.perSession` auth;
8. repeat with `.perUse` auth;
9. repeat with a Secure Enclave P-256 identity;
10. close/relaunch Shell and verify stale socket recovery;
11. disable Local SSH Agent and verify new shells do not receive `SSH_AUTH_SOCK`.

At least one `scp` or `sftp` test MUST also pass through the bridge.

## 19. Compatibility requirements

The bridge MUST be compatible with the bundled OpenSSH-derived `ssh_cmd.framework` clients that already appear in `ios_system`'s command dictionary:

- `ssh`;
- `scp`;
- `sftp`.

No `ssh-add` command is required for V1.

If `ssh-add` is bundled later:

- list operations SHOULD work through `requestIdentities`;
- mutation operations MUST continue to fail unless this specification is explicitly extended;
- Shell's UI/default-key model remains the source of truth for agent membership.

OpenSSH config remains authoritative at the client layer. For example, a user who configures `IdentityAgent none` may intentionally bypass `SSH_AUTH_SOCK`.

## 20. Performance requirements

- `requestIdentities` MUST NOT load private-key bytes solely to enumerate keys when cached public blobs are available.
- expensive encrypted-key parsing MUST remain off the main actor through the existing async loader.
- agent startup SHOULD complete before the first local prompt is displayed, but a startup failure MUST not block local-shell availability.
- idle agent overhead SHOULD be one listening socket plus the minimum event-loop resources practical with the existing NIO runtime.
- the bridge MUST NOT poll Keychain or CloudKit.

## 21. Implementation sequence

### Phase 1 — transport

- Add `LocalSSHAgentService` and Unix-domain listener.
- Add framed plain-byte connection handler.
- Reuse Citadel agent parser/serializer.
- Implement empty identity list and failure responses.
- Add framing/security tests.

### Phase 2 — identity enumeration

- Add `SSHAgentIdentityIndex` over `defaultKeyIDs`.
- Support raw public keys and valid attached certificates.
- Subscribe/invalidate on key/default changes as needed.
- Add identity tests.

### Phase 3 — signing

- Add/extract shared signing helper.
- Route key loading through async `SSHKeyManager.loadPrivateKey(id:)`.
- Implement Ed25519/ECDSA/RSA/Secure Enclave signing.
- Add algorithm verification tests.

### Phase 4 — local shell wiring

- Add device-local enable setting.
- Start agent before exporting local-shell environment.
- Set `SSH_AUTH_SOCK` only on successful bind.
- Preserve native macOS/Catalyst agent environment on `.nativePTY`.

### Phase 5 — documentation/device acceptance

- Update `docs/specs/shell.md` §4.6.
- Run real-device `ssh`/`scp`/`sftp` acceptance matrix.
- Verify app lifecycle and stale-socket cleanup.

## 22. Acceptance checklist

The feature is complete when all of the following are true:

- [ ] local interpreter sessions receive a valid `SSH_AUTH_SOCK` when enabled;
- [ ] `ssh` can enumerate Shell default identities through the socket;
- [ ] no private-key file is required for agent-backed auth;
- [ ] Ed25519 signing works;
- [ ] ECDSA P-256/P-384/P-521 signing works;
- [ ] RSA SHA-256/SHA-512 signing works;
- [ ] Secure Enclave P-256 signing works without private-key export;
- [ ] attached valid user certificates work through the agent;
- [ ] `.none`, `.perSession`, and `.perUse` retain current semantics;
- [ ] biometric/passcode cancellation fails the sign request cleanly;
- [ ] `ssh`, `scp`, and `sftp` interoperate with the bridge;
- [ ] unsupported agent mutation requests fail;
- [ ] remote agent forwarding remains unavailable;
- [ ] external SSH agents remain unsupported by the interpreter backend;
- [ ] native Mac PTY does not have its host `SSH_AUTH_SOCK` overwritten;
- [ ] stale sockets are cleaned up after process restart;
- [ ] disabling the feature removes the listener and future `SSH_AUTH_SOCK` export;
- [ ] no new private material is written to CloudKit, files, logs, or shell environment;
- [ ] `docs/specs/shell.md` accurately distinguishes the local bridge from prohibited forwarding/external-agent features.

## 23. Future extensions

Not part of V1, but compatible with this architecture:

- OpenSSH `session-bind@openssh.com` support and destination constraints;
- public-key selector files that let `IdentityFile` constrain a specific agent-backed Shell identity without private-key export;
- a read-only `shell-agent-list` helper for displaying available identities when `ssh-add` is not bundled;
- per-key “Expose to local agent” membership distinct from the default authentication list;
- diagnostics UI showing listener state and socket path.

None of these extensions should require changing the core rule: the local agent is a signing facade over Shell's existing identity manager, not a second private-key store.

## 24. Design decision summary

The core decisions are:

1. **Use the standard SSH agent protocol and `SSH_AUTH_SOCK`.** Existing OpenSSH-derived tools already understand it.
2. **Keep the agent local to the Shell process/container.** No remote forwarding or external exposure.
3. **Treat `defaultKeyIDs` as agent membership.** This is the closest existing analogue to keys loaded into `ssh-agent` and avoids advertising every stored credential.
4. **Reuse `SSHKeyManager.loadPrivateKey(id:)`.** Authentication, Keychain, iCloud-sync behavior, legacy migration, and Secure Enclave policy stay centralized.
5. **Make the agent read-only.** Shell UI remains the credential-management authority.
6. **Never export Secure Enclave private material.** The agent requests signatures only.
7. **Do not override the real macOS agent on native PTY builds.** The bridge solves the interpreter/iOS gap rather than replacing working host behavior.
