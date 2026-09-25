# Shell Agent Relay: Claude Code and Codex Control from iPhone and Apple Watch

**Status:** Proposed implementation specification; not implemented by this document.  
**Specification version:** 1.1-draft  
**Date:** 24 September 2026  
**Repository:** `chr33s/shell`  
**Inspected baseline:** `main` at `060236c8a89adff088c4aa2cedc4fb71f91ebc63`.[R1]  
**Suggested repository filename:** `spec.agent-relay.md`  
**Base protocols:** `shell-control/1` and `shell-watch-gateway/1`  
**Proposed extension:** `shell-agent/1`, with negotiated agent operation schemas and an optional Watch transport extension.  
**Distribution amendment:** Bundled, sandboxed macOS LaunchAgent for the proposed TestFlight/App Store profile; implementation and distribution validation remain release gates.

> tmux preserves and locates the workspace. A native agent integration identifies the pending interaction. Shell Control authenticates the reviewer, records the response, and returns it to that exact interaction.

Capitalized **MUST**, **MUST NOT**, **SHOULD**, and **MAY** describe requirements of this proposed specification. Numerical limits are product defaults, not provider or Apple guarantees. Existing behavior is identified explicitly; all new names, endpoints, commands, and files below are proposals unless stated otherwise.

## Contents

1. [Decision and scope](#1-decision-and-scope)
2. [Repository baseline](#2-repository-baseline)
3. [Architecture and boundaries](#3-architecture-and-boundaries)
4. [Integration profiles and provider compatibility](#4-integration-profiles-and-provider-compatibility)
5. [Identity, registration, and native request ownership](#5-identity-registration-and-native-request-ownership)
6. [Agent operation approval schemas](#6-agent-operation-approval-schemas)
7. [Typed questions and replies](#7-typed-questions-and-replies)
8. [Signed commands and decision processing](#8-signed-commands-and-decision-processing)
9. [Native delivery, receipts, and recovery](#9-native-delivery-receipts-and-recovery)
10. [Claude Code adapter](#10-claude-code-adapter)
11. [Codex adapter](#11-codex-adapter)
12. [Events, synchronization, and notifications](#12-events-synchronization-and-notifications)
13. [iPhone and Watch experience](#13-iphone-and-watch-experience)
14. [tmux integration](#14-tmux-integration)
15. [API, IPC, and compatibility](#15-api-ipc-and-compatibility)
16. [New messages and cancellation](#16-new-messages-and-cancellation)
17. [Security and privacy](#17-security-and-privacy)
18. [Limits and operational behavior](#18-limits-and-operational-behavior)
19. [Distribution, installation, and diagnostics](#19-distribution-installation-and-diagnostics)
20. [Repository implementation map](#20-repository-implementation-map)
21. [Delivery phases](#21-delivery-phases)
22. [Acceptance tests and release gates](#22-acceptance-tests-and-release-gates)
23. [Decisions deferred from v1](#23-decisions-deferred-from-v1)
24. [Other native request types](#24-other-native-request-types)
25. [References](#25-references)

## 1. Decision and scope

Add native Claude Code and Codex adapters to the optional Shell Control companion. Reuse the Mac-local authority, enrolled device identities, challenge/sign/submit pipeline, and iPhone-to-Watch gateway. Do not build an approval protocol on terminal bytes.

### 1.1 Required outcomes

The initial release MUST support explicit approve/reject decisions for a documented, supported native permission gate while the agent runs on the execution Mac, including inside tmux. It MUST show pending requests on iPhone and eligible requests on Watch, return a decision to the exact original gate, and distinguish a recorded response from agent acceptance and operation completion.

The next increment MUST support bounded, structured answers to explicit agent questions. Later, separately enabled managed-session capabilities MAY support new instructions, active-turn steering, and cancellation.

A terminal attachment is not required for delivery. An available execution host and a live native wait are required. The companion remains optional: disabling it MUST leave ordinary terminal, SSH, and tmux use intact.

### 1.2 Non-goals

V1 does not provide terminal streaming or SSH on Watch; arbitrary terminal input; automatic, bulk, or persistent approval; authorization from notification payloads; unattended replay of offline decisions; a public Mac control listener; guaranteed push delivery; or a universal security boundary around every agent action.

V1 is **Mac-execution-host only**. Agents on a separate Linux/SSH host require an adapter at that host and a separately specified authenticated origin connection. Attaching Shell to remote tmux MUST NOT make that machine appear integrated or authorized.

### 1.3 Distinct interaction types

| Interaction | Meaning | Required handling |
|---|---|---|
| Permission request | An operation is waiting for authorization. | Immutable approval plus explicit approve/reject. |
| Question | A native request is waiting for a constrained answer. | Immutable input request plus a signed typed response. |
| New instruction | The user wants to initiate or steer work. | Separate grant, fresh session context, and managed-session adapter. |
| Cancellation | Stop a specific active turn or controlled job. | Separate capability; cooperative outcome tracking. |
| Informational event | Report progress, completion, failure, or attention. | No executable authority. |

A question can still have consequential answers. Adapters MUST classify side-effect approvals presented as questions as permission review, not harmless text input. An unsupported approval-shaped question MUST remain unapprovable remotely.

### 1.4 Apple-distribution objective

Package Shell-owned Control host functionality with the Mac Catalyst app, not as a separate installer requirement. Select a sandboxed, app-bundled LaunchAgent registered through `SMAppService`; keep it independent of the foreground app after explicit user/system consent. Section 19 defines this proposed distribution profile and replaces the earlier suggested embedded-payload-to-`~/.local` installation model. Native agent/runtime and Tailscale prerequisites remain explicit. The service API is supported; this document does not certify the complete application for TestFlight or App Review.[M1][M2][M3]

## 2. Repository baseline

The inspected repository already defines a Mac-local broker exposed privately through Tailscale Serve, iPhone review and gateway functions, Watch-owned signing keys, and an optional push relay. The iPhone-gateway specification supersedes the independent-Watch topology in the older Watch specification.[R2][R3]

Relevant existing surfaces are:

| Existing location | Verified responsibility | Extension required |
|---|---|---|
| `adapters/` | Blocking-hook and command-wrapper integration rules; Git pre-push and wrapper examples.[R4] | Provider-specific adapters and compatibility fixtures. |
| `Protocol/ApprovalSpec.swift` | Immutable approvals, approve/reject, review requirements, and feature tokens.[R5] | Agent schema capabilities; no generic reply added to `ControlDecision`. |
| `Protocol/Operations.swift` | Recognizes `exec.v1`; preserves unknown schemas as unknown.[R6] | Reviewed agent operation variants. |
| `Protocol/HostIPC.swift` | Framed local JSON, run capabilities, approval wait/withdraw, and receipts.[R7] | Agent registration, input wait/withdraw, and receipt extensions. |
| `Protocol/Commands.swift` | Signed approval, notification acknowledgement, job cancellation, and handoff commands.[R8] | Separate typed agent commands with explicit compatibility handling. |
| `Client/DecisionCoordinator.swift` | Review, challenge, signature, submission, and outcome states.[R9] | Shared mechanics for new typed interactions. |
| `Client/ControlAPIClient.swift` | Runtime reads, signed command submission, origin publication, consume, and receipts.[R10] | Optional agent endpoints. |
| `Client/WatchGatewayClient.swift` | Immediate Watch-to-iPhone requests and device-local signing integration.[R11] | Negotiated question and session-control transport. |

Paths beginning `Protocol/` or `Client/` above are under `Packages/ShellControlCore/Sources/`.

Existing approval transport is not evidence that Claude/Codex adapters or question replies already exist. Source inspection is also not physical-device validation; the gateway specification records outstanding device-validation work.[R3]

## 3. Architecture and boundaries

```text
Execution Mac
┌─────────────────────────────────────────────────────────────────────┐
│ tmux pane                                                          │
│   Claude Code / Codex CLI                                          │
│       ↕ native synchronous hook                                    │
│   provider adapter                                                 │
│                                                                    │
│ Alternative: managed adapter ↔ agent SDK / app-server                │
│                    │                                               │
│                    ↕ authenticated per-user local IPC              │
│              shell-controld                                        │
│                    ↕ loopback                                      │
│          Mac-local Shell Control broker                            │
│          immutable requests • commands • consumes • receipts        │
└───────────────────────────────┬─────────────────────────────────────┘
                                ↕ HTTPS through Tailscale Serve
                           iPhone Control
                                ↕ immediate WatchConnectivity
                            Shell Watch

Attention-only path:
Mac broker → optional Push Relay → APNs → iPhone / system Watch mirroring
```

The terminal and control connections are independent. Closing a terminal view or detaching tmux MUST NOT cancel a pending request. Losing the native wait, restarting the agent, or changing its execution context MUST invalidate it unless durable continuation is proven.

The adapter owns provider parsing and native responses. `shell-controld` owns authenticated local registration, publication, waiting, and consume mediation. The broker owns the durable ledger and device authorization. iPhone and Watch own review and their respective signing keys.

Provider SDKs and RPC dependencies MUST stay outside Ghostty, terminal rendering, SSH identity, and tmux parsing. Shared mobile protocol code MUST remain provider-runtime independent. No provider API key or agent login session is copied to a mobile device.

### 3.1 Logical services versus operating-system processes

The diagram above names logical responsibilities. In the proposed bundled macOS profile, the daemon and broker libraries run inside one native `ShellControlHost` process supervised as a user LaunchAgent. The Catalyst app configures that host through an authenticated App Group-scoped XPC interface. Agent adapters stay separate and return responses through their native waits. Quitting the UI is not a service-stop command; explicit disable and system authorization are handled as specified in section 19.4.

## 4. Integration profiles and provider compatibility

### 4.1 Supported profiles

**Hook profile:** preserve the ordinary provider CLI. A synchronous hook blocks on one native permission request or supported question. Its safety claim is limited to responses successfully delivered through that hook. It MUST NOT be described as remote-only enforcement under every startup, timeout, configuration, or crash condition.

**Managed profile:** the adapter owns the provider process/client connection and its permission/input callbacks. It MUST refuse startup when required policy or protocol capabilities are unavailable. A mandatory-review deployment additionally requires evidence that every targeted action reaches its gate and that failure cannot bypass it. Owning an SDK callback alone is not that evidence.

**Informational profile:** unsupported providers, unsupported actions, or unverified builds may publish attention/status events. Such events MUST NOT expose an approve/reply control.

### 4.2 Verified documentation surface

As checked on the specification date:

- Claude documents `PermissionRequest` allow/deny JSON; that hook lacks `tool_use_id` and excludes sandbox network prompts. Its `PreToolUse` interface supports answering `AskUserQuestion` using preserved questions and `updatedInput.answers`. Permission-hook exit code 2 is not a denial; a command-hook timeout can leave no decision.[P1]
- Codex documents synchronous `PermissionRequest` allow/deny, hook configuration in `~/.codex/hooks.json`, and explicit trust review for changed non-managed hooks. Its permission response does not support `updatedInput`, `updatedPermissions`, or `interrupt`.[P2]
- Claude Agent SDK documents `canUseTool` for approvals and questions, but earlier auto-approval can bypass that callback.[P3]
- Codex app-server documents approval RPCs, user-input requests, turn control, and resolution/completion events. Its documentation labels app-server and WebSocket transport experimental; a managed adapter is therefore opt-in and release-gated, not the default production path.[P4]

### 4.3 Compatibility manifest

Every shipped adapter MUST have a checked-in manifest recording provider build/version, adapter build, integration profile, schema fingerprint where available, supported native events, response encodings, coverage exclusions, failure behavior, and evidence from contract tests.

No minimum provider version is asserted by this document. Release engineering MUST fill the supported-version matrix from tested binaries. A version string or self-reported capability is insufficient without the matching validated decoder and fixtures. Unknown builds default to informational mode unless explicitly covered by a tested compatibility range.

The manifest MUST distinguish `documented`, `contract_tested`, and `device_validated`. Setup MUST NOT display “Ready” from documentation-only evidence.

## 5. Identity, registration, and native request ownership

### 5.1 Identity model

Retain the existing Shell `origin_id`, `job_id`, `run_id`, `request_id`, and `command_id` meanings. Add these proposed bindings:

| Field | Definition |
|---|---|
| `agent_session_id` | Shell UUID for one registered provider session instance. |
| `adapter_instance_id` | UUID for this adapter process lifetime. |
| `native_wait_id` | Adapter-generated UUID for exactly one blocking callback/hook/RPC wait. |
| `connection_epoch` | Adapter-generated UUID identifying the native RPC connection lifetime. |
| `provider_session_id` | Provider session/thread identifier, when exposed. |
| `provider_turn_id` | Provider turn identifier, when exposed. |
| `provider_request_id` | Exact native request identifier, when exposed; preserve its native string/number type. |
| `provider_tool_use_id` | Optional tool-call identifier; never fabricated when absent. |

A reconnect creates a new `connection_epoch`. An agent restart creates a new `run_id` and session instance unless an adapter-specific recovery protocol proves continuity. Reusing a terminal pane or provider display name proves nothing.

### 5.2 Registration

The adapter MUST authenticate over the existing per-user IPC boundary and obtain a per-run capability. Register the provider/build/profile, available operations, owned process or connection identity, policy fingerprint where observable, and optional tmux location.

The run capability MUST remain host-local. It MUST NOT appear in tmux options, push payloads, URLs, mobile caches, command-line arguments, or ordinary logs. Prefer a protected inherited descriptor or authenticated local registration; never embed capabilities in hook configuration.

The host MUST distinguish its own daemon liveness from a live native wait. Presence for a request MUST derive from the adapter's still-open wait and current process/connection evidence. A healthy daemon MUST NOT renew a dead hook indefinitely.

### 5.3 Deduplication and concurrent waits

For native RPC, bind a wait to `(agent_session_id, connection_epoch, native request ID with type)`. For a hook lacking a stable native ID, generate `native_wait_id` once on invocation and reuse it only for that invocation's IPC retries.

Identical tool arguments do not identify identical operations. Two concurrent identical requests MUST remain separate. Retransmitting the same local message ID with different bytes is a conflict, not an update.

An adapter MUST retain an in-memory handle to the exact callback/pipe/RPC waiter. No lookup by “current pane,” most recent question, command text, or title is permitted for dispatch.

## 6. Agent operation approval schemas

### 6.1 Preserve `exec.v1`

`exec.v1` already requires an absolute executable path, argument vector, working directory, and context commitment.[R6] It MUST NOT be populated by splitting a provider command string or inventing the shell invocation the provider might use.

Add `agent.tool.v1` as a negotiated wrapper. Initial `kind` variants are `shell`, `file_change`, and `tool_call`; each requires a separate recognized feature token and renderer. Unknown variants MUST NOT become approvable merely because a full-size screen is available.

The initial shipping adapter MAY support only `shell`. Each additional variant is a separately tested capability, not implied by support for the wrapper.

### 6.2 Required committed content

An `agent.tool.v1` operation MUST contain:

- `provider`, tested `provider_build`, and `adapter_build`;
- `agent_session_id`, `native_wait_id`, and available native identifiers;
- `kind`, native tool name, and exact authorization-relevant parameters;
- absolute `cwd` when execution is directory-sensitive;
- explicit `permission_scope`, including native scope rather than a guessed scope;
- `native_request_sha256`, computed over the canonical native input retained locally;
- `context_sha256`, computed over the adapter's documented context material;
- the fields necessary for the kind-specific renderer to show the actual request.

Context material MUST bind the active native wait, provider identity/build, effective user where observable, the exact tool arguments, relevant effective policy, and any locally verifiable preconditions. For file changes, include expected file/base hashes when available. Unobservable fields MUST be identified as unavailable; do not fabricate an executable identity or complete environment snapshot.

A digest is a commitment, not proof of safe behavior. If the adapter cannot establish the meaning or scope of an authorization-relevant field, it MUST refuse remote approval and offer native review.

### 6.3 Variant review requirements

| Kind | Required review material | V1 device policy |
|---|---|---|
| `shell` | Exact command string or true argv, working directory, known shell semantics, reason, and permission scope. | Full review by default; Watch only through an explicitly tested narrow policy. |
| `file_change` | Exact target paths, change kind, complete relevant diff, and available base/precondition hashes. | iPhone full review; no Watch approval in v1. |
| `tool_call` | Stable tool/server identity, exact side-effecting arguments, schema identity, and scope. | Disabled until a specific renderer/adapter pair is approved. |

Network grants, directory-wide grants, permission-policy changes, and grouped requests are excluded from v1 remote approval. A future renderer MUST display their actual duration and scope. A single native decision may authorize more than one downstream operation; the UI MUST NOT label that “Approve once.”

For supported single-gate operations, “Approve once” means one decision for that native gate, not one guaranteed subprocess, network request, or filesystem side effect.

### 6.4 Illustrative operation shape

This is a structural example, not an executable test vector. Placeholder hashes and build labels MUST be replaced by generated values in fixtures.

```json
{
  "schema": "agent.tool.v1",
  "provider": "claude_code",
  "provider_build": "<tested-build>",
  "adapter_build": "<adapter-build>",
  "agent_session_id": "50000000-0000-4000-8000-000000000001",
  "native_wait_id": "60000000-0000-4000-8000-000000000001",
  "provider_session_id": "native-session-example",
  "kind": "shell",
  "tool_name": "Bash",
  "cwd": "/Users/example/src/shell",
  "shell_request": {
    "representation": "command_string",
    "command": "git status --short",
    "shell_identity": null
  },
  "permission_scope": "single_native_gate",
  "native_request_sha256": "<64-lowercase-hex>",
  "context_sha256": "<64-lowercase-hex>"
}
```

A missing shell identity here is an explicit limitation. The compatibility profile decides whether the native command semantics are still sufficiently specified for review; the example does not itself qualify for remote approval.

The enclosing approval retains its existing immutable spec and request hash. It MUST require `agent.tool.v1`, the kind token such as `agent.shell.v1`, and `consume.v1`. Relevant metadata MUST be inside the committed operation, not appended as unsigned decoration.

## 7. Typed questions and replies

### 7.1 New request type

Define `input.request` independently of `approval.request`. Do not add `reply` to the approve/reject enum.

An immutable `InputSpec` contains `v`, `type`, the four origin/job/run/request IDs, creation and expiry timestamps, summary, source binding, question array, allowed responses, minimum review, required features, and `effect`. Its source additionally commits the tested provider/adapter builds, `native_request_sha256`, `context_sha256`, and `answer_mapping_sha256`. The last digest covers the exact mapping from Shell question/choice IDs to native response fields and values; the host MUST recheck that mapping before dispatch.

`effect` is `answer_question` in v1. Inputs that actually grant tool or permission authority MUST use approval semantics. Unknown effect classifications are not remotely answerable.

Each question has a stable adapter-assigned `id`, exact `prompt`, `kind`, and `required` flag. Supported kinds are:

| Kind | Request fields | Answer fields |
|---|---|---|
| `single_choice` | Ordered choices with stable IDs, labels, and any explanatory descriptions. | One selected choice ID. |
| `multi_choice` | Choices plus minimum and maximum selections. | A unique set of selected choice IDs in canonical order. |
| `text` | Explicit maximum UTF-8 byte length; optional non-executable descriptive hint. | Exact UTF-8 text. |

Question IDs and choice IDs MUST be nonempty ASCII identifiers of at most 64 characters, unique within their respective scopes. A prompt is at most 2,048 UTF-8 bytes; a choice label at most 256 bytes and its description at most 1,024 bytes. All per-field limits remain subject to the smaller total-spec limit. No trimming, Unicode normalization, or case-folding may change committed content.

No arbitrary JSON Schema, regular-expression validator, file upload, URL-opening action, secret-entry workflow, or executable input template is supported in v1. Unknown required constraints disable remote reply.

### 7.2 Immutable example

This is a structural example. Build labels and digest placeholders are not valid release interoperability vectors and MUST be replaced with generated values in tests.

```json
{
  "v": 1,
  "type": "input.request",
  "request_id": "10000000-0000-4000-8000-000000000002",
  "origin_id": "20000000-0000-4000-8000-000000000001",
  "job_id": "30000000-0000-4000-8000-000000000001",
  "run_id": "40000000-0000-4000-8000-000000000001",
  "created_at": "2026-09-24T08:00:00Z",
  "expires_at": "2026-09-24T08:05:00Z",
  "summary": "Choose the test scope",
  "effect": "answer_question",
  "source": {
    "provider": "codex",
    "provider_build": "<tested-build>",
    "adapter_build": "<adapter-build>",
    "native_request_sha256": "<64-lowercase-hex>",
    "context_sha256": "<64-lowercase-hex>",
    "answer_mapping_sha256": "<64-lowercase-hex>",
    "agent_session_id": "50000000-0000-4000-8000-000000000001",
    "native_wait_id": "60000000-0000-4000-8000-000000000002",
    "connection_epoch": "70000000-0000-4000-8000-000000000001",
    "provider_session_id": "thread-example",
    "provider_turn_id": "turn-example",
    "provider_request_id": 23
  },
  "questions": [
    {
      "id": "test_scope",
      "prompt": "Which tests should run next?",
      "kind": "single_choice",
      "required": true,
      "choices": [
        {"id": "focused", "label": "Changed modules only"},
        {"id": "all", "label": "Entire test suite"}
      ]
    }
  ],
  "allowed_responses": ["answer", "decline"],
  "minimum_review": "watch",
  "required_features": ["agent.input.v1", "agent.input.consume.v1"]
}
```

The example IDs and timestamps are illustrative. Request hashing uses the complete canonical spec, including source, choice labels/descriptions, constraints, and expiry. A change to any of those requires withdrawal and a new request ID.

### 7.3 Answer semantics

The signed response MUST contain the actual answer, not merely its digest or an unsigned companion object. A text answer is data for the native input API; it MUST NOT pass through shell evaluation, terminal paste, or command concatenation.

Missing required answers, duplicate question IDs, unknown choice IDs, extra questions, invalid cardinality, invalid Unicode, and over-limit text MUST be rejected. For choice responses, the adapter maintains a committed mapping from Shell IDs to the provider's expected values. It MUST NOT match by a lossy or truncated display label.

A `decline` response is available only when the adapter has a tested native decline mapping. Otherwise publish only `answer`; expiry withdraws remote availability without inventing an empty answer or silently cancelling unrelated work.

Text entry MAY be drafted offline, but MUST NOT be signed, queued, or transmitted as an executable reply until the exact request is refreshed and confirmed online.

## 8. Signed commands and decision processing

### 8.1 Reuse, do not weaken, the control model

Existing approval decisions use the repository's signed envelope, exact request digest, observed state/policy versions, and review challenge.[R8][R9] Agent approvals MUST use that same flow. No push, pane identifier, network connection, or unsigned gateway assertion can replace it.

Introduce a separate agent command union for `input.respond`, later `agent.message`, and later `agent.turn.cancel`. Reuse validated envelope fields and signing primitives, but do not silently broaden an old decoder's accepted types.

An `input.respond` command MUST bind:

| Field | Required commitment |
|---|---|
| Envelope | `v`, `type`, `command_id`, `device_id`, exact enrolled `aud`, `issued_at`, `not_after`. |
| Request | `request_id` and recomputed `request_hash`. |
| Observed state | `expected_state_version` and `policy_version`. |
| Review | `challenge_id`, bound to this action, signer, request, and versions. |
| Response | `action: answer` with typed `answers`, or `action: decline` with no answers. |

The `answers` array contains objects such as `{"question_id":"test_scope","kind":"single_choice","choice_id":"focused"}`. Sort answer entries by question ID for a single deterministic representation. The array itself remains covered by the command signature.

Use the existing ES256/JCS signing scheme and audience convention. Watch commands MUST be signed on Watch and forwarded unchanged by iPhone. The broker MUST verify the signer, device enrollment, grants, and current Watch-to-iPhone binding independently.

### 8.2 Review sequence

1. Fetch the immutable request and current projection. Independently recompute its hash.
2. Verify request kind, supported features, review level, live source presence, and native deadline.
3. Show the complete required review content and obtain explicit confirmation of the exact decision or answer.
4. Refetch or atomically obtain a challenge that confirms the same hash and state/policy versions. A change requires renewed review, not automatic acceptance of new content.
5. Sign and durably record one command ID/JWS before the first network send.
6. Submit through the authorized live path. The broker atomically validates and records a winning response, its idempotency record, and its change event.
7. Display “Response recorded,” then follow dispatch/receipt evidence. Do not display operation success at this point.

A challenge MUST expire no later than the request/native deadline. Command lifetime MUST be no longer than the challenge. A claim permit MUST also respect the original signed deadline; consume MUST NOT extend authorization into a later interaction.

### 8.3 Concurrency and retry rules

The first valid response committed for a request wins. A simultaneous response from another device MUST receive the existing resolution or `request_resolved`; it MUST NOT overwrite the first response.

Authenticate before looking up an idempotency record. The same command ID and exact signed content returns the recorded outcome, including after expiry. The same ID with different content is a conflict. Durable idempotency does not permit submitting a new expired command.

After a transport timeout, query the command ID before creating any new mutation. A retry can use only the identical JWS during an explicit live reconciliation, within its deadline when it has not already been recorded. No background queue may retry authorizing commands later.

Retain unresolved command identifiers in a protected journal so an ambiguous submission can be queried after reconnect. Keeping an ambiguity journal is not permission to replay its commands.

## 9. Native delivery, receipts, and recovery

### 9.1 Dispatch sequence

For an approval, retain the existing consume mechanism. For question responses, add one-time `input.consume` semantics binding the request hash, winning command ID, exact response hash, run, and native wait.

The host MUST perform this sequence:

1. Confirm the signed result and current request resolution.
2. Verify that the original native wait is still open and belongs to the registered run/connection.
3. Recheck all locally observable committed context and native deadlines.
4. Atomically claim the response; validate the returned permit and its deadline.
5. Persist a dispatch record containing the immutable binding and digest of the exact native response bytes.
6. Persist `dispatch_started` **before** the first possible write to the provider.
7. Send through the original native callback, pipe, or RPC request, at most once for that dispatch record.
8. Record transport and native acceptance evidence separately, then publish the strongest justified receipt.

A structured rejected approval is mapped only to the corresponding native denial; it is not an execution permit. It still needs wait correlation and a dispatch journal. Adapter-generated denial on deadline/unavailability MUST be labeled a system outcome, not a user rejection.

### 9.2 Three independent state dimensions

| Dimension | States |
|---|---|
| Request resolution | Approval: `pending`, `approved`, `rejected`, `expired`, `withdrawn`. Input: `pending`, `answered`, `declined`, `expired`, `withdrawn`. |
| Response dispatch | `none`, `awaiting_origin`, `claimed`, `dispatch_started`, `native_response_written`, `accepted`, `not_applied`, `unknown`. |
| Agent operation | `not_observed`, `running`, `completed`, `failed`, `cancelled`, `unknown`. |

The table defines proposed agent projections; it MUST NOT be serialized into legacy enum fields without version negotiation.

`native_response_written` proves only that the adapter handed bytes to the local transport. `accepted` requires correlated native evidence that this response was accepted. A request-cleared event alone may represent cancellation or another client's response and is not sufficient proof.

For compatibility with existing receipts, `applied` MUST require the adapter's documented acceptance evidence; `not_applied` requires positive evidence of non-application. Otherwise report `unknown`. Add detailed evidence through `agent.delivery.v1`, not by changing old receipt field meanings.

A successful tool-completion event can prove acceptance only when its native correlation is unambiguous. Matching command text, elapsed time, or a later terminal screen is insufficient.

### 9.3 Crash handling

A record before `dispatch_started` may be resumed only if the exact original wait and unexpired authorization still exist. A record at or after `dispatch_started` MUST NOT be dispatched again without provider-level proof that no response was accepted and a protocol-safe retry mechanism.

After an unprovable partial write or process crash, mark the outcome unknown, disable further dispatch for that request, and reconcile from correlated native evidence. A new process MUST NOT attach old authority to a new callback that happens to have similar input.

The system promises durable response records and one-time claims. It does **not** promise exactly-once execution of external agent side effects.

### 9.4 Native and local-review races

Withdraw the mobile request when a native deadline expires, the turn ends, the original gate is cleared, or a different local client resolves it. Before dispatch, recheck that it remains the same pending native request.

A late response rejected by the provider becomes `not_applied` when that rejection is explicit. A lost connection without conclusive evidence becomes `unknown`. Do not relaunch the tool or start another turn to make an old response “work.”

## 10. Claude Code adapter

### 10.1 Permission hook

Implement proposed command `shell-control agent hook claude-code`. Dispatch only supported event names from stdin, using the pinned Claude decoder. Parse input without evaluating it. Register the live invocation before publishing any approval.

Install a synchronous, narrowly matched `PermissionRequest` handler. The following illustrates a **proposed** installation, not an existing CLI subcommand:

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "matcher": "^Bash$",
        "hooks": [
          {
            "type": "command",
            "command": "/Users/example/.local/bin/shell-control agent hook claude-code",
            "timeout": 360
          }
        ]
      }
    ]
  }
}
```

Merge only the owned stanza into the user's hook settings. Do not replace the entire settings file or remove other policy hooks. Generated configuration MUST use the actual verified executable path and tested timeout syntax.[P1]

For an unexpired, consumed, verified remote approval, emit the native `PermissionRequest` decision with `behavior: allow`. For rejection or an adapter-controlled deadline, emit `behavior: deny` and a bounded reason. Exit successfully when valid structured decision JSON was written. Never interpret an internal CLI exit code as authorization.[P1][R12]

Do not include permission updates, persistent rules, modified tool arguments, or mode changes. Those would alter what the reviewer approved. Preserve other provider policy checks; another policy hook may still deny.

### 10.2 Deadlines and coverage

Use an internal deadline earlier than the configured outer hook timeout. In the default setup, offer at most 300 seconds of review, stop waiting by 330 seconds from hook entry, and configure a tested outer timeout of 360 seconds. Subtract registration/publication overhead when calculating the remaining review window; do not add a fresh five-minute window after a slow setup. A shorter native deadline always wins.

On broker failure, malformed internal results, expiry, or unavailable native context, return a valid native denial while the hook is still alive. If the hook never starts or the provider kills it, the adapter cannot emit that denial. Setup and UI MUST retain the hook-profile limitation from section 4 rather than imply mandatory enforcement.

Unsupported native prompts, including excluded network gates, are informational/handoff only. The integration MUST NOT claim complete permission coverage.[P1]

### 10.3 Questions

Handle `AskUserQuestion` through a separately configured, tested `PreToolUse` integration, or through a managed SDK callback. Preserve the original input and map typed answers back to the provider's expected question representation. Duplicate question text that cannot be represented without ambiguity MUST disable this hook route.[P1][P3]

The adapter MUST NOT treat a bare allow decision as an answer. It MUST validate every answer against the committed question and build the native response from that immutable input plus the signed answer. Collecting a choice does not authorize editing tool arguments elsewhere.

Interactive and headless behavior MUST have separate contract fixtures; support for one execution mode MUST NOT be inferred from another. A cancelled callback invalidates the input request immediately.

## 11. Codex adapter

### 11.1 Permission hook

Implement proposed command `shell-control agent hook codex`. Install the same narrow synchronous event structure, but with the Codex command and configuration location. Setup MUST require the user to complete Codex hook trust review; it MUST NOT bypass that review.[P2]

Decode Codex input independently of Claude input. Share normalized Shell types, not assumptions about native field coverage. Return only the tested allow/deny permission shape; do not send Claude-only permission extensions.[P2]

Broader scope hidden behind a shell-shaped hook is not a supported single-gate operation. When the adapter cannot distinguish the scope, disable remote approval rather than guess.

### 11.2 Managed app-server mapping

Use a host-owned connection, preferably stdio for the initial experimental implementation. Perform protocol initialization, keep reading while waiting for a mobile response, and serialize writes. Generate/retain schemas from the exact tested binary where supported.[P4]

| Native surface | Proposed Shell mapping |
|---|---|
| `item/commandExecution/requestApproval` | Supported operation approval; approve → `accept`, reject → `decline`. |
| `item/fileChange/requestApproval` | Full-review file-change approval; join to the exact proposed item changes. |
| `item/tool/requestUserInput` | Typed input, unless its semantics are actually authorization. |
| `serverRequest/resolved` | Close the pending native request; determine the reason from correlated evidence. |
| `item/completed` | Correlated operation outcome. |
| `turn/start`, `turn/steer`, `turn/interrupt` | Optional new instruction, steering, and cancellation capabilities. |

These method names are documented provider interfaces; the normalization and policy in this table are Shell design requirements.[P4]

Native approval scope and offered decisions MUST be validated for each request. Never substitute `acceptForSession` for a one-time decision. Permissions tools, managed-network grants, and MCP elicitation require their own future schemas; do not flatten them into generic approval or text reply.

A reported input auto-resolution interval or other native expiry MUST shorten the Shell deadline. Shell MUST NOT generate a default answer when a mobile user is unavailable.

### 11.3 Terminal coexistence

The managed adapter MUST own the request-routing path. Merely opening a second app-server client does not prove it can observe or resolve another client's requests.

A native remote TUI is a possible separately tested configuration, not a prerequisite or a v1 guarantee. Supporting it requires an explicit ownership/routing contract, one authoritative waiter registry, and tests for local/mobile races. No raw app-server listener may be exposed to iPhone or Watch. The experimental status of this integration MUST remain visible.[P4]

## 12. Events, synchronization, and notifications

### 12.1 Normalized event vocabulary

Define proposed event types `agent.session.started`, `agent.session.ended`, `agent.status.changed`, `agent.approval.created`, `agent.input.created`, `agent.request.resolved`, `agent.delivery.updated`, `agent.turn.completed`, and `agent.turn.failed`.

Events carry a unique event ID, origin/session/run identity, optional request/native correlation, occurrence and observation times, and a bounded summary. Provider timestamps are metadata; they do not control authorization expiry. The broker assigns the authoritative ordered sequence.

Status events MUST NOT mutate an immutable request. A normal-looking completion message from terminal output MUST NOT resolve a pending native request. Informational terminal bells or OSC notifications may only produce clearly unverified attention hints.

### 12.2 Durable synchronization

Use the existing broker storage and transaction writer. Add an agent projection/change feed rather than another authority. Committing a request/response and its change event MUST be atomic.

A snapshot MUST identify a consistent sequence cut. Subsequent changes start after that cut. Cursors are opaque and principal-scoped; an expired cursor requires a new snapshot. Missing or coalesced push messages MUST be recoverable through snapshots and changes.

Preserve all request and response transitions. Coalesce repetitive non-authorizing progress updates. Do not push or persist token-by-token model output in v1. Optional final summaries MUST be bounded, visibly attributed to the agent, and incapable of enabling an action.

### 12.3 Push behavior

Remote alerts use the existing optional relay path. The relay has no decision authority, and no-relay installations require foreground checking when the application is suspended.[R2][R3]

A push MUST carry only an opaque origin/request/event reference and generic attention text. Do not include commands, diffs, answers, credentials, signed commands, consume permits, or an executable action payload. Push expiration MUST not outlive the attention item's relevance.

Register Review as a foreground notification action. Opening it MUST fetch current state. Dismissal, delivery, opening, and acknowledgement are not approval or rejection. Apple's notification-action routing differs between foreground and background actions; this spec therefore prohibits background approval/reply shortcuts.[A1]

## 13. iPhone and Watch experience

### 13.1 iPhone

Extend the existing Control area with a unified view of agent approvals, questions, and recent outcomes. Each item MUST show trusted host identity separately from agent-supplied labels, provider/session context, request kind, expiry, review requirement, and freshness.

The detail view MUST render the exact supported operation or question, not merely a friendly summary. Expandable content is acceptable; hidden or truncated authorization-relevant content must prevent confirmation. Large unsupported content goes to native review, not a misleading “full review” button.

For text replies, display the exact final text before confirmation. Provide Open terminal as navigation only. Show “Sending,” “Response recorded,” “Waiting for agent,” “Agent accepted,” “Not applied,” and “Outcome unknown” as distinct states. Report task completion separately.

### 13.2 Watch

The Watch remains a small review/signing client behind its paired iPhone. Its existing client uses immediate requests and a bounded round-trip timeout, not delayed executable delivery.[R11]

V1 Watch eligibility is deliberately narrow: supported low-complexity approvals; at most two short questions; at most four choices per question; or explicitly permitted short text input with a final confirmation screen. File changes and broad permissions require iPhone/native review.

Eligibility MUST require supported schemas, adequate review content, current policy, a fresh request, and live gateway reachability. An unavailable iPhone disables submission immediately. Old cached details may remain readable with stale labeling but cannot authorize.

Dictation produces a draft only. The user MUST review and confirm the resulting text before signing. There is no background dictation-to-agent forwarding.

### 13.3 Gateway rules

Use immediate `sendMessageData` request/reply semantics for executable interactions. `updateApplicationContext` or queued background transfers MAY carry replaceable cache hints, never decisions or replies. Apple provides distinct immediate and background transfer mechanisms; this spec does not assume uninterrupted runtime or eventual delivery by a deadline.[A2]

The phone forwards a Watch-signed command unchanged and MUST NOT re-sign it as the phone to bypass failure. A revoked gateway or changed Watch binding blocks the proxied request. A gateway timeout creates uncertainty to reconcile by command ID; it is not proof that the broker rejected the command.

## 14. tmux integration

### 14.1 Navigation only

tmux supplies persistent terminal sessions and a control-mode stream of terminal/tmux events, not provider-specific authorization semantics.[T1] Shell MUST NOT derive approval state from `capture-pane`, `pipe-pane`, prompt regexes, titles, OSC payloads, or terminal text.

The adapter MAY register this non-authorizing location:

```text
terminal_location:
  enrolled origin_id
  tmux server instance evidence
  session_id
  window_id
  pane_id
  observed_at
```

Navigation metadata belongs outside immutable authorization fields unless explicitly needed to describe context. It MUST NOT be included as a substitute for native wait identity. Do not expose the tmux socket path as a remote command endpoint.

### 14.2 Safe handoff

Open terminal MUST first resolve the enrolled host and an already configured connection, then verify that the tmux server/session/pane still match. If they do not, show “Original terminal unavailable” and allow manual navigation. Do not create a replacement session and label it restored.

The companion MUST NOT issue `send-keys`, `paste-buffer`, Ctrl-C, Enter, `y`, or text replies as part of approval, input, or cancellation. Ordinary user-driven terminal typing remains a separate existing terminal feature.

### 14.3 Lifecycle independence

Detaching tmux or losing the iPhone's SSH connection does not resolve a request. Pane disappearance alone is not proof that an agent stopped; the adapter's native process/connection evidence decides. Conversely, a pane that still exists does not prove its old agent or callback exists.

The implementation MUST work without tmux using the same adapter/control contracts. tmux adds session persistence and navigation, not authority.

## 15. API, IPC, and compatibility

### 15.1 Extension strategy

Keep `shell-control/1` behavior intact for existing clients. Add a discovery endpoint for `shell-agent/1`; absence of that endpoint means agent extensions are unsupported. Do not send new heterogeneous records into a legacy snapshot/change decoder.

Existing agent **approvals** MAY use the base approval endpoints after successful feature negotiation. They use the new operation schema and ordinary `approval.decide`. New **inputs, agent projections, detailed receipts, and optional session commands** use the extension endpoints below.

The same broker, authorization registry, transaction writer, command journal, and signing primitives serve both families. Separate wire contracts do not create a second authority.

### 15.2 Proposed endpoints

All runtime endpoints require the existing authenticated/pinned-origin path. “Origin” means the actual registered execution origin; mobile credentials cannot invoke origin-only mutations.

| Method and path | Principal | Contract |
|---|---|---|
| `GET /v1/agent/capabilities` | Enrolled device/origin | Extension version, features, limits, supported kinds, and enabled profiles. |
| `POST /v1/agent/sessions` | Origin | Idempotent session registration bound to a registered run. |
| `GET /v1/agent/sessions/{id}` | Authorized device/origin | Current session state, available actions, and non-authorizing location. |
| `GET /v1/agent/snapshot` | Authorized device | Stable-cut, paginated agent projection, including approval references and inputs. |
| `GET /v1/agent/changes` | Authorized device | Changes after a principal-scoped cursor. |
| `POST /v1/agent/inputs` | Origin | Publish one immutable input spec; conflicting reuse of an ID fails. |
| `GET /v1/agent/inputs/{id}` | Authorized device/origin | Full spec, recomputed digest, and current projection. |
| `POST /v1/agent/inputs/{id}/withdraw` | Origin | Withdraw the exact run/request/hash with an idempotent mutation ID. |
| `POST /v1/agent/inputs/{id}/consume` | Origin | Claim the winning response for the exact live wait once. |
| `POST /v1/agent/review-challenges` | Authorized reviewer | Fresh action/request/signer/version-bound challenge. |
| `POST /v1/agent/commands` | Authorized reviewer | Submit a JWS; `Idempotency-Key` equals its command ID. |
| `GET /v1/agent/commands/{id}` | Authorized reviewer/origin | Query the permitted command result without resubmitting. |
| `POST /v1/agent/receipts` | Origin | Idempotent, correlated delivery evidence and outcome. |

Snapshot parameters are `limit` and opaque `page`; change parameters are `cursor` and `limit`. Authorization filtering MUST be identical for snapshots, changes, direct fetches, and attachments. A user-supplied origin/device ID never determines authorization on its own.

The signed command is the only authoritative mutation payload. Reject duplicate unsigned copies of answer/decision fields. Unknown command types, required features, or authority-bearing members fail closed.

### 15.3 Consume contract

The input consume request contains `mutation_id`, `run_id`, `native_wait_id`, `request_hash`, `command_id`, and the canonical `response_hash`. The origin is derived from authentication.

An issued permit binds those values plus `permit_id`, issue time, and `apply_before`. It is valid only for its registered recipient run/wait. Repeating the same consume mutation returns the same claim; it does not mint a fresh deadline or second permission. A different consume for an already claimed request fails.

The adapter MUST validate the structured permit, compare all bindings, and enforce its deadline locally. The daemon MUST NOT return “approved” solely because a child CLI exited with status zero.

### 15.4 Local IPC

Preserve existing length-prefixed framing and the per-run capability boundary.[R7] Add negotiated message types `agent.register`, `agent.event`, `input.request`, `input.wait`, `input.withdraw`, and `agent.receipt`. Existing approval messages remain the approval path.

Every new IPC message carries the existing message ID/idempotency convention. The daemon MUST authenticate before reading or mutating another run's state. Large native input is normalized locally; it is not tunneled as unrestricted terminal data.

The adapter MUST read native input with a strict size limit and incremental framing appropriate to the provider. Native stdout is reserved for the provider's expected response format; logs go to a protected diagnostic channel or stderr. Validate the size of the fully serialized envelope, including JWS/base64 and nested JSON overhead, before sending. Per-object limits do not override a smaller transport-frame limit.

### 15.5 Watch transport extension

Add proposed `shell-watch-agent-gateway/1` only after capability negotiation with an upgraded iPhone. Reuse the same WCSession but route the extension by its explicit protocol discriminator to a separate strict decoder.

Its envelope contains `protocol`, `message_id`, `watch_device_id`, a fixed `type`, and a bounded `body`. Replies echo the message ID and separate gateway transport failure from an authoritative broker result.

The allowlist is limited to capability/session reads, agent snapshot/changes, input fetch, review challenge, signed-command submit, and command-result query. There is no generic URL fetch, RPC pass-through, shell command, or arbitrary HTTP proxy operation.

The phone MAY advertise extension availability as a cache hint. Live decisions still require current broker verification. An old phone returns unsupported; the Watch MUST NOT downgrade a reply to terminal keystrokes or a phone-signed command.

### 15.6 Migration

Do not redefine existing enum values or expand old signed fields silently. Add new schema fixtures, decoder branches, and capability gates together. Existing `exec.v1` approvals and ordinary Watch decisions MUST continue to work with no agent integration configured.

Old clients receive only records they can parse. Existing clients that preserve unknown operation schemas must remain unable to approve them; an optional generic notification may direct the user to an upgraded client. Cursor namespaces MUST prevent agent-stream cursors being accepted by legacy endpoints.

## 16. New messages and cancellation

These are post-v1 capabilities, disabled by default. Shipping approvals or question replies MUST NOT implicitly enable them.

### 16.1 New instruction and steering

A proposed `agent.message` command requires `agent.messages.send`, an opted-in managed session, explicit text confirmation, and a fresh session challenge. It binds the agent session/run, exact text, expected session version, and either `mode: new_turn` or `mode: steer` with the expected active turn ID.

To bind the exact message before signing, the review-challenge request MUST include its proposed action digest. The challenge and signed command MUST agree on that digest. The same rule applies to other commands targeting mutable session state rather than an immutable request.

The adapter MUST reject `new_turn` when the expected idle state is no longer current, and reject `steer` when the expected active turn changed. It MUST NOT silently queue a new turn or reinterpret steering as a new instruction later.

Messages contain plain text only in the first implementation. No caller-controlled model, working-directory, sandbox, permission, tool, system-prompt, or executable overrides may accompany them. Subsequent tool operations remain subject to their own provider permission policy.

A permission-hook adapter cannot implement this capability by itself. For an unmanaged CLI, the mobile UI provides terminal handoff instead.

### 16.2 Cancellation

A proposed `agent.turn.cancel` requires `agent.turns.cancel`, exact session/run/turn binding, a fresh challenge, and a supported native cancellation method. Cancellation acknowledgement is not proof of process termination or rollback.

Retain existing `job.cancel` only where its current controlled-job semantics actually match the adapter-owned job. Do not reinterpret it as killing a PID discovered from tmux. A cancelled turn may leave already completed side effects intact.

## 17. Security and privacy

### 17.1 Authority and grants

The execution host and its broker remain trusted; same-user/root compromise is outside the local isolation boundary inherited from the repository.[R3] This system does not prove a command safe and is not end-to-end encryption against the broker.

Retain existing approval grants. Add separately revocable `agent.sessions.read`, `agent.inputs.read`, and `agent.inputs.respond`; reserve `agent.messages.send` and `agent.turns.cancel` for later opt-in profiles. Scope grants to allowed origins and, where configured, allowed sessions/operation kinds.

The broker MUST verify object authorization, action grants, device status, request freshness, policy version, challenge binding, signature, and native presence for every relevant operation. Watch-originated calls additionally require the live enrolled gateway binding. Tailnet reachability is not enough.

### 17.2 Untrusted content

Treat tool arguments, summaries, question text, filenames, URLs, and provider messages as untrusted data. Render control characters and bidirectional controls visibly; do not interpret terminal escapes or HTML. Keep the trusted origin identity visually separate from agent-provided text.

A prompt containing “the user already approved” has no protocol effect. No native hook input may change broker routes, enrolled keys, grants, supported schemas, or review policy.

Unsupported or oversized content fails safely with native-review guidance. Hidden fields or redaction cannot make an otherwise inadequate authorization review adequate. If reviewing the exact operation would disclose a secret, require an appropriate native review flow rather than presenting only a hash.

### 17.3 Storage and transport

Keep raw provider payloads and native waiter handles host-local. Send only the supported immutable review material and bounded events needed by the client. Protect host records with per-user access controls and device caches with platform-protected storage. Do not claim that signatures encrypt the payload.

Default caches and diagnostic exports MUST exclude terminal transcripts, provider credentials, capabilities, and secrets. Signed reply commands contain answer text; retention policy MUST account for that text rather than claim it was deleted while keeping its JWS.

Retain command/idempotency evidence for at least the base protocol's retention floor. Deleting sensitive audit data requires an explicit retention operation over the actual records; never redact a signed payload in place and pretend its signature still authenticates it.

## 18. Limits and operational behavior

Defaults below are proposed for the extension. Negotiated lower limits and native deadlines always take precedence.

| Limit | Default |
|---|---|
| Permission/question review lifetime | 300 seconds. Never beyond native expiry. |
| Maximum configurable request lifetime | 1,800 seconds only where the native integration supports it. |
| Review challenge | At most 60 seconds and never beyond request expiry. |
| Consume permit | At most 10 seconds, bounded by signed/native deadlines. |
| Hook internal hard deadline / outer timeout | 330 / 360 seconds for the tested default configuration. |
| Native-wait heartbeat / stale threshold | 15 / 45 seconds; stale source cannot authorize dispatch. |
| Watch interactive round trip | Preserve the existing 20-second bound.[R11] |
| Foreground refresh | No faster than every 5 seconds without a separately justified event-driven path. |
| Native input size | 256 KiB host-side parsing cap; larger input requires another adapter path. |
| Agent operation review material | 32 KiB inline; larger operations require a separately specified full-review attachment flow. |
| Input spec / combined answer payload | 16 KiB / 4 KiB before envelope overhead. |
| Extension JSON frame | At most 64 KiB including its envelope; respect any lower gateway limit. |
| Questions / choices | At most 16 questions and 16 choices per question, within total size limits. |
| Watch question policy | At most 2 questions, 4 choices per question, and 512 UTF-8 bytes of text input. |
| Concurrent pending requests per run / origin | 16 / 128. Exceeding the limit never auto-approves. |
| Change history / command evidence | Preserve base floors of 7 / 30 days.[R5] |

Use monotonic elapsed time for local wait budgets and broker-controlled timestamps for protocol expiry. A wall-clock jump MUST NOT silently lengthen a previously established local authorization deadline.

On unavailable network paths, keep the native wait only until its deadline and retry idempotent reads with bounded backoff. Do not keep mobile background polling alive to simulate guaranteed availability.

Define machine-readable failures including `unsupported_provider_version`, `unsupported_operation`, `unsupported_input_schema`, `hook_not_trusted`, `native_wait_gone`, `native_context_changed`, `request_expired`, `request_resolved`, `review_required`, `gateway_unavailable`, `idempotency_conflict`, `response_invalid`, `limit_exceeded`, and `outcome_unknown`. UI messages MUST distinguish unsupported integration, connectivity failure, recorded denial, and uncertain dispatch.

Operational metrics SHOULD measure publication failures, pending age, expired requests, duplicate submissions, native acceptance latency, unknown outcomes, and gateway failures without storing prompt/answer text. Performance objectives MUST exclude human review time and sleep/network outages.

## 19. Distribution, installation, and diagnostics

### 19.1 Distribution decision and evidence boundary

The preferred Apple-distribution profile MUST package the Control host inside the Mac Catalyst application and register it as a **sandboxed, per-user LaunchAgent using `SMAppService.agent(plistName:)`**. Its executable MUST have a native macOS app-like wrapper with its own bundle identity, entitlements, and provisioning profile. The helper is a separate process, not a task owned by the foreground Shell application.

`SMAppService` is available to Mac Catalyst 16.0+ and macOS 13.0+. No AppKit registration bridge is required at Shell's existing deployment floor. Apple DTS specifically describes sandboxed SMAppService LaunchAgents, app-like wrappers, provisioning, and App Group-scoped XPC communication.[M1][M2]

This settles the selected service mechanism; it does **not** establish that the current host binaries, external-agent integrations, or full Shell archive already pass sandbox enforcement, TestFlight processing, or review. The actual distributed-build gates in section 22 are mandatory.

The earlier embedded-payload-to-`~/.local` proposal is **not** the TestFlight profile. That profile MUST NOT install executable copies into `~/.local/bin`, `~/.local/lib`, or `/Library/PrivilegedHelperTools`; write conventional external LaunchAgent plists; invoke an installer; or use an unsandboxed helper to evade the app's distribution restrictions. Apple requires sandboxed, self-contained Mac App Store applications, user consent for background execution, and applies its review guidelines to TestFlight submissions.[M3]

The existing standalone signed native distribution MAY remain available as an explicitly separate Developer ID/CLI profile.[R12] It MUST NOT be silently installed as a fallback or presented as a dependency of the self-contained TestFlight Control host. Disabling Control MUST leave the terminal application usable.

This profile packages **Shell-owned host code**, not Tailscale, Claude, Codex, their authentication, or every optional provider runtime. Those remain separately disclosed prerequisites. Packaging the service alone MUST NOT be advertised as proof that every feature of the complete app suite is distributable.

### 19.2 Targets and code reuse

Add a native macOS target, proposed name **`ShellControlHost`**, with a background-only app-like bundle, and embed it only in the Mac Catalyst archive. The host SHOULD run the existing daemon and broker responsibilities in one supervised process, retaining the broker's loopback HTTPS-fronted interface and the existing protocol/security boundaries. This is a packaging and lifecycle consolidation, not a merger of adapter and device authorization.

The repository already publishes `ShellControlDaemon` and `ShellControlHostSupport` as libraries in `cmd/Package.swift`, and `ShellControlBroker` as a library in `services/shell-control/Package.swift`.[R13][R14] Reuse these libraries through a small host entry point, refactoring construction, shutdown, storage, and access controls as needed. Do not spawn the old installer or three separately managed command-line services inside the new host. `ShellControlManagement` MUST be split so this profile cannot call legacy installation or service-management operations accidentally.

The UI remains Mac Catalyst. A native helper target does not require rewriting the main application as an AppKit application. The wrapper has no terminal window or ordinary Dock interface. Every macOS executable/library and registration plist MUST be excluded from iOS, iPadOS, visionOS, and watchOS archives by target/build configuration, not by assuming store thinning repairs an incorrect archive.

### 19.3 Proposed bundle and LaunchAgent declaration

The following layout is proposed. The app-like wrapper and bundle-relative executable approach follow Apple's service-management guidance and launch-constraint example; exact archive layout and signatures MUST pass the distribution spike.[M2][M4]

```text
Shell.app/
  Contents/
    MacOS/Shell
    Library/
      LaunchAgents/
        dev.chr33s.shell.control-host.plist
        ShellControlHost.app/
          Contents/
            Info.plist
            embedded.provisionprofile
            MacOS/ShellControlHost
```

The proposed launchd declaration is:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.chr33s.shell.control-host</string>
  <key>BundleProgram</key>
  <string>Contents/Library/LaunchAgents/ShellControlHost.app/Contents/MacOS/ShellControlHost</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>MachServices</key>
  <dict>
    <key>group.dev.chr33s.shell.control.host</key>
    <true/>
  </dict>
</dict>
</plist>
```

`KeepAlive` is a product choice for a continuously available local broker while the user has enabled Control, not a platform promise of uninterrupted execution. The host MUST remain event-driven when idle, use bounded backoff, and avoid startup/crash loops. A later socket-activation design MAY replace continuous residency after equivalent external-request wake behavior is demonstrated. A private XPC connection alone is not evidence that an incoming Tailscale HTTP request can launch a stopped broker.[M5][M6]

The host MUST maintain single-writer ownership of its ledger, perform recovery before advertising readiness, and reject duplicate instances. launchd registration MUST be the only supervisor in this profile; do not also register the same host through `loginItem(identifier:)` or spawn it as a foreground child.

### 19.4 Registration, consent, and lifecycle

Register only after an explicit user action explaining that Control can run after Shell quits and start again at login. The registration call may originate directly in Catalyst:

```swift
#if targetEnvironment(macCatalyst)
import ServiceManagement

// Invoke only after explicit consent in the Control setup flow.
func registerControlHost() throws -> SMAppService.Status {
    let service = SMAppService.agent(
        plistName: "dev.chr33s.shell.control-host.plist"
    )
    try service.register()
    return service.status
}
#endif
```

This is an API illustration, not a complete lifecycle controller. Production code MUST record user intent, handle errors and `.requiresApproval`, `.notRegistered`, `.notFound`, and unknown states, and provide a route to `SMAppService.openSystemSettingsLoginItems()` when appropriate. Reconcile on foreground activation and when returning from System Settings. `.enabled` indicates registration and eligibility to run; it is not a successful host health check.[M1][M7][M8]

Apple documents an additional macOS 26+ prompt when app-started background tasks remain after the app quits. The implementation MUST honor Allow/Don't Allow and user changes in System Settings; it MUST NOT suppress the prompt or require device-management enrollment.[M9]

| User/system event | Required product behavior |
|---|---|
| Close the UI or quit Shell, with background permission granted | Host remains independently supervised. A live native agent wait may still be answered. |
| Disable Control in Shell | Persist stopped intent, stop accepting new work, invalidate or conservatively resolve pending delivery, unregister the service, and confirm stopped state. Preserve identity and journals. |
| Disable the background item in System Settings | Report disabled/unavailable; do not silently re-register or restart it. |
| Crash the host | launchd may restart it according to policy. Recover the ledger; never replay an ambiguous native response. |
| Log out | Per-user availability ends. Never promise operation before the next applicable login. |
| Sleep, network loss, or unavailable Keychain material | Report unavailable/stale. Expiry and native-wait validation still apply on recovery. |
| Log in with Control still enabled and authorized | Resume the registered background host, without opening the Shell UI unnecessarily. |

Per-user LaunchAgents belong to a logged-in user; logout terminates them. These are not root daemons or pre-login system services.[M5] A process continuing after GUI quit does not keep an independently terminated agent or PTY alive. Session continuity remains the responsibility of the actual execution host and tmux/provider process.

Stopping MUST NOT mean merely killing a `KeepAlive` process and allowing it to restart. If unregistration fails, display that failure rather than claiming the service stopped. Stopping also cannot retract a native operation already dispatched.

### 19.5 Signing, sandbox, and storage

The main Catalyst app and native helper MUST be signed for the same developer team with appropriate distribution provisioning. Each has its own bundle identifier. Both MUST claim a provisioned shared App Group, proposed identifier `group.dev.chr33s.shell.control`. Use Apple's modern `group.` identifier style; Apple DTS documents support for Catalyst and, since the February 2025 developer-site changes, other native macOS product types.[M10]

The helper MUST have its own sandbox configuration. Do not set `com.apple.security.inherit` to treat a launchd-launched service as an ordinary child process. Start with the following capability allocation; the exact effective entitlements MUST be inspected in the downloaded TestFlight build:

| Component | Required or conditional capability |
|---|---|
| Catalyst UI | App Sandbox, the shared App Group, and its existing justified client/UI capabilities. |
| Native Control host | App Sandbox and the shared App Group. |
| Host loopback HTTP ingress | `com.apple.security.network.server`; bind loopback only. |
| Host outbound client traffic | `com.apple.security.network.client` only for actual configured network-client functions. |
| Keychain access | A narrowly provisioned access group only where necessary; do not automatically share the origin private key with every component. |

The current app entitlement file contains App Sandbox and network-client access but not these new App Group/server grants. This is a source-file observation, not a claim about effective archive entitlements.[R15] Apple's networking entitlement permits listening; it does not authenticate local callers or make a public listener acceptable.[M11]

Store the authoritative ledger and host secrets in the helper's protected container/Keychain. Use the App Group container only for deliberately shared, bounded configuration or diagnostics. Resolve containers through platform APIs, not hard-coded home paths. The foreground app MUST use the host's IPC for authoritative mutations rather than opening its database as a second writer. Origin identity MUST survive compatible app updates and MUST NOT be regenerated merely because registration, a route, or a bundle path changes.

### 19.6 Two local IPC boundaries

**Owned UI to host:** use a bounded XPC interface with a launchd-published Mach service whose name is inside the provisioned App Group namespace. Both executables claim the group. Authenticate peers using supported code-identity/audit information and reject unsupported messages. An App Group does not replace authorization. Do not request a broad temporary global Mach exception for communication that should be covered by the shared group.[M2]

**External agent adapter to host:** preserve authenticated, scoped, framed request/response semantics, but do not assume Claude, Codex, tmux, or a shell script can use the app's private database or App Group. Select and validate an external ingress/bootstrap mechanism in the distribution spike: a private Unix socket with demonstrated access or a separately authenticated loopback endpoint are candidates, not prevalidated guarantees. Never reuse an enrolled reviewer credential as an adapter capability.

A local endpoint MUST reject unauthenticated requests, enforce size/rate limits, bind capabilities to the exact run/wait, and offer no arbitrary command-execution API. If HTTP is selected, browser-origin requests and ambient authentication MUST NOT establish adapter authority. Capability enrollment and any user-approved export require an explicit workflow; no public endpoint or predictable secret is acceptable.

The external integration still owns native waiter identity and operation-context revalidation. The sandboxed host MUST NOT gain unrestricted filesystem access, launch an unsandboxed process, request Accessibility, or scrape the terminal to substitute for a missing integration. Any bundled adapter executable requires its own signing/sandbox design; main-host success does not prove a helper invoked by an external provider can read that provider's working tree.

If a provider profile depends on filesystem or execution access unavailable in the TestFlight sandbox, that profile MUST remain disabled in that distribution until an explicit, reviewable solution is validated. A separate Developer ID profile may be offered transparently; it is not an automatic escape path.

### 19.7 Tailscale and provider setup

Retain the private Mac-local broker and iPhone-gateway topology. Tailscale remains a separately installed/configured prerequisite. The sandboxed app MUST NOT assume it can execute a global `tailscale` CLI, edit another application's settings, configure arbitrary services, or install Tailscale itself.

The first release MUST either validate a supported sandbox-compatible configuration path or use an explicit prerequisite workflow in which the user configures Tailscale Serve outside Shell. Shell then verifies the resulting route and origin identity through permitted interfaces. It MUST not claim that successful `SMAppService` registration also established the tailnet route.[R3]

Provider hook configuration likewise requires permitted user-authorized file access or an explicit external setup step. Preserve unrelated hooks, show the exact owned change, write atomically where permitted, and retain a recoverable backup. Never disable provider trust/policy checks to make setup succeed.

The following remain proposed CLI commands for the applicable standalone or validated adapter profile, not an instruction to install a CLI into `~/.local` from TestFlight:

```text
shell-control agent install claude-code|codex [--dry-run]
shell-control agent uninstall claude-code|codex
shell-control agent doctor [--json]
shell-control agent hook claude-code|codex
shell-control agent test claude-code|codex --reviewer iphone|watch
shell-control agent launch claude-code|codex -- <provider arguments>
```

`launch` MUST NOT silently convert ordinary CLI operation to a managed SDK/RPC session. Downloaded runtimes or provider executables MUST NOT be used to bypass App Store restrictions; managed profiles require separate sandbox and distribution evidence. No mandatory Node/Python runtime is introduced into ordinary terminal use or basic Control host operation.

### 19.8 Updates, migration, and removal

The TestFlight/App Store application update is the host-code update mechanism. Do not self-update embedded executables or continue indefinitely from copied code after the containing app changes or is removed. Use bundle-relative registration, version the host protocol/schema, and validate the archive-to-installed-app update path, including any new consent requirement.[M3][M4]

Before replacing a running host, quiesce new publications, preserve journals, and identify active native waits. A process/adapter reconnection does not prove those waits survived. Any request lacking continuity evidence is withdrawn or marked uncertain, never automatically re-authorized.

Detect a legacy standalone installation before enabling the bundled host. Do not run both against the same port, origin, or ledger. Migrate through an explicit, authenticated export/import or user-authorized file workflow; preserve origin keys only when continuity is verified. Stop legacy supervision using its own supported management path. If required access is unavailable, explain the migration step instead of escalating privileges.

Provide a visible **Disable Control** action and document that deleting an app is distinct from deleting its stored enrollment data. Never silently erase identity, receipts, or audit evidence on normal disable/update. Validate OS behavior on removal and do not claim an app receives an uninstall callback.

TestFlight builds are time-limited to 90 days.[M12] Test expiration, invalid entitlement/profile, and update-required states without bypassing distribution enforcement or treating a beta as a permanent unattended host installation.

### 19.9 Readiness and diagnostics

Report these independently: bundled host build/signature identity, service registration, system authorization, host health, storage/key availability, adapter capability/compatibility, Tailscale route, enrolled reviewers, and optional push mode. A useful state model is `not_enabled`, `approval_required`, `registered_starting`, `ready_local`, `route_unavailable`, `disabled_by_user`, `incompatible_build`, and `degraded`. These labels are proposed UI states, not aliases for `SMAppService.Status`.

“Ready for approvals” requires an end-to-end safe adapter fixture plus native-contract evidence. “Watch ready” additionally requires the actual phone/gateway path. A broker ping or `.enabled` status is insufficient.

The safe fixture MUST exercise publication, review, signature, claim, native-response encoding, and receipt without executing a tool. A separate controlled real-provider test MUST run against the TestFlight-installed Mac build with the Shell UI closed and no debugger attached. Distinguish documentation, local debug, processed archive, real-provider, and physical-device evidence.

Diagnostics MAY reference `sfltool dumpbtm` and relevant system logs for human-operated troubleshooting.[M9] Production setup MUST NOT reset global background-task state, alter other applications' jobs, or instruct users to weaken platform security.

## 20. Repository implementation map

Existing directories below are from the inspected repository; filenames prefixed **New** are suggested locations, not observed source files.[R2][R4]

| Area | Required change |
|---|---|
| `adapters/` | **New** `claude-code/`, `codex/`, provider manifests, raw-input fixtures, expected-response fixtures, lifecycle tests. |
| `Packages/ShellControlCore/Sources/Protocol/` | Add recognized agent operations, input specs, agent commands/challenges/permits/receipts, limits, and strict validators. Preserve legacy decoding. |
| `Packages/ShellControlCore/Sources/Client/` | Add typed input coordination, agent API client/reconciler, and negotiated Watch gateway extension. Reuse signing and ambiguity journals. |
| `cmd/` | Reuse daemon/host-support libraries; separate portable runtime from legacy installer/lifecycle operations. Add validated hook dispatch, diagnostics, adapter registration, and IPC extensions. |
| `services/shell-control/` | Reuse the broker library in the native host; add extension routes, durable projections, input state machine, claims, grants, and transactionally consistent changes. |
| `shell/Features/Control/` | Add agent inbox/renderers and, on Catalyst, explicit background consent, SMAppService lifecycle/status, authenticated XPC, and migration/diagnostics UI. |
| `ShellWatch/` | Add eligible input review, answer confirmation, unsupported/full-review handoff, and new gateway capability negotiation. |
| `ShellWatchTests/` | Add gateway failure, stale-review, dictation-confirmation, and signature-attribution tests. |
| `protocol/` | Publish schema definitions, exact canonicalization/hash/signature fixtures, negative fixtures, and migration examples. |
| `services/push-relay/` | Reuse hint-only delivery. No provider payload parser, approval API, or durable agent ledger. |
| **New** `ShellControlHost/` | Native macOS app-like helper target, entry point, service composition, private storage, XPC/adapter ingress, and lifecycle tests. |
| `shell.xcodeproj` / configuration | Embed the signed native helper and LaunchAgent plist in Catalyst only; configure separate provisioning and supported architectures. |
| **New** host entitlements / shared App Group | Explicitly provision both bundle identities; keep host server access and private keys narrowly scoped. |
| Build/release tests | Archive validation, actual TestFlight install/update, consent, quit/relogin, legacy migration, and sandbox denial tests. |
| Documentation | Add this spec; amend the companion boundary, distribution profiles, supported integrations, setup, and release checklist. |

No agent code belongs in Ghostty or tmux protocol parsing. Reusing a shared coordinator MUST NOT collapse approval and input command types into a permissive generic dictionary.

## 21. Delivery phases

### Phase 0A — Sandboxed distribution spike

Build the smallest Catalyst app with the proposed provisioned native LaunchAgent. Validate registration, background consent, XPC, loopback ingress, private storage, quit/relogin, and stop. Upload and install through TestFlight before claiming the packaging path works for Shell. Then run one real external-hook request through the sandboxed host with the main app closed. Validate the Tailscale prerequisite path separately.

**Exit condition:** the narrow prototype passes A37–A40 and A45–A48 for the selected sandboxed interfaces. The remaining A37–A52 scenarios stay mandatory before release; this spike does not replace later integration and full-suite testing. Unsupported filesystem/runtime integrations remain disabled. Passing a local development build alone does not complete this phase.

### Phase 0B — Contracts and honest capability reporting

Finalize provider manifests, schemas, native wait identity, scope exclusions, and canonical fixtures. Implement feature negotiation and unsupported-mode UI. Validate the unchanged terminal build and existing approval flow.

**Exit condition:** unsupported builds/actions cannot produce a mobile authorization; old clients continue to function.

### Phase 1 — Hook-based operation approvals

Implement narrow Claude and Codex permission hooks, host registration, reviewed agent operations, deadlines, withdrawal, dispatch journaling, and conservative receipts. Enable iPhone first; enable Watch only for explicitly tested eligible operations. Reuse optional push hints.

**Exit condition:** supported approvals and rejections complete through real native hooks, with failure cases passing and no PTY input path.

### Phase 2 — Typed question replies

Add the input protocol, broker projection, signed responses, one-time delivery, and mobile renderers. Enable the tested Claude question route. Enable Codex questions only through a validated managed integration; do not imply permission hooks can answer every Codex question.

**Exit condition:** answers are bound to the exact question and original waiter; duplicate, stale, malformed, and cross-session replies cannot be applied.

### Phase 3 — Experimental managed conversation control

Add opt-in managed sessions, new-message and steering grants, and cancellation. Validate provider experimental dependencies, request ownership, and terminal coexistence separately.

**Exit condition:** a new instruction or cancel command cannot target a different or later turn, and failures never fall back to terminal input.

## 22. Acceptance tests and release gates

Tests MUST include deterministic native fixtures, broker/client tests, actual supported provider builds, simulator tests, and physical iPhone/Watch cases. A fixture test is not evidence that a provider hook was installed or trusted.

| ID | Scenario | Required result |
|---|---|---|
| A01 | Supported Claude permission, iPhone approve. | Exact waiter receives the native allow response after valid claim; no broader permission change. |
| A02 | Supported Codex permission, Watch reject. | Native denial; signature attributable to Watch, not substituted by iPhone. |
| A03 | Short eligible Watch approval. | Entire required content reviewed; current challenge and native wait validated. |
| A04 | Unsupported provider build or action kind. | No approve/reply control; explicit capability failure or native handoff. |
| A05 | Untrusted or edited Codex hook. | Not reported ready; setup does not bypass trust review. |
| A06 | Provider operation auto-approved before the integration gate. | No claim that Shell reviewed it; coverage limitation visible. |
| A07 | Broad/grouped/network permission disguised as shell input. | Refuse v1 remote approval, not “Approve once.” |
| A08 | Two identical concurrent native requests. | Different wait/request identities; each response reaches only its own waiter. |
| A09 | Two devices decide simultaneously. | Exactly one durable winning response; the other receives current resolution. |
| A10 | Same command ID retried after response loss. | Recorded result returned; no second native dispatch. |
| A11 | Same command ID with changed answer/body. | Idempotency conflict. |
| A12 | Hook internal deadline or broker unavailable. | Structured denial before outer timeout where the hook remains alive; no false user-rejection attribution. |
| A13 | Hook cannot start, is killed, or reaches provider timeout. | Actual provider behavior recorded; no false mandatory-enforcement claim. |
| A14 | Agent exits but daemon and tmux pane remain. | Native wait becomes invalid; stale request cannot be dispatched. |
| A15 | RPC reconnect reuses a numeric request ID. | Old connection epoch prevents cross-connection replay. |
| A16 | Local terminal/native client resolves first. | Mobile request closes; late response cannot revive it. |
| A17 | Crash before and after `dispatch_started`. | Safe pre-dispatch recovery only; ambiguous dispatch is not repeated. |
| A18 | Response written but native acceptance unproven. | Receipt remains unknown/unconfirmed, not falsely applied. |
| A19 | Native tool later fails. | Response acceptance and operation failure remain distinct. |
| A20 | Question, choices, policy, or expiry changes during review. | New request or conflict; original signature cannot authorize the changed question. |
| A21 | Extra/missing/duplicate answers, invalid choice, invalid Unicode, oversized text. | Validation failure before claim or dispatch. |
| A22 | Approval-shaped question or secret/URL elicitation. | Proper approval schema or unsupported; never downgraded to harmless input. |
| A23 | Native input auto-resolution or turn completion. | Deadline shortened/request withdrawn; no default mobile answer generated. |
| A24 | iPhone unreachable, VPN down, Mac asleep, or Watch disconnected. | Submission disabled/fails explicitly; no queued future authorization. |
| A25 | Gateway times out after broker records the command. | Command-ID reconciliation finds the result without new authorization. |
| A26 | Watch or gateway iPhone revoked during review. | Broker rejects subsequent mutation/claim according to current revocation state. |
| A27 | Push delayed, dropped, duplicated, or opened after expiry. | Foreground refresh restores authoritative state; push itself authorizes nothing. |
| A28 | Notification dismissal, acknowledgement, or first-action gesture. | No implicit approve/reject/reply; review opens as configured. |
| A29 | Dictation draft differs from expected text. | Final text confirmation required before signing. |
| A30 | Detach/reconnect terminal or rename/reuse a pane. | Control continues independently; handoff verifies identity; no injected keys. |
| A31 | No tmux present. | Same native adapter/control flow works. |
| A32 | Old broker, phone, or Watch encounters new capability. | Safe unsupported behavior; legacy inbox/approval decoding does not break. |
| A33 | Snapshot pages race with new events or cursor expires. | No missed request/resolution; consistent cut and resnapshot behavior. |
| A34 | Tampered signature, hash, audience, source binding, or response digest. | Rejected with no native dispatch. |
| A35 | New-message/steering target turn changes. | No late delivery to another turn or silent mode conversion. |
| A36 | Cancellation races with tool completion. | Accurate request/turn outcome; no rollback or termination claim without evidence. |
| A37 | Catalyst archive includes native host. | Correct SDKs, signatures, provisioning, and App Group authorization; no host binaries in mobile/Watch archives. |
| A38 | Install actual processed TestFlight build on a clean Mac. | Self-contained Control host setup; no separate host DMG, root operation, external executable copy, or debug-only entitlement. |
| A39 | User enables Control and grants/denies background permission. | State accurately follows intent and system consent; denial does not trigger silent re-registration. |
| A40 | Quit Catalyst UI during a real external provider wait. | Independently supervised host delivers only the valid signed response; no dependency on UI child lifetime. |
| A41 | Disable Control with KeepAlive configured. | Service stops persistently; no restart loop, concealed failure, or erased origin identity. |
| A42 | Disable in System Settings, then reopen app. | Disabled status respected; explicit user action required to re-enable. |
| A43 | Host crash, logout/login, sleep/wake, and locked Keychain. | Honest availability; single-writer recovery; no old wait replay or pre-login guarantee. |
| A44 | TestFlight update while waits are pending. | Version/schema compatibility checked; identity retained; uncertain native deliveries never resent. |
| A45 | UI/helper XPC from wrong group or unauthorized peer. | Reject; no broad global Mach exception or unsigned administrative bypass. |
| A46 | External hook accesses host without a valid scoped capability. | Reject; group/private files are not an authentication shortcut; limits and replay defenses hold. |
| A47 | Real adapter needs unsupported filesystem/process access. | Capability is disabled, not worked around through an unsandboxed helper or terminal injection. |
| A48 | Tailscale missing, disabled, or Serve misconfigured. | Distinct prerequisite/route failure; no arbitrary CLI execution or claim that registration configured networking. |
| A49 | Legacy CLI host already owns port/origin/ledger. | No dual writer or second authority; explicit, verified migration or actionable conflict. |
| A50 | Host idle with Control enabled. | Bounded memory/CPU, no busy polling, no avoidable crash/restart loop; incoming request path remains functional. |
| A51 | App removed, beta expired, profile invalid, or build incompatible. | No copied-code fallback or bypass; documented unavailable/update state and conservative request outcomes. |
| A52 | Release validation of full app suite. | Terminal/SSH/tmux and each mobile/Watch target tested independently; Control-host success is not treated as full-suite review approval. |

Release gates additionally require zero PTY-based authorization paths, provider/version evidence recorded in manifests, broker-restart and corruption recovery tests, unchanged non-companion terminal behavior, and device tests with normal OS suspension behavior rather than only debugger-attached execution.

This specification does not claim those tests have been executed. File-generation checks validate the document, not the proposed runtime implementation.

## 23. Decisions deferred from v1

Remote Linux execution origins, full diffs via authenticated content-addressed attachments, broad/network permission scopes, arbitrary MCP elicitation, independent Watch networking, full transcript synchronization, and mandatory organization-wide enforcement require separate specifications or explicit amendments.

The selected Apple service mechanism is not deferred: section 19 chooses `SMAppService.agent(plistName:)` with a sandboxed native app-like wrapper. External adapter access, sandbox-compatible Tailscale setup, and actual distribution remain explicit implementation/release gates rather than assumed capabilities.

The managed Codex integration remains experimental until its pinned provider interface and product support status justify a different release designation. No precise provider minimum version or universal native-receipt guarantee is invented here.

Section 24 classifies the native request types v1 leaves unsupported and states what supporting each would require.

The implementation MUST choose safety-preserving unavailability when a provider does not expose a reliable request/response interface. It MUST NOT recover missing capabilities by scraping a prompt or synthesizing terminal input.

## 24. Other native request types

**Status:** Proposed; not implemented. Nothing in this section changes the rule that an unsupported request is never answered remotely.  
**Evidence baseline:** Claude Code 2.1.281 hook inputs captured headless (`adapters/claude-code/fixtures/captured-2.1.281/`); `codex-cli 0.156.1` `app-server generate-json-schema` output, a live app-server capture, and a hook-route capture (`adapters/codex/fixtures/captured-0.156.1/`); provider documentation checked on 24 September 2026.  
**Relates to:** sections 6, 7, 11.2, and 23. Every new name below is a proposal.

### 24.1 Scope

The shipped adapters answer:

- Claude Code `PermissionRequest` for `Bash` (and, opt-in, `Edit`/`Write`), and
  `PreToolUse` for `AskUserQuestion`;
- Codex `PermissionRequest` for `Bash` (hook profile), and, in the experimental managed
  profile, `item/commandExecution/requestApproval`, `item/fileChange/requestApproval`,
  and `item/tool/requestUserInput`.

Every other native request stays in the terminal (hook profile) or is refused with a
JSON-RPC error (managed profile, so the turn does not wait on a request no one sees).
This section classifies those other requests and states what supporting each would
require. It does not change the rule that an unsupported request is never answered
remotely.

### 24.2 Classification

| Group | Requests | Disposition |
|---|---|---|
| A. One-time tool approvals | Claude `MultiEdit`, `NotebookEdit`, `WebFetch`, `WebSearch`, MCP tools; Codex legacy `execCommandApproval`, `applyPatchApproval` | Supportable within `agent.tool.v1` with new kinds and renderers (section 24.3). |
| B. Durable or widened grants | Claude `permission_suggestions` / `updatedPermissions`; Codex `item/permissions/requestApproval`, `acceptForSession`, exec-policy and network-policy amendments, `grantRoot` | Requires a new authority model and an amendment to this specification (section 24.4). |
| C. Structured elicitation | Codex `mcpServer/elicitation/request`; Claude `Elicitation` / `ElicitationResult` hooks | Supportable as an extension of `input.request` for a bounded schema subset (section 24.5). |
| D. Client-defined tools | Codex `item/tool/call` | Not applicable unless Shell defines tools (section 24.6). |
| E. Credentials and attestation | Codex `account/chatgptAuthTokens/refresh`, `attestation/generate` | MUST NOT reach a device (section 24.7). |
| F. Prompts without a hook | Claude sandbox network prompts | Not supportable without a provider change (section 24.8). |

### 24.3 Group A: one-time tool approvals

These are single native gates whose decision authorizes one operation. They fit the
existing approval pipeline: immutable spec, request hash, review challenge, signed
decision, one-time consume, dispatch journal, and conservative receipts. Each new kind
MUST have its own feature token and renderer; support for `agent.tool.v1` never implies
support for a kind (section 6.1).

#### 24.3.1 Claude `MultiEdit` and `NotebookEdit`

- Map to the existing `file_change` kind (`agent.file_change.v1`).
- `MultiEdit`: apply every edit in order to the current file contents; refuse remote
  approval if any `old_string` is missing or ambiguous, exactly as the provider would
  fail. Commit one complete diff and the base SHA-256.
- `NotebookEdit`: commit the notebook's base hash and a cell-level change description
  (cell ID, edit mode, old and new source). A renderer MUST show the exact cell source;
  a raw JSON diff of the notebook file is not adequate review. Until a cell renderer
  exists, `NotebookEdit` stays local.
- Watch: never eligible (section 6.3).

#### 24.3.2 Claude `WebFetch` and `WebSearch`

- New kind `network_fetch` (token `agent.network_fetch.v1`) with fields: tool name,
  exact URL or query, the prompt the provider will apply to the result, and whether the
  provider follows redirects where observable.
- The renderer MUST show the full URL with its host visibly separated, escaped per
  section 17.2. Punycode or confusable hosts MUST be displayed in their ASCII form.
- A domain-scoped suggestion in `permission_suggestions` is a Group B grant and MUST NOT
  be applied by a Group A approval.

#### 24.3.3 MCP tool calls (`mcp__<server>__<tool>`)

Section 6.3 reserves `tool_call` and disables it until a specific renderer and adapter
pair is approved. Enabling it requires:

- **Stable server identity.** The hook input names the server only. The adapter MUST
  derive an identity from the configured server (for stdio servers, the resolved command
  and arguments; for remote servers, the URL) and commit its digest. A server whose
  configuration changes is a different identity.
- **Schema identity.** The tool's input schema is not in the hook input. The adapter
  MUST obtain it from the same configuration or a cached tool listing and commit its
  digest; without it the call stays local.
- **Exact arguments.** Every argument is rendered in full. Arguments beyond the inline
  limit (32 KiB) or not representable as bounded scalars, strings, or small arrays stay
  local.
- **Per-server enablement.** A user MUST enable remote approval per server (and MAY
  restrict it per tool). There is no generic "approve any MCP tool" setting.
- Watch: not eligible in the first release.

#### 24.3.4 Codex legacy `execCommandApproval` and `applyPatchApproval`

These v1 methods carry the same information as the v2 requests the managed adapter
already maps (`command`/`cwd`/`reason`; `fileChanges`/`grantRoot`). Mapping them is
mechanical, but they SHOULD be supported only if a v2 client is shown to receive them;
the 0.156.1 capture did not.

#### 24.3.5 Requirements common to Group A

- A manifest route per request type, gated by evidence (section 4.3). Claude hook
  routes need interactive and headless captures before they count at run time.
- Positive and negative fixtures: exact native input, expected native response, and at
  least one refusal case per scope-widening field.
- A local recheck before dispatch of every committed precondition (file bases, server
  identity, schema digest, policy fingerprint).

### 24.4 Group B: durable or widened grants

#### 24.4.1 Why they are excluded today

Each of these authorizes operations the reviewer has not seen:

| Provider | Request or decision | Effect |
|---|---|---|
| Claude | `permission_suggestions` echoed in `updatedPermissions` (observed: `addDirectories`, `setMode: acceptEdits`, destination `session`) | Adds a rule or changes the mode for the rest of the session or persistently. |
| Codex | `item/permissions/requestApproval` | Grants file-system or network permission profiles with `scope: turn | session`. |
| Codex | `acceptForSession` | Approves this command and similar future prompts. |
| Codex | `acceptWithExecpolicyAmendment`, `applyNetworkPolicyAmendment` | Writes a persistent execution or network policy rule. |
| Codex | `grantRoot` on a file change | Allows writes under a directory for the session. |

Section 6.3 excludes these from remote approval. Supporting them is a change to the
security model, not a new renderer, and MUST be made as an explicit amendment to this
specification.

#### 24.4.2 Required design if adopted

- **New schema** `agent.permission.v1`, never folded into `agent.tool.v1`. It commits:
  the exact native rule or profile, its scope (`turn`, `session`, `persistent`), its
  destination (for Claude: user, project, local, session settings), the effective policy
  before and after, and an expiry where the provider supports one.
- **Review language.** The renderer MUST state the duration and breadth in plain terms
  ("Allow writes under /path for this session"). It MUST NOT use "Approve once". iPhone
  full review only; no Watch approval.
- **Separate grant.** A new revocable device grant (e.g. `agent.permissions.grant`),
  off by default, and a per-session or per-provider policy that can forbid persistent
  scope entirely.
- **Durable record.** The broker records each granted rule with its scope and the
  session it applies to, shows active grants on the phone, and marks them ended when the
  session ends. Where the provider offers no native revocation (Claude hooks), the UI
  MUST say that revoking in Shell does not remove a rule already written to provider
  settings.
- **Exactness.** The adapter sends only the rule that was shown, byte for byte; it never
  broadens, merges, or reorders suggestions. After dispatch it recomputes the policy
  fingerprint and reports the observed change as delivery evidence.
- **Offered decisions.** For Codex, only a decision present in `availableDecisions` may
  be sent (the 0.156.1 capture shows that list can omit `decline`).

### 24.5 Group C: structured elicitation

#### 24.5.1 Native surfaces

- **Codex** `mcpServer/elicitation/request` (0.156.1 schema): `serverName`, `threadId`,
  optional `turnId`, and either a form mode (`message`, `requestedSchema`) or a URL mode
  (`message`, `elicitationId`, `url`). The response is `{action: accept | decline |
  cancel, content?}`.
- **Claude** `Elicitation` and `ElicitationResult` hook events, matched by MCP server
  name. The documentation does not describe their decision output; a contract capture is
  required before any design is fixed.

#### 24.5.2 Required protocol extension

Section 7.1 forbids arbitrary JSON Schema, URL-opening actions, and secret entry in
v1. Supporting elicitation therefore requires:

- **New question kinds** in `input.request`, each with explicit bounds and its own
  feature token (e.g. `agent.input.form.v1`): `boolean`; `integer` and `number` with
  required minimum and maximum; `enum` (single choice over committed values);
  `multi_enum` with cardinality. Strings reuse `text` with a byte limit.
- **Schema translation** in the adapter from the elicitation's `requestedSchema` to those
  kinds. Any keyword outside the supported subset (patterns, formats, nested objects,
  `oneOf`, defaults that change meaning) keeps the elicitation local. The translation and
  the reverse mapping are committed through `answer_mapping_sha256`.
- **Tested decline.** `accept`, `decline`, and `cancel` are distinct native actions; the
  adapter MAY offer `decline` only when that mapping is covered by a captured fixture.
- **URL mode** is never answered remotely. The phone MAY show the host and message as a
  handoff to the Mac.
- **Secrets.** A field marked sensitive, or a Codex question with `isSecret: true`, stays
  local.
- **Effect classification.** An elicitation whose answer grants authority (for example,
  approving a payment or an OAuth consent) is Group B, not an input.

### 24.6 Group D: client-defined tools (`item/tool/call`)

Codex sends `item/tool/call` only for tools the client registered with the app-server.
Shell registers none, so refusing the call is correct. Supporting it would mean defining
Shell tools deliberately, each with its own specification; it is not a gap in the relay.

### 24.7 Group E: credentials and attestation

- `account/chatgptAuthTokens/refresh` asks the client for ChatGPT access tokens when the
  client manages authentication.
- `attestation/generate` is sent only to a client that opted in with
  `requestAttestation`.

Section 3 forbids copying provider credentials or login sessions to a mobile device.
The managed adapter MUST NOT opt into client-managed ChatGPT authentication or
attestation, so that Codex handles both itself, and MUST refuse either request if it
arrives. Neither is ever published, rendered, or forwarded.

### 24.8 Group F: prompts without a hook

Claude Code sandbox network prompts do not reach `PermissionRequest` (section 4.2).
There is no supported interception point, so they stay in the terminal. Shell MUST NOT
approximate them by scraping or keystroke injection (section 14.2). Support depends
on a provider hook.

### 24.9 Cross-cutting requirements

For every route adopted from this section:

1. **Manifest.** A route entry with hook event or RPC method, tools, response encoding,
   coverage exclusions, and evidence; runtime evidence counts only for the modes
   actually captured.
2. **Capture first.** No decoder ships on documentation alone. The 0.156.1 capture found
   `availableDecisions` absent from the generated schema, `environmentId: "local"` on
   every request, and resolution notices without results; each would have broken a
   documentation-only design.
3. **Negotiation.** A feature token, a device renderer, and broker checks that keep the
   new kind unapprovable on clients that do not advertise it.
4. **Review limits.** Inline content within the base limits; oversized or truncated
   content disables confirmation.
5. **Watch policy.** Stated per kind. Groups B and C (other than small boolean or enum
   forms) are iPhone-only.
6. **Delivery evidence.** `accepted` only from correlated native evidence: Codex item
   status or RPC result; for hooks, `native_response_written` is the ceiling.
7. **Tests.** Fixture tests, broker tests for the new states, adapter end-to-end tests
   against the in-process broker, and the acceptance cases of section 24.10.

### 24.10 Additional acceptance cases

| ID | Scenario | Required result |
|---|---|---|
| O01 | `MultiEdit` with one ambiguous edit | Stays local; nothing published. |
| O02 | `WebFetch` to a confusable host | Renderer shows the ASCII host; approval covers only that URL. |
| O03 | MCP server command changes between review and dispatch | Server identity mismatch; denied as a system outcome. |
| O04 | MCP tool with an unknown schema | Stays local. |
| O05 | Codex `acceptForSession` offered, device approves once | `accept` sent; never `acceptForSession`. |
| O06 | Permission grant approved with `session` scope | Recorded with scope; shown as active; ends with the session. |
| O07 | Claude `permission_suggestions` present on a Bash approval | Group A approval never writes `updatedPermissions`. |
| O08 | Elicitation schema with a `pattern` keyword | Stays local. |
| O09 | Elicitation in URL mode | Handoff only; no remote accept. |
| O10 | `account/chatgptAuthTokens/refresh` arrives | Refused; nothing published or logged with token content. |
| O11 | `availableDecisions` omits `decline` | A rejection sends an offered denial and labels its effect. |

### 24.11 Suggested order

1. Claude `MultiEdit` and `NotebookEdit` (Group A, file changes): small.
2. Form elicitation with the boolean and enum subset (Group C): medium; needs captures
   from both providers.
3. MCP tool calls with per-server enablement (Group A): medium.
4. Durable grants (Group B): only after this specification is amended.
5. Groups D, E, and F: no work beyond keeping the current refusals.

## 25. References

Repository references are pinned to the inspected commit. External documentation was checked on 24 September 2026 and may change; supported releases must retain their own compatibility evidence. These sources establish the existing interfaces and limitations. New protocol names, policies, limits, endpoints, and rollout requirements in this document are proposed design decisions.

[R1]: https://github.com/chr33s/shell/commit/060236c8a89adff088c4aa2cedc4fb71f91ebc63 "Inspected repository baseline"
[R2]: https://github.com/chr33s/shell/blob/060236c8a89adff088c4aa2cedc4fb71f91ebc63/README.md "Shell architecture and optional Control companion"
[R3]: https://github.com/chr33s/shell/blob/060236c8a89adff088c4aa2cedc4fb71f91ebc63/spec.iphone-gateway.md "Authoritative iPhone-gateway profile and physical-device validation requirements"
[R4]: https://github.com/chr33s/shell/blob/060236c8a89adff088c4aa2cedc4fb71f91ebc63/adapters/README.md "Existing adapter contract"
[R5]: https://github.com/chr33s/shell/blob/060236c8a89adff088c4aa2cedc4fb71f91ebc63/Packages/ShellControlCore/Sources/Protocol/ApprovalSpec.swift "Approval decisions, features, and policy defaults"
[R6]: https://github.com/chr33s/shell/blob/060236c8a89adff088c4aa2cedc4fb71f91ebc63/Packages/ShellControlCore/Sources/Protocol/Operations.swift "Operation schemas and exec.v1 requirements"
[R7]: https://github.com/chr33s/shell/blob/060236c8a89adff088c4aa2cedc4fb71f91ebc63/Packages/ShellControlCore/Sources/Protocol/HostIPC.swift "Local framing, capabilities, and approval wait contract"
[R8]: https://github.com/chr33s/shell/blob/060236c8a89adff088c4aa2cedc4fb71f91ebc63/Packages/ShellControlCore/Sources/Protocol/Commands.swift "Existing signed command envelope and command types"
[R9]: https://github.com/chr33s/shell/blob/060236c8a89adff088c4aa2cedc4fb71f91ebc63/Packages/ShellControlCore/Sources/Client/DecisionCoordinator.swift "Review/sign/submit mechanics and submission states"
[R10]: https://github.com/chr33s/shell/blob/060236c8a89adff088c4aa2cedc4fb71f91ebc63/Packages/ShellControlCore/Sources/Client/ControlAPIClient.swift "Existing runtime endpoints"
[R11]: https://github.com/chr33s/shell/blob/060236c8a89adff088c4aa2cedc4fb71f91ebc63/Packages/ShellControlCore/Sources/Client/WatchGatewayClient.swift "Watch gateway reachability and bounded live requests"
[R12]: https://github.com/chr33s/shell/blob/060236c8a89adff088c4aa2cedc4fb71f91ebc63/cmd/README.md "Native host tools and structured permit requirements"
[P1]: https://code.claude.com/docs/en/hooks "Claude Code hooks reference"
[P2]: https://learn.chatgpt.com/docs/hooks "OpenAI Codex hooks reference; current destination of developers.openai.com/codex/hooks/"
[P3]: https://code.claude.com/docs/en/agent-sdk/user-input "Claude Agent SDK: approvals and user input"
[P4]: https://learn.chatgpt.com/docs/app-server "OpenAI Codex app-server reference; current destination of developers.openai.com/codex/app-server/"
[A1]: https://developer.apple.com/documentation/watchos-apps/adding-actions-to-notifications-on-watchos "Apple: notification actions on watchOS"
[A2]: https://developer.apple.com/documentation/watchconnectivity/transferring-data-with-watch-connectivity "Apple: WatchConnectivity transfer mechanisms"
[T1]: https://man.openbsd.org/tmux.1 "tmux manual, including control mode"

[R13]: https://github.com/chr33s/shell/blob/060236c8a89adff088c4aa2cedc4fb71f91ebc63/cmd/Package.swift "Reusable native host/daemon library products"
[R14]: https://github.com/chr33s/shell/blob/060236c8a89adff088c4aa2cedc4fb71f91ebc63/services/shell-control/Package.swift "Reusable broker library product"
[R15]: https://github.com/chr33s/shell/blob/060236c8a89adff088c4aa2cedc4fb71f91ebc63/shell/Entitlements/Shell.entitlements "Baseline app entitlement file"
[M1]: https://developer.apple.com/documentation/servicemanagement/smappservice "SMAppService: Mac Catalyst 16+, macOS 13+"
[M2]: https://developer.apple.com/forums/thread/835003 "Apple DTS, June 2026: sandboxed app/LaunchAgent IPC, provisioning, and app-like wrappers"
[M3]: https://developer.apple.com/app-store/review/guidelines/ "App Review Guidelines 2.2 and 2.4.5: TestFlight and Mac distribution requirements"
[M4]: https://developer.apple.com/videos/play/wwdc2023/10266/ "Apple WWDC23: environment constraints; bundle-relative LaunchAgent executable example"
[M5]: https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html "Apple launchd guide: per-user lifetime, KeepAlive, on-demand services; use current registration rather than archived installation paths"
[M6]: https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html "Apple XPC guide: on-demand/idle lifetime and privilege separation"
[M7]: https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.enum/enabled "SMAppService enabled is registration/eligibility, not application readiness"
[M8]: https://developer.apple.com/documentation/servicemanagement/smappservice/opensystemsettingsloginitems() "System Settings handoff API"
[M9]: https://support.apple.com/en-vn/guide/deployment/depdca572563/web "Apple: bundled service management, diagnostics, and macOS 26 background-after-quit consent"
[M10]: https://developer.apple.com/forums/thread/721701 "Apple DTS: App Groups across Catalyst/native macOS and February 2025 provisioning changes"
[M11]: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.server "App Sandbox incoming-network entitlement"
[M12]: https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/ "TestFlight platforms, distribution, and 90-day beta lifetime"
