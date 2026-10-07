# tmux patches

## 0001-program-status-control-client-flag.patch

Lets OSC 7501 (program status) support detection work through `tmux -CC`.

Programs detect support with `OSC 7501 ; ? ST` followed by DA1 (`CSI c`) and
treat the protocol as unsupported if the DA1 reply arrives first. Stock tmux
answers DA1 itself immediately, while Shell's OSC 7501 reply has to travel
through control mode, so detection always fails.

The patch adds a `program-status` control-client flag. With it, tmux holds a
pane's OSC 7501 query as a request (as it does for OSC 4/52), queues later
replies such as DA1 behind it, and releases them once the client answers with
`refresh-client -r %pane:<reply>`. Unanswered requests time out after the
usual 500 ms. Without the flag, nothing changes.

Shell (`TmuxViewer`) sets the flag on attach, reads `#{client_flags}` back, and
answers through `refresh-client -r` only when the server kept the flag;
otherwise it falls back to `send-keys`, where detection still loses to DA1.

The patch is against tmux master and is meant for upstream submission. To run
SwifttyKit's tmux tests against a patched build:

```sh
TMUX_BIN=/path/to/patched/tmux swift test --package-path Packages/SwifttyKit --filter TmuxIntegrationTests
```
