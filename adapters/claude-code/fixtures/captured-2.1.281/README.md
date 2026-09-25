# Captured from Claude Code 2.1.281 (headless)

Captured on 2026-09-24 with `claude -p --model haiku --settings <temp settings>` and a
capture hook on `PermissionRequest` (matcher `Bash`). Paths and the home directory are
redacted; nothing else was changed.

| Fixture | Hook response written | Observed result |
|---|---|---|
| `permission-request.bash.deny.headless.input.json` | `permission-request.bash.deny.expected.json` | Claude reported the command denied; the file was not created. |
| `permission-request.bash.allow.headless.input.json` | `permission-request.bash.allow.expected.json` | The command ran; the file was created. |

Observations: `PermissionRequest` fires in headless mode for a command that needs
permission; it carries `permission_suggestions` and `prompt_id` and **no
`tool_use_id`**. `AskUserQuestion` is not available in headless mode, so the question
route has no captured evidence. Interactive (TTY) mode was not exercised; the spec forbids
inferring it from headless evidence, so this range counts as contract-tested only for
headless execution.
