# Adapters

An adapter integrates a tool's **documented, blocking pre-execution hook** or an
explicit command wrapper with `shell-controld`. A tool without a safe
request/response hook gets notifications and a link to review elsewhere — never
a synthetic approval implementation (docs/specs/control-protocol.md section 2).

Every adapter owes three things:

1. **A context commitment.** `exec.v1` requires the executable identity,
   effective user, declared environment, and any operation-specific
   precondition (a Git object id, for instance) to be hashed into
   `context_sha256`, and re-checked locally before the approval is applied.
2. **A dispatch journal.** The intent to answer the permission gate is recorded
   durably *before* the gate is answered, so a crash is recoverable rather than
   ambiguous.
3. **A receipt.** What was actually applied — `applied`, `not_applied`, or
   `unknown`. A zero exit status from the CLI is not permission, and never a
   substitute for a receipt.

## What is in here

| Directory | What it shows |
|---|---|
| `git-pre-push/` | A blocking Git `pre-push` hook: the operation is known before anything is pushed, and the hook's own exit status gates the push. |
| `command-wrapper/` | An explicit wrapper that owns the full dispatch journal and precondition check for one command. |
| `claude-code/` | The Claude Code hook adapter's compatibility manifest and native contract fixtures. |
| `codex/` | The Codex hook adapter's compatibility manifest and native contract fixtures. |

Neither script interprets a nonzero exit as permission, and neither reuses the
PTY as a control channel.

## Agent adapters

`shell-control agent hook claude-code|codex` is the native adapter of
[`docs/specs/agent-relay.md`](../docs/specs/agent-relay.md). It is compiled into the CLI
(`cmd/Sources/ShellControlAgentAdapter`); these directories hold what release
engineering maintains beside it:

- `manifest.json` — the compatibility manifest: routes, response encodings,
  coverage exclusions, failure behavior, documentation sources, and the
  **tested build ranges**. It must equal the manifest compiled into the CLI
  (`swift test --package-path cmd` checks this; regenerate with
  `UPDATE_AGENT_MANIFESTS=1`).
- `fixtures/` — raw native inputs and expected native responses.

Most fixtures follow the providers' **documented** shapes (checked on
2026-09-24). `claude-code/fixtures/captured-2.1.281/` holds `PermissionRequest`
inputs captured from Claude Code 2.1.281 in headless mode, with the observed
effect of the allow and deny encodings; the manifest records that as
`contract_tested` for headless only. A hook cannot tell headless from
interactive execution, so partial-mode evidence never counts at run time, and
every build still defaults to informational mode: prompts stay
in the terminal and devices get only an attention hint. A build becomes
remotely answerable by adding a `contract_tested` range backed by fixtures
captured from that binary, or locally by an explicit, visible
`shell-control agent allow-build` (reported `user_attested`, never Ready).
