# Adapters

An adapter integrates a tool's **documented, blocking pre-execution hook** or an
explicit command wrapper with `shell-controld`. A tool without a safe
request/response hook gets notifications and a link to review elsewhere — never
a synthetic approval implementation (spec.watch.md section 3).

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

Neither script interprets a nonzero exit as permission, and neither reuses the
PTY as a control channel.
