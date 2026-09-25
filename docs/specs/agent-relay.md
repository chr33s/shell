# Shell Agent Relay

**Status:** Implemented in `c2c041b4`: Claude Code and Codex hook adapters, typed questions, experimental managed Codex sessions, the `shell-agent/1` broker and Watch-gateway extensions, and the bundled `ShellControlHost`. Open: the distribution and physical-device release gates (section 20, A37–A52). Provider builds stay informational until a `contract_tested` range covers them. Section 22 is proposed only.
**Scope:** Answer Claude Code and Codex permission requests and typed questions, and drive managed sessions, from iPhone and Apple Watch. Runs over the `shell-agent/1` extension of `shell-control/1` and `shell-watch-gateway/1`, packaged as a sandboxed LaunchAgent inside the Mac Catalyst app.

> tmux keeps and locates the workspace. A native agent integration identifies the pending interaction. Shell Control authenticates the reviewer, records the response, and returns it to that exact interaction.

**MUST**/**MUST NOT**/**SHOULD**/**MAY** are normative. Limits are product defaults, not provider or Apple guarantees. Related: [control-protocol.md](control-protocol.md) (broker, iPhone gateway, Watch), [control-cli.md](control-cli.md), [control-setup.md](control-setup.md), [mobile-connectivity.md](mobile-connectivity.md), [shell.md](shell.md).

## 1. Scope

Native Claude Code and Codex adapters for the optional Shell Control companion. They reuse the Mac-local authority, enrolled device identities, the challenge/sign/submit pipeline, and the iPhone-to-Watch gateway. Approvals MUST NOT be built on terminal bytes.

### 1.1 Required outcomes

- Approve/reject of a documented, supported native permission gate while the agent runs on the execution Mac (including in tmux). Pending requests show on iPhone, eligible ones on Watch. The decision returns to the exact original gate. Recorded response, agent acceptance, and operation completion are separate states.
- Bounded, structured answers to explicit agent questions.
- Separately enabled managed-session capabilities: new instructions, steering, cancellation.
- Delivery needs an available host and a live native wait, not a terminal attachment. Disabling the companion MUST leave terminal, SSH, and tmux use intact.

### 1.2 Non-goals

Terminal streaming or SSH on Watch; arbitrary terminal input; automatic, bulk, or persistent approval; authorization from notification payloads; unattended replay of offline decisions; a public Mac listener; guaranteed push; a universal security boundary around agent actions.

Mac execution host only. A Linux/SSH host would need its own adapter and a separately specified authenticated origin. Attaching Shell to remote tmux MUST NOT make that machine appear integrated or authorized.

### 1.3 Interaction types

| Interaction | Meaning | Handling |
|---|---|---|
| Permission request | Operation awaiting authorization. | Immutable approval; explicit approve/reject. |
| Question | Native request awaiting a constrained answer. | Immutable input request; signed typed response. |
| New instruction | User starts or steers work. | Separate grant, fresh session context, managed adapter. |
| Cancellation | Stop a specific turn or controlled job. | Separate capability; cooperative outcome tracking. |
| Informational event | Progress, completion, failure, attention. | No executable authority. |

A side-effect approval presented as a question MUST be classified as permission review. An unsupported approval-shaped question MUST NOT be remotely approvable.

### 1.4 Distribution objective

Shell-owned host code ships inside the Catalyst app as a sandboxed, app-bundled LaunchAgent registered through `SMAppService`. After explicit user and system consent it runs independently of the UI. Agent runtimes and Tailscale stay explicit prerequisites. A supported service API does not certify the whole app for TestFlight or App Review.[M1][M2][M3]

## 2. Architecture and boundaries

```text
Execution Mac
  tmux pane: Claude Code / Codex CLI ─ native synchronous hook ─ provider adapter
  (alt) managed adapter ↔ agent SDK / app-server
        ↕ authenticated per-user local IPC
  shell-controld ↔ loopback ↔ Mac-local broker (requests • commands • consumes • receipts)
        ↕ HTTPS via Tailscale Serve
  iPhone Control ↔ immediate WatchConnectivity ↔ Shell Watch
Attention only: broker → optional push relay → APNs → iPhone / Watch mirroring
```

Terminal and control connections are independent. Closing a view or detaching tmux MUST NOT cancel a request. Losing the native wait, restarting the agent, or changing its execution context MUST invalidate it unless continuation is proven. The adapter owns provider parsing and native responses. `shell-controld` owns local registration, publication, waiting, and consume mediation. The broker owns the ledger and device authorization. iPhone and Watch own review and their own signing keys. Provider SDKs and RPC deps MUST stay out of Ghostty, rendering, SSH identity, and tmux parsing. Shared mobile protocol code MUST NOT depend on a provider runtime. Provider keys and logins never reach a mobile device.

### 2.1 Logical services and OS processes

In the bundled profile, daemon and broker libraries run in one native `ShellControlHost` process supervised by launchd. The UI configures it over App Group-scoped authenticated XPC. Adapters stay separate. Quitting the UI does not stop the service (section 18.4).

## 3. Integration profiles and provider compatibility

### 3.1 Profiles

- **Hook:** the provider CLI is unchanged. A synchronous hook blocks on one permission request or supported question. Its safety claim covers only responses actually delivered through the hook. It MUST NOT be described as remote-only enforcement under every startup, timeout, config, or crash condition.
- **Managed:** the adapter owns the provider process or connection and its callbacks, and MUST refuse to start when required policy or protocol capabilities are missing. Mandatory review also needs evidence that every targeted action reaches its gate and cannot bypass it on failure. Owning an SDK callback is not that evidence.
- **Informational:** unsupported providers, actions, or builds MAY publish attention/status events and MUST NOT expose approve or reply controls.

### 3.2 Provider surface (checked 24 Sep 2026)

- **Claude:** `PermissionRequest` allow/deny JSON, with no `tool_use_id` and excluding sandbox network prompts. `PreToolUse` can answer `AskUserQuestion` with preserved questions plus `updatedInput.answers`. Exit code 2 is not a denial, and a timeout can leave no decision.[P1]
- **Codex:** `PermissionRequest` allow/deny in `~/.codex/hooks.json`. Changed non-managed hooks need explicit trust review. There is no `updatedInput`, `updatedPermissions`, or `interrupt`.[P2]
- **Claude Agent SDK:** `canUseTool` handles approvals and questions, but earlier auto-approval can bypass it.[P3]
- **Codex app-server:** approval RPCs, user-input requests, turn control, resolution events. Documented as experimental, so managed mode is opt-in and release-gated.[P4]

### 3.3 Compatibility manifest

`adapters/<provider>/manifest.json` MUST equal the manifest compiled into the CLI. It records provider build/range, adapter build, profile, schema fingerprint, native events, response encodings, coverage exclusions, failure behavior, and test evidence.

Evidence levels: `documented`, `contract_tested`, `device_validated`, plus local `user_attested` (`shell-control agent allow-build`). Setup MUST NOT show "Ready" on documented or user-attested evidence. No minimum provider version is asserted. A version string or self-reported capability needs a matching validated decoder and fixtures. Unknown builds are informational. Evidence counts only for captured modes (interactive, headless).

## 4. Identity, registration, and request ownership

### 4.1 Identity

`origin_id`, `job_id`, `run_id`, `request_id`, and `command_id` are unchanged. Added:

| Field | Definition |
|---|---|
| `agent_session_id` | Shell UUID for one registered provider session instance. |
| `adapter_instance_id` | UUID per adapter process lifetime. |
| `native_wait_id` | UUID for exactly one blocking callback, hook, or RPC wait. |
| `connection_epoch` | UUID per native RPC connection lifetime. |
| `provider_session_id` / `provider_turn_id` | Provider IDs, when exposed. |
| `provider_request_id` | Exact native request ID, with its string or number type kept. |
| `provider_tool_use_id` | Optional. Never fabricated. |

A reconnect gets a new `connection_epoch`. A restart gets a new `run_id` and session unless an adapter recovery protocol proves continuity. A reused pane or display name proves nothing.

### 4.2 Registration

The adapter MUST authenticate over per-user IPC and get a per-run capability. It registers provider, build, profile, operations, owned process or connection identity, policy fingerprint where observable, and optional tmux location. The capability MUST stay host-local. It never appears in tmux options, push, URLs, mobile caches, argv, logs, or hook config. Daemon liveness is not wait liveness. Presence derives from the adapter's open wait plus current process/connection evidence. A healthy daemon MUST NOT keep a dead hook alive.

### 4.3 Deduplication and concurrent waits

RPC waits bind to `(agent_session_id, connection_epoch, typed native request ID)`. Hooks without a stable ID generate `native_wait_id` once per invocation and reuse it only for that invocation's IPC retries. Identical arguments do not make identical operations. Concurrent identical requests MUST stay separate. The same message ID with different bytes is a conflict. The adapter MUST hold an in-memory handle to the exact waiter. Dispatch by current pane, latest question, command text, or title is forbidden.

## 5. Agent operation approval schemas

### 5.1 `exec.v1` and `agent.tool.v1`

`exec.v1` (absolute executable, argv, cwd, context commitment) is unchanged. It MUST NOT be filled by splitting a provider command string or guessing the shell invocation.

`agent.tool.v1` is a negotiated wrapper with kinds `shell`, `file_change`, and `tool_call`. Each kind needs its own feature token (e.g. `agent.shell.v1`, `agent.file_change.v1`) and renderer. Unknown kinds MUST NOT become approvable. Wrapper support implies no kind.

### 5.2 Committed content

An operation MUST contain: `provider`, tested `provider_build`, `adapter_build`; `agent_session_id`, `native_wait_id`, and available native IDs; `kind`, native tool name, exact authorization-relevant parameters; absolute `cwd` when directory-sensitive; explicit native `permission_scope` (not guessed); `native_request_sha256` over the canonical native input kept locally; `context_sha256` over documented context material; and whatever the kind renderer needs to show the actual request.

Context binds the active wait, provider identity/build, effective user where observable, exact arguments, relevant effective policy, and locally verifiable preconditions (file base hashes for changes). Unobservable fields are marked unavailable, never invented. A digest commits; it does not prove safety. If the adapter cannot establish a relevant field's meaning or scope, it MUST refuse remote approval and offer native review.

### 5.3 Kind review requirements

| Kind | Review material | Device policy |
|---|---|---|
| `shell` | Exact command string or true argv, cwd, known shell semantics, reason, scope. | Full review. Watch only via an explicitly tested narrow policy. |
| `file_change` | Exact paths, change kind, full relevant diff, base/precondition hashes. | iPhone full review. Never Watch. |
| `tool_call` | Stable tool/server identity, exact side-effecting args, schema identity, scope. | Disabled until a specific renderer/adapter pair is approved (section 22.2). |

Network grants, directory-wide grants, policy changes, and grouped requests are excluded from remote approval. When one native decision can authorize several downstream operations, the UI MUST NOT say "Approve once". For a supported single gate, "Approve once" means one decision for that gate, not one guaranteed side effect.

### 5.4 Illustrative shape

```json
{"schema":"agent.tool.v1","provider":"claude_code","provider_build":"<tested>","adapter_build":"<adapter>",
 "agent_session_id":"5000…0001","native_wait_id":"6000…0001","provider_session_id":"native-session",
 "kind":"shell","tool_name":"Bash","cwd":"/Users/example/src/shell",
 "shell_request":{"representation":"command_string","command":"git status --short","shell_identity":null},
 "permission_scope":"single_native_gate","native_request_sha256":"<hex64>","context_sha256":"<hex64>"}
```

A null `shell_identity` is an explicit limitation, and the compatibility profile decides whether the semantics are reviewable. The enclosing approval keeps its immutable spec and hash. It MUST require `agent.tool.v1`, the kind token, and `consume.v1`, with all metadata inside the committed operation. Fixtures: `protocol/fixtures/agent-approval-spec.*`. Schema: `protocol/schemas/agent-tool-operation.schema.json`.

## 6. Typed questions and replies

### 6.1 `input.request`

`input.request` is separate from `approval.request`. `reply` is never added to the approve/reject enum.

An `InputSpec` has `v`, `type`, origin/job/run/request IDs, `created_at`/`expires_at`, `summary`, `source`, `questions`, `allowed_responses`, `minimum_review`, `required_features`, and `effect`. `source` commits the provider and adapter builds, `native_request_sha256`, `context_sha256`, `answer_mapping_sha256`, and the native IDs. The mapping digest covers the exact map from Shell question and choice IDs to native fields and values, and the host MUST recheck it before dispatch.

`effect` is `answer_question`. Inputs that grant tool or permission authority MUST use approval semantics. Unknown effects are not remotely answerable.

| Kind | Request fields | Answer |
|---|---|---|
| `single_choice` | Ordered choices: stable `id`, `label`, optional `description`. | One `choice_id`. |
| `multi_choice` | Choices plus min/max selections. | Unique choice IDs in canonical order. |
| `text` | Explicit max UTF-8 bytes; optional non-executable hint. | Exact UTF-8 text. |

- Questions have `id`, `prompt`, `kind`, `required`. Question and choice IDs are non-empty ASCII, ≤ 64 chars, unique in scope.
- Prompt ≤ 2,048 bytes, label ≤ 256, description ≤ 1,024, all within the total-spec limit. No trimming, normalization, or case-folding of committed content.
- Unsupported: arbitrary JSON Schema, regex validators, file upload, URL-opening actions, secret entry, executable templates. Any unknown required constraint disables remote reply.

### 6.2 Illustrative shape

```json
{"v":1,"type":"input.request","request_id":"…","origin_id":"…","job_id":"…","run_id":"…",
 "created_at":"2026-09-24T08:00:00Z","expires_at":"2026-09-24T08:05:00Z",
 "summary":"Choose the test scope","effect":"answer_question",
 "source":{"provider":"codex","provider_build":"<tested>","adapter_build":"<adapter>",
   "native_request_sha256":"<hex64>","context_sha256":"<hex64>","answer_mapping_sha256":"<hex64>",
   "agent_session_id":"…","native_wait_id":"…","connection_epoch":"…",
   "provider_session_id":"thread-x","provider_turn_id":"turn-x","provider_request_id":23},
 "questions":[{"id":"test_scope","prompt":"Which tests should run next?","kind":"single_choice","required":true,
   "choices":[{"id":"focused","label":"Changed modules only"},{"id":"all","label":"Entire test suite"}]}],
 "allowed_responses":["answer","decline"],"minimum_review":"watch",
 "required_features":["agent.input.v1","agent.input.consume.v1"]}
```

The hash covers the whole canonical spec. Any change (source, labels, constraints, expiry) requires withdrawal and a new request ID. See `protocol/fixtures/input-spec.*` and `protocol/schemas/input-spec.schema.json`.

### 6.3 Answer semantics

The signed response MUST carry the actual answer, not a digest or unsigned companion. Text is data for the native input API and MUST NOT pass through shell evaluation, paste, or concatenation. Reject missing required answers, duplicate or extra question IDs, unknown choices, bad cardinality, invalid Unicode, and over-limit text. Choices map through the committed map, never a lossy or truncated label. `decline` is offered only with a tested native decline mapping. Expiry withdraws the request without inventing an empty answer or cancelling unrelated work. Text MAY be drafted offline, but is not signed, queued, or sent until the exact request is refreshed and confirmed online.

## 7. Signed commands and decision processing

### 7.1 Control model

Agent approvals use the existing signed envelope, request digest, observed state/policy versions, review challenge, and `approval.decide`. Push, pane identity, connection, or an unsigned gateway assertion never replaces them.

A separate agent command union holds `input.respond`, `agent.message`, and `agent.turn.cancel`. It reuses envelope fields and signing primitives, and old decoders MUST NOT silently accept the new types. `input.respond` binds:

| Field | Commitment |
|---|---|
| Envelope | `v`, `type`, `command_id`, `device_id`, exact enrolled `aud`, `issued_at`, `not_after`. |
| Request | `request_id`, recomputed `request_hash`. |
| Observed state | `expected_state_version`, `policy_version`. |
| Review | `challenge_id` bound to action, signer, request, versions. |
| Response | `action: answer` with typed `answers`, or `action: decline` with none. |

Answers look like `{"question_id":"test_scope","kind":"single_choice","choice_id":"focused"}`, sorted by question ID. Signing is ES256 over JCS with the existing audience convention (`protocol/schemas/agent-command.schema.json`). Watch commands MUST be signed on the Watch and forwarded unchanged. The broker independently verifies signer, enrollment, grants, and the current Watch-to-iPhone binding.

### 7.2 Review sequence

1. Fetch the immutable request and projection; recompute the hash.
2. Verify kind, features, review level, live source presence, native deadline.
3. Show all required content; get explicit confirmation of the exact decision or answer.
4. Get a challenge confirming the same hash and versions. Any change needs fresh review.
5. Sign, and durably record the command ID and JWS before the first send.
6. Submit on the authorized live path. The broker atomically records the winner, idempotency record, and change event.
7. Show "Response recorded", then follow dispatch and receipt evidence. Never show operation success here.

Challenge expiry ≤ request/native deadline. Command lifetime ≤ challenge. Claim permits respect the signed deadline, and consume MUST NOT extend authorization.

### 7.3 Concurrency and retry

The first valid committed response wins. Later ones get the existing resolution or `request_resolved` and never overwrite it. Authenticate before any idempotency lookup. Same ID with same signed content returns the recorded outcome, even after expiry. Same ID with different content is a conflict. Idempotency never admits a newly expired command. After a transport timeout, query the command ID before any new mutation. Only the identical JWS may be retried, only during explicit live reconciliation, and only within its deadline. No background retry of authorizing commands. Unresolved command IDs sit in a protected journal for reconciliation. The journal does not authorize replay.

## 8. Native delivery, receipts, and recovery

### 8.1 Dispatch sequence

Approvals use the existing consume. Inputs use one-time `input.consume` bound to request hash, winning command ID, response hash, run, and native wait. The host MUST:

1. confirm the signed result and current resolution
2. verify the original wait is open and belongs to the registered run/connection
3. recheck observable committed context and native deadlines
4. atomically claim; validate the permit and its deadline
5. persist a dispatch record with the binding and a digest of the exact native response bytes
6. persist `dispatch_started` before the first possible provider write
7. send once through the original callback, pipe, or RPC request
8. record transport and native-acceptance evidence separately, then publish the strongest justified receipt

A rejection maps only to the native denial and still needs wait correlation and journaling. Adapter-generated denials on deadline or unavailability MUST be labeled system outcomes, not user rejections.

### 8.2 State dimensions

| Dimension | States |
|---|---|
| Request resolution | Approval: `pending`, `approved`, `rejected`, `expired`, `withdrawn`. Input: `pending`, `answered`, `declined`, `expired`, `withdrawn`. |
| Response dispatch (`agent.delivery.v1`) | `none`, `awaiting_origin`, `claimed`, `dispatch_started`, `native_response_written`, `accepted`, `not_applied`, `unknown`. |
| Agent operation | `not_observed`, `running`, `completed`, `failed`, `cancelled`, `unknown`. |

These MUST NOT be serialized into legacy enums without version negotiation. `native_response_written` only means bytes reached the local transport, and is the ceiling for hooks. `accepted` needs correlated native evidence. A "request cleared" event alone is not enough, since it may be a cancel or another client. In legacy receipts, `applied` needs documented acceptance evidence and `not_applied` positive evidence of non-application. Otherwise `unknown`. Tool completion proves acceptance only with unambiguous correlation. Text, timing, or terminal content never does.

### 8.3 Crash handling

Before `dispatch_started`, a record may resume only if the exact wait and unexpired authorization still exist. At or after it, never re-dispatch without provider proof of non-acceptance and a protocol-safe retry. After an unprovable partial write or crash: mark `unknown`, disable dispatch, reconcile from correlated evidence. A new process never attaches old authority to a similar-looking callback. The system promises durable response records and one-time claims, not exactly-once external side effects.

### 8.4 Races

Withdraw the mobile request when the native deadline expires, the turn ends, the gate clears, or another local client resolves it. Recheck before dispatch. An explicit late provider rejection is `not_applied`. A lost connection without evidence is `unknown`. Never relaunch a tool or start a turn to make an old response work.

## 9. Claude Code adapter

### 9.1 Permission hook

`shell-control agent hook claude-code` dispatches only supported event names from stdin with the pinned decoder. It parses without evaluating and registers the live invocation before publishing. `agent install` merges only Shell's synchronous `PermissionRequest` stanza into `~/.claude/settings.json`. Matcher `^Bash$`, with Edit/Write via `--include-file-changes` (iPhone only). Tested outer timeout 360 s. Other hooks are preserved and the old file backed up. Config MUST use the verified executable path.[P1] Consumed, verified, unexpired approval → `behavior: allow`. Rejection or adapter deadline → `behavior: deny` with a bounded reason. Exit 0 once valid JSON is written. stdout is only the provider's decision JSON or nothing. An exit code is never authorization. Never include permission updates, persistent rules, modified arguments, or mode changes. Other policy hooks may still deny.

### 9.2 Deadlines and coverage

≤ 300 s review, hard stop at 330 s from hook entry, outer timeout 360 s. Setup overhead is subtracted from the review window. A shorter native deadline wins. Before publication (Control stopped, unsupported tool, untested build) the hook writes nothing, so the provider's terminal prompt applies. After publication, broker failure, malformed results, expiry, or changed context yield a native denial while the hook is alive. If the hook never starts or is killed, no denial is possible, so setup and UI MUST keep the hook-profile limit visible (section 3.1). Unsupported prompts, including network gates, are informational or handoff only. Full coverage MUST NOT be claimed.

### 9.3 Questions

`AskUserQuestion` goes through a separately configured `PreToolUse` route or a managed SDK callback. Original input is preserved and typed answers map back to the provider shape. Duplicate question text that can't be represented unambiguously MUST disable the route.[P1][P3] A bare allow is never an answer. Validate every answer against the committed question and build the response from the immutable input plus the signed answer. A choice never authorizes editing other arguments. Interactive and headless modes need separate fixtures; neither implies the other. A cancelled callback invalidates the input immediately. An unanswered question stays with the terminal.

## 10. Codex adapter

### 10.1 Permission hook

`shell-control agent hook codex` uses the same narrow structure in `~/.codex/hooks.json`. Setup MUST require Codex hook trust review (`/hooks`) and MUST NOT bypass it.[P2] The Codex decoder is independent of Claude's. It returns only the tested allow/deny shape, never Claude-only extensions. If a broader scope hides behind a shell-shaped hook, remote approval is disabled.

### 10.2 Managed app-server mapping (experimental)

`agent install codex --enable-managed` then `agent launch codex --managed` runs a host-owned `codex app-server` over stdio. The adapter initializes the protocol, keeps reading while waiting, serializes writes, and derives schemas from the tested binary where supported.[P4]

| Native surface | Shell mapping |
|---|---|
| `item/commandExecution/requestApproval` | Operation approval: approve → `accept`, reject → `decline`. |
| `item/fileChange/requestApproval` | Full-review file change joined to the exact item changes. |
| `item/tool/requestUserInput` | Typed input, unless its semantics are authorization. |
| `serverRequest/resolved` | Close the native request; reason from correlated evidence; sole source of `accepted`. |
| `item/completed` | Correlated operation outcome. |
| `turn/start`, `turn/steer`, `turn/interrupt` | New instruction, steering, cancellation (section 15). |

Validate scope and offered decisions per request. Only a decision in `availableDecisions` may be sent, and `acceptForSession` is never substituted for a one-time decision. Permission tools, network grants, and MCP elicitation need their own schemas (section 22). Native auto-resolution or expiry MUST shorten the Shell deadline. No default answer is generated. Other unsupported server requests get a JSON-RPC error.

### 10.3 Terminal coexistence

The managed adapter MUST own request routing. A second app-server client can't be assumed to see or resolve another client's requests. In managed mode the launching terminal is the local client: typed lines start or steer turns, and `/approve N`, `/deny N`, `/answer N …`, `/interrupt`, `/quit` act on requests. First of terminal or device wins; the other is withdrawn. A native remote TUI would need a separate ownership contract, one waiter registry, and race tests. No raw app-server listener is exposed to devices. The experimental status MUST stay visible.

## 11. Events, synchronization, and notifications

### 11.1 Event vocabulary

`agent.session.started`, `agent.session.ended`, `agent.status.changed`, `agent.approval.created`, `agent.input.created`, `agent.request.resolved`, `agent.delivery.updated`, `agent.turn.completed`, `agent.turn.failed`. Each carries a unique ID, origin/session/run identity, optional request/native correlation, occurrence and observation times, and a bounded summary. Provider timestamps are metadata only; the broker assigns order. Status events MUST NOT mutate a request. Terminal output MUST NOT resolve a native request. Bells and OSC only produce hints labeled unverified.

### 11.2 Durable synchronization

One broker store and transaction writer, plus an agent projection and change feed. A request or response and its event MUST commit atomically. Snapshots mark a consistent sequence cut, and changes start after it. Cursors are opaque and principal-scoped; an expired cursor means re-snapshot. Missing or coalesced pushes are recovered by snapshot and changes. All request and response transitions are kept. Non-authorizing progress may coalesce. No token-by-token output. Final summaries are bounded, attributed to the agent, and never enable actions.

### 11.3 Push

The optional relay has no decision authority. Without it, users check in the foreground ([control-protocol.md](control-protocol.md)). A push carries only an opaque origin/request/event reference and generic text: no commands, diffs, answers, credentials, signed commands, permits, or actionable payloads. Its expiry must not outlive relevance. Review is a foreground notification action that fetches current state. Dismissing, delivering, opening, or acknowledging is never a decision. Background approve/reply actions are prohibited.[A1]

## 12. iPhone and Watch experience

### 12.1 iPhone

A unified Control inbox of approvals, questions, and outcomes. Items show trusted host identity apart from agent labels, plus provider/session, kind, expiry, review requirement, freshness. Detail renders the exact operation or question. Hidden or truncated authorization-relevant content blocks confirmation. Large unsupported content goes to native review. Text replies show the final text before confirmation. "Open terminal" is navigation only. "Sending", "Response recorded", "Waiting for agent", "Agent accepted", "Not applied", "Outcome unknown" are distinct. Task completion is reported separately.

### 12.2 Watch

A small review and signing client behind the paired iPhone, using immediate requests with the existing bounded round trip. Eligible: low-complexity supported approvals; ≤ 2 short questions with ≤ 4 choices each; or permitted short text with a final confirmation screen. File changes and broad permissions go to iPhone or native review. Needs supported schemas, adequate content, current policy, a fresh request, and a live gateway. No iPhone means submission is disabled at once. Stale cached details are labeled and never authorize. Dictation is only a draft, and MUST be reviewed and confirmed before signing.

### 12.3 Gateway rules

Executable interactions use immediate `sendMessageData` request/reply. `updateApplicationContext` and queued transfers MAY carry only replaceable cache hints.[A2] The phone forwards Watch-signed commands unchanged and MUST NOT re-sign them. A revoked gateway or changed Watch binding blocks the request. A gateway timeout is uncertainty to reconcile by command ID, not a rejection.

## 13. tmux integration

### 13.1 Navigation only

tmux supplies persistent sessions and control-mode events, not authorization semantics.[T1] No approval state from `capture-pane`, `pipe-pane`, prompt regexes, titles, OSC, or terminal text. The adapter MAY register a non-authorizing `terminal_location` (`origin_id`, tmux server instance evidence, `session_id`, `window_id`, `pane_id`, `observed_at`). It sits outside authorization fields and never stands in for wait identity. The tmux socket path is never exposed.

### 13.2 Safe handoff

"Open terminal" resolves the enrolled host and a configured connection, then checks that server, session, and pane still match. Otherwise it shows "Original terminal unavailable" and offers manual navigation, never a replacement labeled restored. The companion MUST NOT send `send-keys`, `paste-buffer`, Ctrl-C, Enter, `y`, or text for approval, input, or cancellation.

### 13.3 Lifecycle independence

Detaching tmux or losing SSH resolves nothing. A vanished pane doesn't prove the agent stopped, and a surviving pane doesn't prove the callback exists. Native process/connection evidence decides. Everything MUST work without tmux.

## 14. API, IPC, and compatibility

### 14.1 Extension strategy

`shell-control/1` is unchanged. A missing `GET /v1/agent/capabilities` means no extension. New record types never reach legacy snapshot/change decoders. After negotiation, agent approvals use base approval endpoints with the new schema. Inputs, agent projections, detailed receipts, and session commands use the extension. One broker, grant registry, transaction writer, journal, and signing stack serves both.

### 14.2 Endpoints

All need the authenticated, pinned-origin path. "Origin" is the registered execution origin; mobile credentials cannot make origin-only mutations.

| Method and path | Principal | Contract |
|---|---|---|
| `GET /v1/agent/capabilities` | Device/origin | Version, features, limits, kinds, profiles. |
| `POST /v1/agent/sessions` | Origin | Idempotent session registration bound to a run. |
| `GET /v1/agent/sessions/{id}` | Device/origin | Session state, actions, non-authorizing location. |
| `GET /v1/agent/sessions/{id}/commands` | Origin | Recorded session commands (message/cancel) pending for the managed adapter. |
| `POST /v1/agent/sessions/{id}/commands/{cid}/claim` | Origin | One-time claim of a session command for this connection. |
| `GET /v1/agent/snapshot` | Device | Stable-cut paginated projection (`limit`, opaque `page`). |
| `GET /v1/agent/changes` | Device | Changes after a principal-scoped `cursor` (`limit`). |
| `POST /v1/agent/inputs` | Origin | Publish an immutable input spec; conflicting ID reuse fails. |
| `GET /v1/agent/inputs/{id}` | Device/origin | Spec, recomputed digest, projection. |
| `POST /v1/agent/inputs/{id}/withdraw` | Origin | Withdraw exact run/request/hash (idempotent `mutation_id`). |
| `POST /v1/agent/inputs/{id}/consume` | Origin | One-time claim of the winning response for the live wait. |
| `POST /v1/agent/review-challenges` | Reviewer | Challenge bound to action, request, signer, versions. |
| `POST /v1/agent/commands` | Reviewer | Submit JWS; `Idempotency-Key` = command ID. |
| `GET /v1/agent/commands/{id}` | Reviewer/origin | Query result without resubmitting. |
| `POST /v1/agent/receipts` | Origin | Idempotent correlated delivery evidence. |
| `POST /v1/agent/events` | Origin | Normalized events (section 11.1). |

Authorization filtering MUST match across snapshots, changes, fetches, and attachments. A user-supplied origin or device ID never decides authorization. The signed command is the only authoritative mutation payload; duplicate unsigned copies are rejected. Unknown command types, required features, or authority-bearing members fail closed.

### 14.3 Consume contract

Request: `mutation_id`, `run_id`, `native_wait_id`, `request_hash`, `command_id`, canonical `response_hash`, with origin taken from authentication. Permit adds `permit_id`, issue time, and `apply_before`, and is valid only for its registered run and wait. A repeated consume returns the same claim with no new deadline. A different consume on a claimed request fails. The adapter validates the permit, compares every binding, and enforces the deadline locally. The daemon MUST NOT report "approved" because a child exited 0.

### 14.4 Local IPC

Existing length-prefixed framing and the per-run capability boundary are kept. Added types: `agent.register`, `agent.event`, `input.request`, `input.wait`, `input.withdraw`, `agent.receipt`. Approval messages are unchanged. Every message follows the message-ID/idempotency convention, and the daemon authenticates before touching another run. Native input is read under a strict size limit. Native stdout is reserved for the provider response, logs go to a protected channel or stderr. The size check covers the fully serialized envelope (JWS, base64, nesting), and per-object limits never override a smaller frame limit.

### 14.5 Watch transport extension

`shell-watch-agent-gateway/1` exists only after negotiation with an upgraded iPhone. Same WCSession, routed by protocol discriminator to a separate strict decoder. Envelope: `protocol`, `message_id`, `watch_device_id`, fixed `type`, bounded `body`. Replies echo the ID and separate transport failure from the broker result. Allowlist: capability/session reads, snapshot/changes, input fetch, review challenge, signed submit, command query. No URL fetch, RPC pass-through, shell, or HTTP proxy. Availability is only a cache hint. An old phone returns unsupported, and the Watch MUST NOT fall back to keystrokes or a phone-signed command.

### 14.6 Migration

No redefined enums or silently widened signed fields. Schema fixtures, decoder branches, and capability gates ship together. `exec.v1` approvals and ordinary Watch decisions MUST work without any agent integration. Old clients only get records they can parse, preserved unknown schemas stay unapprovable, and an optional generic notice may point to an upgrade. Cursor namespaces keep agent cursors out of legacy endpoints.

## 15. New messages and cancellation

Off by default; requires a managed session. Enabling approvals or questions MUST NOT enable these.

### 15.1 New instruction and steering

`agent.message` needs the `agent.messages.send` grant, an opted-in managed session, explicit text confirmation, and a fresh session challenge. It binds session/run, exact text, expected session version, and `mode: new_turn`, or `mode: steer` plus the expected active turn ID. The challenge request includes the proposed action digest, and challenge and command MUST agree on it (true of every command targeting mutable session state). `new_turn` is rejected unless still idle; `steer` is rejected if the active turn changed. Never queued or reinterpreted. Plain text only, with no model, cwd, sandbox, permission, tool, system-prompt, or executable overrides. Later tool calls still face provider policy. Hook-only adapters can't do this, so unmanaged CLIs get terminal handoff.

### 15.2 Cancellation

`agent.turn.cancel` needs `agent.turns.cancel`, an exact session/run/turn binding, a fresh challenge, and a supported native method. Acknowledgement doesn't prove termination or rollback. `job.cancel` is kept only where its controlled-job semantics match the adapter-owned job, and never kills a PID found via tmux. Completed side effects remain.

## 16. Security and privacy

### 16.1 Authority and grants

The host and broker are trusted. Same-user or root compromise is out of scope. The system doesn't prove commands safe and isn't end-to-end encrypted against the broker. Existing approval grants stay. Separately revocable: `agent.sessions.read`, `agent.inputs.read`, `agent.inputs.respond`, plus `agent.inputs.read-via-gateway` for a Watch. Opt-in `agent.messages.send` and `agent.turns.cancel` via `shell-control agent grant <id> [--messages] [--cancel]`. Grants are scoped to origins, optionally to sessions or kinds. For every relevant operation the broker MUST check object authorization, action grants, device status, freshness, policy version, challenge binding, signature, and native presence. Watch calls also need the live gateway binding. Tailnet reachability is not enough.

### 16.2 Untrusted content

Tool args, summaries, questions, filenames, URLs, and provider messages are untrusted. Control and bidi characters render visibly; escapes and HTML are never interpreted. Trusted origin identity stays visually separate. "The user already approved" in a prompt does nothing. Hook input can't change routes, keys, grants, schemas, or review policy. Unsupported or oversized content fails safely with native-review guidance. Redaction can't make an inadequate review adequate. If review would reveal a secret, use native review, never just a hash.

### 16.3 Storage and transport

Raw provider payloads and waiter handles stay on the host. Only supported review material and bounded events are sent. Host records are per-user protected; device caches use platform-protected storage. Signatures aren't encryption. Caches and diagnostic exports MUST exclude transcripts, provider credentials, capabilities, and secrets. Signed replies contain answer text, and retention MUST account for it. Command and idempotency evidence is kept at least the base floor. Deletion is an explicit retention operation, and signed payloads are never redacted in place.

## 17. Limits and operational behavior

Negotiated lower limits and native deadlines always win.

| Limit | Default |
|---|---|
| Permission/question review lifetime | 300 s, never past native expiry. |
| Max configurable request lifetime | 1,800 s where natively supported. |
| Review challenge / consume permit | ≤ 60 s / ≤ 10 s, bounded by request, signed, and native deadlines. |
| Hook hard deadline / outer timeout | 330 / 360 s. |
| Native-wait heartbeat / stale | 15 / 45 s; a stale source can't authorize dispatch. |
| Watch round trip | Existing 20 s bound. |
| Foreground refresh | No faster than 5 s without a justified event-driven path. |
| Native input parse cap | 256 KiB. |
| Operation review material inline | 32 KiB; larger needs a separately specified attachment flow. |
| Input spec / combined answers | 16 KiB / 4 KiB before envelope. |
| Extension JSON frame | ≤ 64 KiB incl. envelope, or a lower gateway limit. |
| Questions / choices | ≤ 16 / ≤ 16 per question. |
| Watch question policy | ≤ 2 questions, ≤ 4 choices, ≤ 512 bytes text. |
| Pending per run / origin | 16 / 128; overflow never auto-approves. |
| Change history / command evidence | Base floors of 7 / 30 days. |

- Local wait budgets use monotonic time; protocol expiry uses broker timestamps. A wall-clock jump MUST NOT extend a local deadline.
- Offline: keep the native wait until its deadline and retry idempotent reads with bounded backoff. No background polling to fake availability.
- Failure codes: `unsupported_provider_version`, `unsupported_operation`, `unsupported_input_schema`, `hook_not_trusted`, `native_wait_gone`, `native_context_changed`, `request_expired`, `request_resolved`, `review_required`, `gateway_unavailable`, `idempotency_conflict`, `response_invalid`, `limit_exceeded`, `outcome_unknown`. The UI separates unsupported integration, connectivity failure, recorded denial, and uncertain dispatch.
- Metrics SHOULD cover publication failures, pending age, expiries, duplicates, acceptance latency, unknown outcomes, and gateway failures, with no prompt or answer text. Performance objectives exclude human review time and outages.

## 18. Distribution, installation, and diagnostics

### 18.1 Profile decision

- The Apple profile MUST package the host in the Catalyst app as a sandboxed per-user LaunchAgent via `SMAppService.agent(plistName:)` (Mac Catalyst 16+, macOS 13+; no AppKit bridge). The host is a native app-like wrapper with its own bundle ID, entitlements, and provisioning, running separate from the UI.[M1][M2]
- It MUST NOT install executables into `~/.local/bin`, `~/.local/lib`, or `/Library/PrivilegedHelperTools`, write external LaunchAgent plists, run an installer, or use an unsandboxed helper to evade distribution rules.[M3]
- The standalone Developer ID/CLI profile ([control-cli.md](control-cli.md)) stays separate: never a silent fallback or presented dependency. Disabling Control leaves the terminal usable. Tailscale, Claude, Codex, and their auth are disclosed prerequisites; packaging the host doesn't prove the suite distributable.

### 18.2 Targets and code reuse

`ShellControlHost` (background-only app-like bundle, no window or Dock icon) is embedded only in the Catalyst archive. It runs daemon and broker in one process via `ShellControlHostRuntime` (composing `ShellControlDaemon`, `ShellControlHostSupport`, `ShellControlBroker`; loopback HTTPS kept). It MUST NOT depend on `ShellControlManagement` or spawn the old services. The UI stays Catalyst. All macOS executables, libraries, and registration plists MUST be excluded from iOS, iPadOS, visionOS, and watchOS archives by target config.

### 18.3 Bundle and LaunchAgent declaration

```text
Shell.app/Contents/Library/LaunchAgents/dev.chr33s.shell.control-host.plist
Shell.app/Contents/Library/LaunchAgents/ShellControlHost.app/Contents/{Info.plist,embedded.provisionprofile,MacOS/ShellControlHost}
```

Plist: `Label` `dev.chr33s.shell.control-host`; bundle-relative `BundleProgram` `Contents/Library/LaunchAgents/ShellControlHost.app/Contents/MacOS/ShellControlHost`; `RunAtLoad` and `KeepAlive` true; `MachServices` `group.dev.chr33s.shell.control.host`.[M2][M4] `KeepAlive` is a product choice, not a continuity promise: the host MUST be event-driven when idle, back off boundedly, and avoid crash loops. Socket activation MAY replace residency once external-request wake is shown; private XPC doesn't prove a Tailscale request can wake a stopped broker.[M5][M6] Single writer: recover before advertising readiness, reject duplicate instances (exit 75). launchd is the only supervisor (no `loginItem(identifier:)`, no foreground child).

### 18.4 Registration, consent, lifecycle

Register (`SMAppService.agent(plistName: "dev.chr33s.shell.control-host.plist").register()`, Catalyst only) only after an explicit action explaining Control runs after quit and at login. Code MUST record intent; handle `.requiresApproval`, `.notRegistered`, `.notFound`, and unknown; offer `SMAppService.openSystemSettingsLoginItems()`; reconcile on foreground and on return from Settings. `.enabled` means registered and eligible, not healthy.[M1][M7][M8] Honor the macOS 26+ background-after-quit prompt; never suppress it or require device management.[M9]

| Event | Behavior |
|---|---|
| Quit UI (permission granted) | Host keeps running; can answer a live wait. |
| Disable Control in Shell | Persist stopped intent, stop new work, resolve pending delivery conservatively, unregister, confirm; keep identity and journals. |
| Disabled in System Settings | Report disabled; never silently re-register or restart. |
| Host crash | launchd may restart; recover ledger; never replay ambiguous responses. |
| Log out / log in still enabled | Availability ends (no pre-login promise) / resumes without opening the UI. |
| Sleep, network loss, locked Keychain | Report unavailable/stale; expiry and wait checks apply on recovery. |

Per-user agents end at logout.[M5] Session continuity belongs to the host and tmux/provider. Stopping MUST NOT mean killing a `KeepAlive` process that restarts; a failed unregister is shown as failure; stopping can't retract a dispatched operation.

### 18.5 Signing, sandbox, storage

Both bundles: same team, distribution provisioning, separate IDs, shared App Group `group.dev.chr33s.shell.control`.[M10] The helper has its own sandbox and MUST NOT use `com.apple.security.inherit`. Effective entitlements MUST be inspected in the downloaded TestFlight build.

| Component | Capability |
|---|---|
| Catalyst UI | App Sandbox, App Group, existing justified capabilities. |
| Control host | App Sandbox, App Group; `network.server` loopback only[M11]; `network.client` only for real client functions. |
| Keychain | Narrow access group only where needed; origin key not shared broadly. |

Ledger and secrets live in the helper's container and Keychain (`Application Support/ShellControlHost`, 0700/0600); the App Group holds only bounded shared config and diagnostics. Containers resolve via platform APIs, never `$HOME`. The UI mutates only through host IPC, never as a second DB writer. Origin identity survives compatible updates and isn't regenerated by route, registration, or path changes.

### 18.6 Local IPC boundaries

- **UI ↔ host:** bounded XPC (`XPCSession`/`XPCListener`) on `group.dev.chr33s.shell.control.host`; peers authenticated by code identity and audit token; unsupported messages rejected. The App Group isn't authorization; no broad global Mach exception.[M2]
- **Adapter ↔ host:** authenticated, scoped, framed request/response. Candidate: framed Unix socket `control.sock` in the App Group container, same-user peer check, per-run capabilities; it MUST still pass the distribution spike. Reviewer credentials are never adapter capabilities.
- Local endpoints reject unauthenticated requests, enforce size/rate limits, bind capabilities to run and wait, and expose no command execution. If HTTP is ever used, browser-origin and ambient auth MUST NOT grant authority.
- The sandboxed host MUST NOT get unrestricted filesystem access, launch unsandboxed processes, request Accessibility, or scrape the terminal. A provider profile needing unavailable access stays disabled in that distribution until a reviewable solution is validated.

### 18.7 Tailscale and provider setup

- Tailscale is a separate prerequisite ([mobile-connectivity.md](mobile-connectivity.md), [control-setup.md](control-setup.md)). The app MUST NOT run the `tailscale` CLI, edit other apps' settings, or install it. The user configures `tailscale serve` and enters the MagicDNS name; the host verifies it by fetching `/v1/origin/proof` and checking the origin signature (failures `invalid_name`, `unreachable`, `tls_failure`, `http_status`, `not_shell_broker`, `origin_mismatch`). Pairing is refused until verified; registration never implies a route.
- Hook setup needs permitted file access or an external step; it preserves unrelated hooks, shows the exact change, writes atomically, keeps a backup, and never disables provider trust checks.
- CLI: `shell-control agent install|uninstall|doctor|hook|test|launch|grant|allow-build` ([control-cli.md](control-cli.md)). `launch` MUST NOT silently make CLI use managed. Downloaded runtimes never bypass store rules; no Node or Python runtime is required.

### 18.8 Updates, migration, removal

- App updates are the only host update path: no self-update or copied code; bundle-relative registration; versioned protocol and schema.[M3][M4] Before replacement, quiesce publications, keep journals, identify active waits; waits without continuity evidence are withdrawn or marked uncertain, never re-authorized.
- A legacy standalone install (foreign broker on the port, or a live `~/.local/state/shell-control/control.sock`) is `legacy_conflict`, remedy `shell-control down`. Never a dual writer; migration is explicit and authenticated, keys kept only with verified continuity, no privilege escalation.
- Visible **Disable Control**. Deleting the app ≠ deleting enrollment data; identity and audit data are never silently erased; no uninstall callback. TestFlight builds expire after 90 days: test expiry, invalid profile, and update-required states without bypass.[M12]

### 18.9 Readiness and diagnostics

- Reported separately: host build/signature, registration, authorization, health, storage and keys, adapter compatibility, route, reviewers, push mode. UI states: `not_enabled`, `approval_required`, `registered_starting`, `ready_local`, `route_unavailable`, `disabled_by_user`, `incompatible_build`, `degraded`, `legacy_conflict` (not aliases for `SMAppService.Status`).
- "Ready for approvals" needs the safe fixture (`shell-control agent test`: publication, review, signature, claim, native encoding, receipt, no tool executed) plus native-contract evidence; "Watch ready" also the real gateway path. A ping or `.enabled` is insufficient. A real-provider test MUST run on the TestFlight-installed build with the UI closed and no debugger.
- Diagnostics MAY reference `sfltool dumpbtm` and system logs.[M9] Setup MUST NOT reset global background-task state, touch other apps' jobs, or weaken platform security.

## 19. Implementation layout

Adapters and fixtures: `adapters/{claude-code,codex}/` (`captured-2.1.281/`, `captured-0.156.1/`). Protocol types (`AgentOperation`, `AgentInput`, `AgentCommands`, `AgentSessionCommands`, `AgentDelivery`, `AgentEvents`, `AgentState`, `AgentPolicy`) and clients (`AgentAPI`, `AgentInputCoordinator`, `AgentSessionCoordinator`, `WatchAgentGateway`): `Packages/ShellControlCore/Sources/{Protocol,Client}/`. Hook runner, installer, mappers, and managed Codex session: `cmd/Sources/ShellControlAgentAdapter/`. Daemon agent IPC, host runtime, and XPC: `cmd/Sources/{ShellControlDaemon,ShellControlHostRuntime,ShellControlHostSupport}/`. Broker routes and state: `services/shell-control/`. Hint-only push: `services/push-relay/`. UI: `shell/Features/Control/`, `ShellWatch/`. Host bundle: `ShellControlHost/`. Schemas and fixtures: `protocol/`. No agent code in Ghostty or tmux parsing. A shared coordinator MUST NOT collapse approval and input types into a permissive generic dictionary.

## 20. Acceptance tests and release gates

Tests MUST include deterministic native fixtures, broker and client tests, real supported provider builds, simulator runs, and physical iPhone and Watch cases. A fixture test doesn't show a hook was installed or trusted.

**Contract and protocol (A01–A36).** A01 Claude permission, iPhone approve: exact waiter gets allow after a valid claim, nothing broader. A02 Codex permission, Watch reject: native denial with a Watch-attributable signature. A03 Eligible Watch approval: all content reviewed, current challenge and wait. A04 Unsupported build or kind: no controls; explicit failure or handoff. A05 Untrusted or edited Codex hook: not ready, trust not bypassed. A06 Provider auto-approves before the gate: no review claim, limit visible. A07 Broad, grouped, or network scope disguised as shell: refused, never "Approve once". A08 Identical concurrent requests: distinct identities, each response to its own waiter. A09 Simultaneous devices: one winner, the other gets the resolution. A10 Same command ID retried: recorded result, no second dispatch. A11 Same ID, changed body: idempotency conflict. A12 Hook deadline or broker down: structured denial before the outer timeout, labeled system. A13 Hook not started, killed, or timed out: actual behavior recorded, no enforcement claim. A14 Agent exits while daemon and pane remain: wait invalid, no dispatch. A15 RPC reconnect reuses a numeric ID: epoch blocks cross-connection replay. A16 Local client resolves first: mobile closes; a late response can't revive it. A17 Crash before/after `dispatch_started`: safe resume only before; never repeated after. A18 Written, acceptance unproven: `unknown`. A19 Tool later fails: acceptance and failure distinct. A20 Question, choices, policy, or expiry change mid-review: new request or conflict. A21 Extra/missing/duplicate answers, bad choice or Unicode, oversized text: rejected before claim. A22 Approval-shaped question, or secret/URL elicitation: approval schema or unsupported. A23 Native auto-resolution or turn end: deadline shortened or withdrawn, no default answer. A24 iPhone unreachable, VPN down, Mac asleep, Watch disconnected: explicit failure, nothing queued. A25 Gateway timeout after the broker recorded: reconciled by command ID. A26 Watch or iPhone revoked mid-review: broker rejects later mutations and claims. A27 Push delayed, dropped, duplicated, or opened late: foreground refresh restores state; push authorizes nothing. A28 Dismissal, acknowledgement, or first-action gesture: no implicit decision. A29 Dictation draft differs: final confirmation before signing. A30 Detach/reconnect, pane renamed or reused: control independent, handoff verifies, no injected keys. A31 No tmux: same flow works. A32 Old broker, phone, or Watch: safely unsupported, legacy decoding intact. A33 Snapshot races or expired cursor: nothing missed, re-snapshot. A34 Tampered signature, hash, audience, binding, or response digest: rejected, no dispatch. A35 Message or steer target turn changes: no late delivery, no mode conversion. A36 Cancel races completion: accurate outcome, no rollback or termination claim without evidence.

**Distribution (A37–A52, all outstanding).** A37 Catalyst archive: correct SDKs, signatures, provisioning, App Group; no host in mobile or Watch archives. A38 Processed TestFlight build on a clean Mac: self-contained, with no DMG, root, external copy, or debug entitlement. A39 Background permission granted or denied: state follows intent and consent; denial never re-registers. A40 Quit UI during a real provider wait: host delivers only the valid signed response. A41 Disable with `KeepAlive`: stops persistently, no loop, hidden failure, or erased identity. A42 Disabled in Settings, then reopen: respected; explicit re-enable. A43 Crash, logout/login, sleep/wake, locked Keychain: honest availability, single-writer recovery, no replay. A44 Update with pending waits: compatibility checked, identity kept, uncertain deliveries never resent. A45 XPC from wrong group or peer: rejected, no global Mach exception or bypass. A46 Hook without a valid scoped capability: rejected; group files aren't authentication. A47 Adapter needs unsupported filesystem or process access: disabled, not worked around. A48 Tailscale missing or misconfigured: distinct route failure, no CLI execution. A49 Legacy host owns port, origin, or ledger: no dual writer; explicit migration or conflict. A50 Idle host: bounded CPU and memory, no busy polling, incoming path works. A51 App removed, beta expired, profile invalid, build incompatible: no fallback or bypass; documented state. A52 Full-suite release: terminal, SSH, tmux, and each target tested independently.

**Also required:** zero PTY-based authorization paths, provider/version evidence in manifests, broker restart and corruption recovery tests, unchanged non-companion terminal behavior, and device tests under normal OS suspension, not a debugger.

**Gate status.** Covered by package tests: hook approvals (Claude, Codex), typed questions, experimental managed Codex conversation control, and the host runtime (startup order, recovery, duplicate refusal, legacy conflicts, XPC peer rejection, route verification). Outstanding (distribution spike): signing and provisioning both bundle IDs with the App Group, TestFlight processing and clean-Mac install, consent prompts, sandbox enforcement of the adapter socket with a real provider hook, quit/logout/sleep behavior, A37–A52, and physical-device validation. The spike exits only when a TestFlight-installed build passes A37–A40 and A45–A48 and handles one real external-hook request with the UI closed. A local build never completes it.

## 21. Deferred decisions

These need separate specs or amendments: remote Linux origins, full diffs via content-addressed attachments, broad or network scopes, arbitrary MCP elicitation, independent Watch networking, full transcript sync, and mandatory org-wide enforcement. The Apple service mechanism is settled (section 18). External adapter access, sandbox-compatible Tailscale setup, and distribution itself remain release gates. Managed Codex stays experimental until its interface and support status justify otherwise. Where a provider lacks a reliable request/response interface, the feature MUST stay unavailable, and MUST NOT fall back to scraping prompts or synthesizing input.

## 22. Other native request types (proposed)

Not implemented; unsupported requests are never answered remotely. Evidence: Claude Code 2.1.281 headless captures; codex-cli 0.156.1 `app-server generate-json-schema` output plus live app-server and hook captures; provider docs as of 24 Sep 2026.

### 22.1 Scope and classification

Answered today: Claude `PermissionRequest` `Bash` (Edit/Write opt-in) and `PreToolUse` `AskUserQuestion`; Codex hook `PermissionRequest` `Bash`; managed `item/commandExecution/requestApproval`, `item/fileChange/requestApproval`, `item/tool/requestUserInput`. Everything else stays in the terminal (hook) or gets a JSON-RPC error (managed).

| Group | Requests | Disposition |
|---|---|---|
| A. One-time tool approvals | Claude `MultiEdit`, `NotebookEdit`, `WebFetch`, `WebSearch`, MCP tools; Codex legacy `execCommandApproval`, `applyPatchApproval` | Supportable in `agent.tool.v1` with new kinds and renderers. |
| B. Durable or widened grants | Claude `permission_suggestions`/`updatedPermissions`; Codex `item/permissions/requestApproval`, `acceptForSession`, exec/network-policy amendments, `grantRoot` | New authority model plus spec amendment. |
| C. Structured elicitation | Codex `mcpServer/elicitation/request`; Claude `Elicitation`/`ElicitationResult` | Extend `input.request` for a bounded schema subset. |
| D. Client-defined tools | Codex `item/tool/call` | Refused; Shell registers no tools (Shell tools would need their own spec). |
| E. Credentials and attestation | Codex `account/chatgptAuthTokens/refresh`, `attestation/generate` | MUST NOT reach a device. |
| F. Prompts without a hook | Claude sandbox network prompts | Stay in the terminal until a provider hook exists; never scraped or injected. |

### 22.2 Group A: one-time tool approvals

Existing pipeline; a token and renderer per kind.

- **`MultiEdit`** → `file_change`: apply edits in order to current contents; a missing or ambiguous `old_string` stays local; commit one complete diff and the base SHA-256. **`NotebookEdit`**: commit the notebook base hash and cell-level changes (cell ID, edit mode, old/new source); the renderer MUST show cell source, not raw JSON, and it stays local until one exists. Neither is Watch-eligible.
- **`WebFetch`/`WebSearch`** → `network_fetch` (`agent.network_fetch.v1`): tool, exact URL or query, prompt applied to the result, redirect behavior where observable. Show the full URL with the host separated and escaped, confusable or punycode hosts in ASCII. A domain-scoped `permission_suggestions` is Group B and MUST NOT be applied.
- **MCP (`mcp__<server>__<tool>`)** enables `tool_call` only with a stable server identity digest (stdio: resolved command and args; remote: URL; config change = new identity), a committed input-schema digest (else local), every argument rendered in full (>32 KiB or unbounded values stay local), per-server (optionally per-tool) user enablement with no "approve any MCP tool", and no Watch in the first release.
- **Codex legacy `execCommandApproval`/`applyPatchApproval`**: mechanical mapping; SHOULD be supported only if a v2 client is shown to receive them (0.156.1 did not).
- **Common:** evidence-gated manifest route (Claude hooks need interactive and headless captures), positive and negative fixtures with a refusal per scope-widening field, and a local recheck of every committed precondition before dispatch.

### 22.3 Group B: durable or widened grants

These authorize operations the reviewer hasn't seen: Claude `permission_suggestions` → `updatedPermissions` (seen: `addDirectories`, `setMode: acceptEdits`, destination `session`); Codex `item/permissions/requestApproval` (filesystem/network profile, `scope: turn | session`), `acceptForSession` (similar future prompts), `acceptWithExecpolicyAmendment`/`applyNetworkPolicyAmendment` (persistent rule), and `grantRoot` (session writes under a directory). Adopting them changes the security model and MUST be an explicit amendment, with:

- a new `agent.permission.v1` schema (never inside `agent.tool.v1`) committing the exact rule or profile, scope (`turn`/`session`/`persistent`), destination (Claude user/project/local/session settings), policy before and after, and expiry where supported
- plain-language duration and breadth ("Allow writes under /path for this session"), never "Approve once"; iPhone full review only
- a new revocable grant (e.g. `agent.permissions.grant`), off by default, with policy able to forbid persistent scope
- a broker record per rule with scope and session, shown active and ended with the session; without native revocation (Claude hooks) the UI MUST say Shell revocation leaves provider settings unchanged
- the shown rule sent byte for byte (never broadened, merged, or reordered), then the policy fingerprint recomputed and reported as evidence; for Codex, only decisions in `availableDecisions` (which can omit `decline`)

### 22.4 Group C: structured elicitation

Codex `mcpServer/elicitation/request` carries `serverName`, `threadId`, optional `turnId`, and form mode (`message`, `requestedSchema`) or URL mode (`message`, `elicitationId`, `url`); response `{action: accept|decline|cancel, content?}`. Claude `Elicitation`/`ElicitationResult` hooks match by MCP server name, with undocumented output (capture first). Support requires:

- bounded kinds with their own tokens (e.g. `agent.input.form.v1`): `boolean`, `integer`/`number` with required min/max, `enum`, `multi_enum` with cardinality; strings reuse `text`
- adapter translation from `requestedSchema`; any other keyword (pattern, format, nested objects, `oneOf`, meaning-changing defaults) stays local; both directions committed via `answer_mapping_sha256`
- distinct `accept`/`decline`/`cancel`, with `decline` only when a fixture covers it; URL mode never answered remotely (handoff only); sensitive fields and `isSecret: true` stay local; authority-granting answers (payment, OAuth consent) are Group B

### 22.5 Groups D, E, F

**D:** refuse `item/tool/call`. **E:** the managed adapter MUST NOT opt into client-managed ChatGPT auth or `requestAttestation`, and MUST refuse either request; nothing is published, rendered, forwarded, or logged with token content. **F:** sandbox network prompts stay in the terminal.

### 22.6 Cross-cutting requirements, acceptance, order

Every adopted route needs: (1) a manifest route (event or method, tools, encoding, exclusions, evidence) counted only for captured modes; (2) a capture before the decoder ships (0.156.1 showed `availableDecisions` missing from the generated schema, `environmentId: "local"` on every request, and resolution notices without results); (3) negotiation (token, renderer, broker checks keeping the kind unapprovable on non-advertising clients); (4) inline content within base limits, with oversize or truncation disabling confirmation; (5) a per-kind Watch policy, B and C iPhone-only except small boolean or enum forms; (6) `accepted` only from correlated evidence (Codex item status or RPC result), hooks capped at `native_response_written`; (7) fixture, broker, and adapter end-to-end tests plus:

O01 `MultiEdit` with an ambiguous edit stays local. O02 `WebFetch` to a confusable host shows the ASCII host; approval covers only that URL. O03 MCP server command changed before dispatch: identity mismatch, system denial. O04 Unknown MCP tool schema stays local. O05 `acceptForSession` offered, approved once: `accept` sent. O06 Session-scoped grant: recorded, shown active, ends with the session. O07 `permission_suggestions` on Bash: `updatedPermissions` never written. O08 Elicitation with `pattern` stays local. O09 URL-mode elicitation: handoff only. O10 Token refresh: refused, no token content published or logged. O11 `availableDecisions` without `decline`: rejection sends an offered denial and labels its effect.

Order: (1) `MultiEdit`/`NotebookEdit` (small); (2) boolean and enum forms (medium; captures from both providers); (3) MCP with per-server enablement (medium); (4) Group B only after an amendment; (5) D, E, F keep refusing.

## 23. References

External docs checked 24 Sep 2026. Supported releases keep their own compatibility evidence.

[P1]: https://code.claude.com/docs/en/hooks "Claude Code hooks reference"
[P2]: https://learn.chatgpt.com/docs/hooks "OpenAI Codex hooks reference"
[P3]: https://code.claude.com/docs/en/agent-sdk/user-input "Claude Agent SDK: approvals and user input"
[P4]: https://learn.chatgpt.com/docs/app-server "OpenAI Codex app-server reference"
[A1]: https://developer.apple.com/documentation/watchos-apps/adding-actions-to-notifications-on-watchos "Apple: notification actions on watchOS"
[A2]: https://developer.apple.com/documentation/watchconnectivity/transferring-data-with-watch-connectivity "Apple: WatchConnectivity transfer mechanisms"
[T1]: https://man.openbsd.org/tmux.1 "tmux manual, including control mode"
[M1]: https://developer.apple.com/documentation/servicemanagement/smappservice "SMAppService: Mac Catalyst 16+, macOS 13+"
[M2]: https://developer.apple.com/forums/thread/835003 "Apple DTS: sandboxed app/LaunchAgent IPC, provisioning, app-like wrappers"
[M3]: https://developer.apple.com/app-store/review/guidelines/ "App Review Guidelines 2.2 and 2.4.5"
[M4]: https://developer.apple.com/videos/play/wwdc2023/10266/ "WWDC23: environment constraints; bundle-relative LaunchAgent executable"
[M5]: https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html "launchd: per-user lifetime, KeepAlive, on-demand services"
[M6]: https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html "XPC: on-demand lifetime and privilege separation"
[M7]: https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.enum/enabled "SMAppService .enabled"
[M8]: https://developer.apple.com/documentation/servicemanagement/smappservice/opensystemsettingsloginitems() "System Settings handoff API"
[M9]: https://support.apple.com/en-vn/guide/deployment/depdca572563/web "Bundled service management, diagnostics, macOS 26 background-after-quit consent"
[M10]: https://developer.apple.com/forums/thread/721701 "Apple DTS: App Groups across Catalyst/native macOS"
[M11]: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.server "App Sandbox incoming-network entitlement"
[M12]: https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/ "TestFlight overview and 90-day beta lifetime"
