# Captured from codex-cli 0.156.1 (`codex app-server`, stdio)

Captured on 2026-09-24 by a scripted client (`initialize` with `experimentalApi`,
`thread/start` with `approvalPolicy: "untrusted"`, two turns asking the agent to `touch`
a file). Paths are redacted; nothing else was changed.

| Response written | Observed |
|---|---|
| `{"decision":"decline"}` to the first approval | `serverRequest/resolved`, then `item/completed` with `status: "declined"`; no file created |
| `{"decision":"accept"}` to the second approval | `serverRequest/resolved`, then `item/completed` with `status: "completed"`; the file was created |

Differences from both the published docs and `codex app-server generate-json-schema`
for the same build: the approval carries `availableDecisions` (not in the generated
schema) and it listed `accept`, an exec-policy amendment, and `cancel` — **not `decline`**,
although `decline` was honoured; `environmentId` is `"local"`; `command` is a single
string (`/bin/zsh -lc '…'`), not an argv; `serverRequest/resolved` carries only
`requestId` and `threadId`. The adapter therefore sends only offered decisions, and
correlates acceptance through the item's final status. `item/fileChange/requestApproval`
and `item/tool/requestUserInput` were not triggered in this capture.

## Hook route (`PermissionRequest`), captured 2026-09-25

A scripted `codex app-server` client ran one turn per decision (`approvalPolicy:
"untrusted"`, asking the agent to `touch` a file) in a scratch project that was trusted
in `~/.codex/config.toml`. Its `.codex/hooks.json` had a capture hook on
`PermissionRequest` and `PreToolUse`, and both hooks were trusted through `/hooks`.
The trust entries were removed afterwards. Paths are redacted.

| Fixture | Hook response written | Observed |
|---|---|---|
| `hook.permission-request.bash.deny.input.json` | `../permission-request.bash.deny.expected.json` | `hook/completed` with `status: "blocked"` and the message as a `feedback` entry (`hook.permission-request.completed.blocked.json`); no approval reached the client; no file created |
| `hook.permission-request.bash.allow.input.json` | `../permission-request.bash.allow.expected.json` | `hook/completed` with `status: "completed"` (`hook.permission-request.completed.completed.json`); no approval reached the client; the command ran and the file was created |

Differences from the documentation-based fixtures: the input also carries
`transcript_path` and `model`; `tool_input` has only `command` (no `description`);
`PermissionRequest` has **no `tool_use_id`**, while the `PreToolUse` that precedes it
does (`hook.pre-tool-use.bash.input.json`, which the adapter observes but does not
handle). The interactive TUI was not exercised, so this range is recorded for headless
execution only and stays documented at run time.
