# Local SSH Agent Bridge v2 — Security Delta

**Status:** Proposed amendment to `ssh-agent-bridge-spec.md` (V1)  
**Repository:** `chr33s/shell`  
**Target:** iOS / iPadOS / visionOS / sandboxed Mac Catalyst interpreter backend  
**Scope:** Only changes from V1. All V1 requirements not explicitly replaced below remain unchanged.

Capitalized **MUST**, **MUST NOT**, **SHOULD**, and **MAY** are normative.

## 1. Summary of V2 changes

V2 changes the local SSH agent from an implicitly available convenience feature into an explicitly granted credential-use capability.

The changes are:

1. Local SSH Agent defaults to **Off**.
2. Agent membership is no longer derived from `SSHKeyManager.defaultKeyIDs`.
3. Each agent-visible identity requires an explicit, device-local **Allow in Local SSH Agent** grant.
4. Agent `.perSession` authorization is isolated from ordinary Shell SSH authorization.
5. Agent authorization is cleared on background/lock and when the agent is disabled.
6. Failed/cancelled authentication is rate-limited to prevent biometric/passcode prompt spam.
7. Concurrent agent clients and outstanding sign requests are bounded.
8. Remote agent forwarding remains explicitly separate and disabled.

No changes are made to V1's Unix-socket transport, protocol framing, read-only model, signing algorithms, Keychain storage, Secure Enclave behavior, certificate behavior, or prohibition on private-key export.

---

## 2. Replace V1 §5.3 — Agent management

Replace the V1 rule that derives loaded identities from `SSHKeyManager.defaultKeyIDs`.

The local agent MUST instead use a dedicated, device-local ordered membership list:

```swift
struct LocalSSHAgentPolicy: Codable, Sendable {
    var enabled: Bool
    var allowedKeyIDs: [UUID]
}
```

`allowedKeyIDs` is the sole source of truth for which Shell-managed identities may be exposed to local programs through `SSH_AUTH_SOCK`.

Requirements:

- `defaultKeyIDs` MUST NOT implicitly grant agent access.
- adding a key to Shell's normal default-authentication list MUST NOT add it to the agent;
- removing a key from Shell's normal default-authentication list MUST NOT remove an independent agent grant;
- importing or generating a key MUST NOT automatically grant agent access;
- a key synchronized from another device MUST NOT inherit that other device's agent permission;
- deleting a key SHOULD remove its UUID from `allowedKeyIDs` opportunistically, but stale UUIDs MUST be harmless if retained;
- identity enumeration MUST preserve `allowedKeyIDs` order after skipping unavailable identities.

If `allowedKeyIDs` is empty, the agent MUST return zero identities even when Shell has default SSH keys configured.

### 2.1 User-visible per-key grant

Each locally usable SSH identity MUST expose a device-local control conceptually named:

```text
Allow in Local SSH Agent
```

Semantics:

| Value | Behavior |
| --- | --- |
| Off | the identity is never advertised or accepted for local-agent signing |
| On | the identity may be advertised and used through the local agent, subject to its normal authentication policy |

The permission MUST be explicit. It MUST NOT be inferred from profile use, default-key status, recent use, certificate attachment, or storage level.

The permission MUST use device-local storage and MUST NOT be included in CloudKit identity metadata or iCloud-synced settings.

---

## 3. Replace V1 §6 — Settings defaults

The global setting remains:

```text
Connections > Local SSH Agent
```

but V2 changes its default and activation semantics.

### 3.1 Default

Recommended and required default for new installs:

```text
Local SSH Agent = Off
```

`allowedKeyIDs` MUST also begin empty.

The agent MUST therefore expose no ambient signing capability until the user has both:

1. enabled Local SSH Agent; and
2. explicitly allowed at least one identity.

### 3.2 Enabling

Turning the global setting On starts or makes available the local bridge, but MUST NOT automatically add any key to `allowedKeyIDs`.

If no keys are allowed, `SSH_AUTH_SOCK` MAY still be exported to interpreter-backed shells, but `requestIdentities` MUST return an empty list.

### 3.3 Disabling

Turning the global setting Off MUST:

- stop accepting new socket clients;
- close existing agent client connections;
- unlink the listening socket;
- stop exporting `SSH_AUTH_SOCK` to new interpreter sessions;
- clear all agent-scoped `.perSession` authorization state;
- clear pending authentication cooldown/rate-limit state.

It MUST NOT modify the keys themselves or their ordinary Shell SSH authentication state.

### 3.4 V1-state migration, if required

If a build containing V1 behavior has already persisted an enabled-agent setting, upgrading to V2 MUST NOT silently convert `defaultKeyIDs` into agent grants.

The safe migration is:

```text
enabled = false
allowedKeyIDs = []
```

The user must explicitly opt back in under the V2 permission model.

---

## 4. Replace V1 §7.1 — Base identity exposure

For each UUID in `LocalSSHAgentPolicy.allowedKeyIDs`, the bridge MUST:

1. resolve the UUID against current local `SSHKeyManager.savedKeys`;
2. verify the key is locally usable;
3. require or derive existing public-key metadata as V1 specifies;
4. exclude identities unavailable on the current device;
5. preserve the order of `allowedKeyIDs` in `SSH_AGENT_IDENTITIES_ANSWER`.

All V1 certificate ordering and certificate-validity rules remain unchanged, except that a certificate is only advertised when its underlying key UUID is present in `allowedKeyIDs`.

A sign request for a known Shell key that is **not** currently in `allowedKeyIDs` MUST return `SSH_AGENT_FAILURE`, even if the client supplies the exact public-key blob.

This check MUST occur at sign time as well as enumeration time so revoking a key's permission takes effect immediately for already-connected clients.

---

## 5. Replace V1 §12 — Authentication session semantics

V1's `.none`, `.perSession`, and `.perUse` meanings remain, but V2 changes the scope of `.perSession` authorization.

### 5.1 Agent-specific `.perSession` authorization

A successful biometric/passcode authentication for ordinary Shell SSH MUST NOT, by itself, authorize subsequent local-agent signing.

A successful authentication initiated by the local agent MUST NOT, by itself, authorize ordinary Shell SSH use.

`SSHKeyAuthManager` SHOULD therefore distinguish authentication purpose, conceptually:

```swift
enum SSHKeyAuthPurpose: Hashable, Sendable {
    case nativeSSH
    case localAgent
}
```

and track session state by `(keyID, purpose)` rather than `keyID` alone.

Equivalent implementations are acceptable, but V2 requires the observable security property: **native SSH and local-agent session authorization are not interchangeable ambient authority**.

Authentication prompt deduplication MAY still be shared when two truly concurrent requests refer to the same key and same purpose.

### 5.2 `.none`

`.none` remains promptless after the user has explicitly granted the identity to the agent.

The security contract is therefore:

```text
explicit device-local agent grant
        +
key.authRequirement == .none
        =
promptless local-agent signing
```

The UI SHOULD make this consequence clear when enabling agent access for a `.none` key.

### 5.3 `.perUse`

`.perUse` continues to require fresh authentication for every signing operation.

A successful `.perUse` signing operation MUST NOT establish reusable agent session authorization.

---

## 6. Add V2 lifecycle authorization invalidation

In addition to V1 lifecycle rules, the bridge MUST clear all **local-agent** `.perSession` authorization when any of the following occurs:

- the app transitions to background/inactive state;
- protected data becomes unavailable or the device locks;
- Local SSH Agent is disabled;
- the corresponding identity's agent permission is revoked;
- the identity is deleted;
- the process terminates naturally by losing all in-memory state.

Foregrounding the app MUST NOT restore agent authorization from persisted state. A protected `.perSession` key must authenticate again on its next agent use.

This invalidation MUST NOT silently downgrade the key to `.none` behavior.

The implementation MAY keep the same socket path across background/foreground transitions; only authorization state is required to reset.

---

## 7. Add V2 prompt-abuse and resource controls

The agent MUST prevent untrusted local code from creating unbounded authentication prompts or unbounded local resource use.

### 7.1 Cancel/failure cooldown

After a user-cancelled or failed biometric/passcode authentication for a key through the local agent, further authentication-triggering sign requests for that same key MUST fail without presenting another authentication prompt for a short cooldown period.

Recommended cooldown:

```text
5 seconds per key
```

The cooldown:

- applies only to the local-agent purpose;
- MUST NOT mark the key authenticated;
- SHOULD return `SSH_AGENT_FAILURE` immediately;
- MUST be cleared by a successful later authentication;
- MAY use monotonic process time and MUST NOT require persistence.

Malformed protocol traffic and unknown-key requests MUST NOT trigger authentication or affect the cooldown.

### 7.2 Concurrent-client bound

The listener MUST impose a finite upper bound on simultaneous local agent client connections.

Recommended V2 limit:

```text
8 concurrent clients
```

Connections beyond the limit SHOULD be refused or closed immediately.

### 7.3 Outstanding sign-request bound

The bridge MUST also bound in-flight signing work so local scripts cannot queue an unbounded number of Keychain/Secure Enclave operations.

Recommended limits:

```text
4 in-flight sign requests per client
16 in-flight sign requests globally
```

Requests exceeding a limit SHOULD receive `SSH_AGENT_FAILURE` or have their connection closed according to the simplest safe implementation.

The limits MUST NOT cause private material, request payloads, or signatures to be logged.

---

## 8. Strengthen V1 §14 — Security model

Replace the V1 statement that the bridge reduces risk by "exposing only Shell's default identities" with:

> The bridge exposes only identities that the user explicitly granted to the Local SSH Agent on this device.

V2's trust statement is:

> Any program running in Shell's local interpreter that can reach `SSH_AUTH_SOCK` may request arbitrary SSH signatures from agent-enabled identities. The private key remains protected from extraction, but the ability to request signatures is itself a credential-use capability.

The implementation and documentation MUST distinguish:

- **key confidentiality:** private material remains protected by Keychain/Secure Enclave;
- **key use authority:** local programs may request signatures only for explicitly agent-enabled keys;
- **user-presence policy:** `.none`, `.perSession`, and `.perUse` determine additional authentication after that grant.

A per-key agent grant is therefore a security permission, not merely an organizational preference.

---

## 9. Strengthen separation from remote agent forwarding

V1 already prohibits remote SSH agent forwarding. V2 makes the separation structural.

The local bridge implementation MUST NOT be wired into Citadel's:

```swift
SSHClient.enableAgentForwarding(...)
```

The local Unix-socket delegate/service MUST NOT be passed to an SSH connection as an `auth-agent@openssh.com` forwarding delegate.

Enabling Local SSH Agent MUST NOT:

- send `auth-agent-req@openssh.com`;
- accept remote agent channels;
- create a remote-accessible listener;
- change SSH profile configuration;
- add a `ForwardAgent` equivalent.

A future remote-forwarding feature would require a separate specification and separate user permission. Local-agent permission MUST NOT imply remote-forwarding permission.

---

## 10. Amend proposed settings/data ownership

V2 adds one new device-local policy owner, conceptually:

```text
shell/Features/SSH/Agent/LocalSSHAgentPolicy.swift
```

or an equivalent settings-layer type.

It owns:

```swift
enabled: Bool
allowedKeyIDs: [UUID]
```

Both fields MUST use device-only settings persistence.

`allowedKeyIDs` MUST NOT be added directly to synchronizable `SSHKey` metadata, because doing so would turn a local execution permission into a cross-device permission.

The per-key UI may read/write this policy without changing the `SSHKey` storage schema.

---

## 11. Amend V1 tests

All V1 tests remain required except where their expected membership source changes from `defaultKeyIDs` to `allowedKeyIDs`.

Add or replace the following tests.

### 11.1 Permission tests

Tests MUST verify:

- a default SSH key with no agent grant is not advertised;
- an agent-granted key that is not a normal default key is advertised;
- a newly imported/generated key is not agent-enabled automatically;
- revoking a grant immediately causes later sign requests on an existing socket to fail;
- a synced identity does not become agent-enabled merely because another device allowed it;
- certificate exposure follows the underlying key's agent grant;
- agent ordering follows `allowedKeyIDs`, not `defaultKeyIDs`.

### 11.2 Global setting tests

Tests MUST verify:

- new-install default is Off;
- the initial agent allowlist is empty;
- enabling the global setting does not populate the allowlist;
- disabling the agent closes clients and clears agent-scoped session authorization;
- any V1 migration does not derive grants from `defaultKeyIDs`.

### 11.3 Authentication-scope tests

Tests MUST verify:

- native SSH `.perSession` authentication does not authorize local-agent use;
- local-agent `.perSession` authentication does not authorize native SSH use;
- agent `.perSession` auth is cleared on background;
- agent `.perSession` auth is cleared when protected data becomes unavailable;
- revoking a key's agent permission clears its agent session authorization;
- `.perUse` never establishes a reusable agent session.

### 11.4 Prompt-abuse tests

Tests MUST verify:

- cancellation starts the per-key cooldown;
- repeated requests during cooldown return failure without a second auth prompt;
- cooldown for key A does not suppress key B;
- a successful later authentication clears/ends the failure state;
- client-count and in-flight-sign limits are enforced deterministically;
- exceeding resource limits does not crash or terminate the local terminal.

---

## 12. Amend V1 device acceptance

Replace the V1 flow "mark it as a default identity" with:

1. create/import a key in Shell;
2. verify the Local SSH Agent global setting is Off by default;
3. enable Local SSH Agent;
4. explicitly enable **Allow in Local SSH Agent** for the test key;
5. open a local interpreter shell;
6. verify `SSH_AUTH_SOCK` is live;
7. verify the agent exposes the allowed key but not an otherwise-default, non-allowed key;
8. authenticate with bundled `ssh` without a private-key file;
9. verify `.perSession` prompts again after background/foreground;
10. verify `.perUse` prompts for each signing operation;
11. verify a Secure Enclave P-256 key follows the same explicit-grant rules;
12. revoke the key's agent permission and verify an already-connected client can no longer sign with it;
13. disable Local SSH Agent and verify the listener is removed.

The V1 `scp`, `sftp`, stale-socket, algorithm, certificate, and Secure Enclave acceptance requirements remain unchanged.

---

## 13. Amend V1 implementation sequence

Insert the following work before V1 Phase 2 identity enumeration is considered complete:

### V2 Phase 1A — explicit permission model

- Add device-local `LocalSSHAgentPolicy`.
- Default global enablement to Off.
- Add ordered `allowedKeyIDs` storage.
- Add per-key **Allow in Local SSH Agent** UI.
- Ensure import/generation/default-key changes do not auto-grant permission.

### V2 Phase 2A — scoped authentication

- Add authentication-purpose scoping for `.perSession` state.
- Route local-agent key loads through the `.localAgent` purpose.
- Invalidate agent purpose state on background, lock, disable, revoke, and delete.

### V2 Phase 2B — abuse controls

- Add failed/cancelled-auth cooldown.
- Add concurrent-client limit.
- Add per-client and global in-flight signing limits.
- Add deterministic tests for each bound.

All subsequent V1 phases continue with `allowedKeyIDs` as the identity-membership source.

---

## 14. Replace affected V1 acceptance-checklist items

Replace:

```text
[ ] ssh can enumerate Shell default identities through the socket
```

with:

```text
[ ] ssh can enumerate only identities explicitly allowed in the Local SSH Agent
```

Replace:

```text
[ ] .none, .perSession, and .perUse retain current semantics
```

with:

```text
[ ] .none, .perSession, and .perUse retain their user-presence semantics while agent .perSession authorization remains isolated from native SSH authorization
```

Add:

```text
[ ] Local SSH Agent is Off by default
[ ] agent allowlist is empty by default
[ ] normal default SSH keys do not receive implicit agent permission
[ ] per-key agent grants are device-local and never synced
[ ] permission revocation takes effect for already-connected clients
[ ] background/device-lock clears agent .perSession authorization
[ ] cancelled/failed authentication cannot create rapid repeated biometric/passcode prompts
[ ] client and in-flight signing limits are enforced
[ ] enabling the local agent does not enable or request remote agent forwarding
```

---

## 15. Replace affected V1 design decisions

V1 design decision 3:

> Treat `defaultKeyIDs` as agent membership.

is replaced by:

> **Use an explicit device-local ordered `allowedKeyIDs` list as agent membership.** Normal SSH default-key selection and local-agent credential delegation are different security decisions and MUST remain independent.

Add:

> **Default to no delegated capability.** The global local-agent feature is Off and its allowlist empty until the user explicitly enables both.

Add:

> **Scope session authorization by use surface.** Authenticating a key for native SSH does not silently unlock it for arbitrary local-shell programs, and vice versa.

Add:

> **Bound abuse from untrusted local code.** Authentication cooldowns and finite connection/request limits prevent the agent from becoming an unlimited biometric-prompt or resource-exhaustion surface.

All other V1 design decisions remain unchanged.
