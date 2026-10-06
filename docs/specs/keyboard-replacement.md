# Shell: replacement software keyboard

**Status:** Implemented (simulator unit tests); not yet device-tested.  
**Repository:** `chr33s/shell`  
**Suggested repository path:** `docs/specs/keyboard-replacement.md`  
**Source baseline:** `e5d4465cd4f79d5b167216c2ecaaca13d7501101` (`main`, verified 6 October 2026).  
**Scope:** iPhone and iPad terminal input.  
**Explicit constraints:** No F1–F12 work. Preserve the existing single arrow-control approach.

“Must” identifies a release requirement. Component names marked **new** are proposed, not existing APIs. Numerical layout and performance targets are product requirements to validate, not measurements of the current app.

## 1. Decision

Replace the terminal's primary iOS software keyboard with an app-owned `UIInputView`, while retaining Shell's existing configurable keyboard accessory above it. This is a replacement of the letter/number typing surface, not merely another toolbar row.

The replacement provides a five-row, terminal-oriented US-QWERTY keyboard with a persistent number row, explicit symbol and navigation pages, and a visible switch to Apple's keyboard. Existing Esc, Tab, Ctrl, Option/Alt, Command, custom keys, drawers, and the single arrow button continue through the existing toolbar infrastructure.

Do not introduce a Keyboard Extension target, a separate keyboard installation, synthetic UIKit hardware events, or a new terminal transport. Apple's supported custom-input-view mechanism permits an app-owned primary input view and a separate accessory on the same responder. [A1]

### Product boundaries

| Area | Decision |
| --- | --- |
| Terminal sessions | Support local shell, SSH, ordinary terminal sessions running tmux, and native tmux control-mode panes. |
| Other text fields | Keep the system keyboard for connection forms, secure credential fields, search, settings, and the compose overlay. |
| Arrow navigation | Reuse `KeyboardArrowJoystickButton`. Do not introduce a permanent four-arrow cluster or another arrow control in the replacement body. |
| Function keys | No F1–F12 buttons, layers, picker additions, encoding changes, or new requirements. Existing hardware function-key behavior remains untouched. |
| Platforms | Implement on iOS/iPadOS. Do not change Mac Catalyst, visionOS, or Watch keyboard behavior. |
| Language support | Ship one deterministic US-QWERTY layout. Preserve the system keyboard for other layouts, input methods, emoji, and dictation. |
| Defaults | New installations use Shell for supported terminal input. Existing installations retain System until the user chooses Shell. |
| Escape hatch | A visible **System** key is available on every replacement page. The terminal's keyboard menu also exposes **Use System Keyboard** and **Use Shell Keyboard**. |

## 2. Existing code and integration constraints

The reviewed source already has the essential presentation and dispatch infrastructure:

| Existing component | Relevant responsibility |
| --- | --- |
| `shell/UI/Keyboard/KeyboardAccessoryView.swift` | `UIInputView` wrapper around the existing toolbar. |
| `shell/UI/Keyboard/KeyboardToolbarView.swift` | Drawers, button dispatch, shared sticky modifiers, and one-shot clearing. |
| `shell/UI/Keyboard/KeyboardArrowJoystickButton.swift` | Single arrow control, directional drag, repeat, and persisted joystick/drawer modes. |
| `shell/UI/Keyboard/KeyboardModifierButton.swift` | Inactive, one-shot, and locked modifier states; Esc dispatches immediately. |
| `shell/UI/Terminal/TerminalKeyboardAccessoryController.swift` | Primary/accessory view selection, keyboard suppression, toolbar-only mode, hide/pin state, and geometry. |
| `shell/UI/Terminal/TerminalInputController.swift` | Physical input state, repeat, modifiers, and command/IME handling. |
| `shell/UI/Terminal/TerminalView+Keyboard.swift` | Key dispatch, keybinding sequences, terminal actions, and local-shell interrupt handling. |
| `shell/Core/Terminal/Reconnect/RecoveryInputGate.swift` | Generation-bound, ordered, bounded input admission; no silent keystroke replay on reconnect. |

These responsibilities are verified in the baseline source. [R1–R8]

Two integration hazards must be addressed rather than copied into the replacement:

1. The existing toolbar merges in `SystemShiftReader.currentShift(near:)`. That system-software-keyboard state must not determine a custom keyboard's keycaps or output. Custom mode needs an explicit modifier source while retaining trusted physical-keyboard modifier handling. [R3]
2. The toolbar's ordinary key dispatch includes a debug message containing `key`. Routing every typed letter through that path would expose input content in debug logs. Remove or redact content-bearing logging on all paths exercised by replacement typing, not just in the new view. [R3]

## 3. User-visible layout

### 3.1 Shared structure

The existing accessory remains a separate view above the replacement. Its saved layout and drawer configuration remain authoritative except for the keyboard visibility control described below. The replacement does not otherwise reorder or reset the user's toolbar.

For the replacement feature, the toolbar's keyboard visibility control uses a **keyboard glyph** instead of the current chevron glyph and occupies the **first toolbar position** in the proposed presentation. The existing single `KeyboardArrowJoystickButton` remains present in its existing/proposed toolbar position; changing the visibility icon must not remove, replace, or convert the joystick into individual chevrons.

```text
┌──────────────────────────────────────────────────────────┐
│ [keyboard] Esc Ctrl Opt Cmd Tab [joystick] …              │
├──────────────────────────────────────────────────────────┤
│  1    2    3    4    5    6    7    8    9    0            │
│  q    w    e    r    t    y    u    i    o    p            │
│    a    s    d    f    g    h    j    k    l                │
│ Shift   z    x    c    v    b    n    m        Backspace   │
│ #+=   System   /             Space           .   Return  │
└──────────────────────────────────────────────────────────┘
```

This is a semantic layout, not a pixel-accurate mock-up. The number row and the three typing rows are not horizontally scrollable. Controls stretch or use weighted widths within the actual available content width.

The body does not duplicate the toolbar's arrow button, Ctrl, Alt, or Command controls. A body Shift key is necessary for typing; when a saved toolbar also contains Shift, both are presentations of the same modifier state, not separate latches.

### 3.2 Alphabetic page

| Row | Keys, left to right |
| --- | --- |
| 1 | `1 2 3 4 5 6 7 8 9 0` |
| 2 | `q w e r t y u i o p` |
| 3 | `a s d f g h j k l`, centered |
| 4 | Shift; `z x c v b n m`; Backspace |
| 5 | Symbols (`#+=`); System; `/`; Space; `.`; Return |

Shift changes letters to uppercase and applies the ordinary US symbol pairs to number and punctuation keys. Show the shifted character as a secondary keycap label where legible. For example, Shift+1 enters `!`, Shift+/ enters `?`, and Shift+. enters `>`.

There is no automatic capitalization, spelling correction, smart quotes, smart dashes, double-space-to-period, or automatic trailing space. Return submits terminal Return; it is not a “Send” button for a buffered draft.

### 3.3 Symbols page

The Symbols key replaces the alphabetic body with the following page, preserving its height and the toolbar above it:

| Row | Keys, left to right |
| --- | --- |
| 1 | `1 2 3 4 5 6 7 8 9 0` |
| 2 | Left/right square brackets; left/right braces; left/right parentheses; `<`; `>`; pipe; backslash |
| 3 | Backtick; tilde; `!`; `@`; `#`; `$`; `%`; `^`; `&`; comma |
| 4 | Shift; `-`; `_`; `=`; `+`; `;`; `:`; single quote; double quote; Backspace |
| 5 | ABC; System; Nav; Space; `?`; Return |

A key explicitly labeled with a symbol inserts that symbol. Applying Shift must not unexpectedly turn an explicitly labeled symbol into another symbol; the layout model must distinguish a literal-symbol key from a base key with a shifted alternative. Shift remains a modifier for terminal keybindings and special keys.

All 95 printable ASCII characters must be reachable across the alphabetic and symbols pages, including space. In particular, `*` is available through Shift+8. Do not silently substitute visually similar Unicode punctuation.

Switching pages sends no terminal input and does not consume a pending one-shot modifier. Page selection persists while that terminal remains actively focused, but returns to ABC after leaving terminal input or changing keyboard mode.

### 3.4 Navigation page

**Nav** on the Symbols page opens a page with these controls:

| Region | Controls |
| --- | --- |
| Number row | Same persistent `1…0` row. |
| Navigation row | Home; End; Page Up; Page Down; Forward Delete (`⌦`). |
| Control row | Tab; Shift+Tab; Esc; Paste. |
| Editing/state row | Shift; Clear Modifiers; Backspace. |
| Bottom row | ABC; System; Symbols; Space; `/`; Return. |

There are **no arrow keys on this page**. Arrow movement stays on the existing toolbar button. Home/End/Page Up/Page Down are terminal keys, not commands to move a UIKit text cursor or scroll the local viewport. A receiving shell/editor decides their terminal meaning.

The navigation page is fixed built-in keyboard functionality. It does not require inserting custom keys into the user's saved toolbar or rebuilding the existing custom-key editor.

### 3.5 Sizing and presentation

Use the actual input-view/window bounds, side safe areas, and existing keyboard sizing tokens. Do not calculate width from the physical screen or add another global keyboard-frame singleton.

Target a body row height of 44 points in normal vertical space and 36–40 points in compact-height layouts. Preserve the existing toolbar's sizing policy. Keep all five body rows when Shell mode is available; do not drop the number row or silently remove keys in landscape.

Use at least 44-point-wide targets for System and the principal mode/action controls where the row permits. Alphanumeric keys on narrow phones necessarily have narrower targets: provide non-overlapping hit regions spanning their full layout cells, rather than claiming every key is 44×44. Establish an initial supported content-width floor of 320 points; verify 320, 375, 390, 430, and iPad window widths.

Fit and visibility are release gates. When the body, accessory, and safe-area requirements cannot fit without overlap or leave fewer than two terminal text rows, choose a transient System fallback. Preserve the preference so a later explicit reopening in adequate space can use Shell again. Never change keyboard mode under an active touch.

Pages retain the same height. Drawer expansion may change accessory height through the existing controller, but must not shrink body keys into unusable targets. In height-constrained layouts, use the existing cycling drawer presentation instead of stacking multiple rows; do not rewrite the saved stacking preference.

Custom floating/split keyboard presentation is not part of v1. When UIKit supplies an unsupported floating/undocked presentation, retain System mode with a brief explanation. Do not force UIKit into a docking state or use private APIs. Full-width iPad windowed layouts are in scope when they meet the sizing rules.

### 3.6 Keyboard visibility icon, hide, and restore semantics

Replace the toolbar's current hide/show **chevron glyph** with a **keyboard glyph**. This is an icon/affordance change for the existing visibility action, not a new keyboard-mode action. The control remains in the first toolbar position in the proposed presentation and retains the existing hide, restore, pin, and toolbar-only behavior.

The toolbar keyboard-glyph control is distinct from the replacement keyboard body's **System** action: **System** changes the active software keyboard implementation from Shell to Apple's keyboard, while the toolbar keyboard glyph changes keyboard visibility. The two controls must not share an action merely because both concern keyboards.

When the keyboard-glyph control hides the keyboard, capture the effective software keyboard implementation active at the moment of hiding (`shell` or `system`) as transient per-terminal presentation state. Activating the same keyboard-glyph control while hidden must restore that same implementation. Hiding a Shell keyboard therefore restores Shell; hiding Apple's System keyboard restores System. A hide/restore cycle must not rewrite `softwareKeyboardMode`, trigger migration logic, or silently switch implementations.

The remembered restore mode applies to both ordinary toolbar-only hiding and pinned-hidden behavior. Collapsing the toolbar must not discard it. If the remembered implementation is temporarily unavailable when restoration is requested—for example because current geometry cannot safely present Shell—restore using the existing transient System fallback rules while retaining the remembered Shell restore intent. A later explicit reopen after the constraint clears may return to Shell without changing the saved preference.

An explicit keyboard-mode action overrides the remembered restore mode. In particular, tapping **System** while Shell is visible makes System the active implementation for that presentation and updates subsequent hide/restore behavior accordingly. Switching implementation remains subject to the modifier-clearing and safe-boundary rules in this specification.

The remembered restore mode is transient. Do not persist it to UserDefaults, CloudKit, restoration archives, or another terminal. Clear it when the terminal is destroyed. It must never leak across panes, windows, or sessions.

## 4. Preserve the single arrow control

Reuse the existing `KeyboardArrowJoystickButton` and its saved `Settings.KeyboardToolbar.arrowJoystickMode`. Retain the stable `.arrowDrawerToggle` identifier. Do not replace the control with a new D-pad, a space-bar trackpad, or four permanent buttons. [R2]

The baseline interactions are the compatibility contract:

| Interaction | Required behavior |
| --- | --- |
| Touch without drag in joystick mode | No arrow is sent. |
| Drag | Determine direction from displacement relative to touch-down, using the existing dominant-axis rule. |
| Dead zone | Preserve 18 points. Returning inside it stops repeat. |
| First direction / direction change | Send immediately, cancel the old repeat, then arm the new direction's repeat. |
| Repeat | Preserve the 0.5-second initial delay and 0.1-second interval. |
| Stationary long press | Preserve the 1.5-second switch between joystick and drawer modes. |
| Long-press cancellation | Preserve cancellation after movement exceeds 8 points. |
| Drawer mode | The same single main-row button toggles the existing temporary arrow drawer. |
| Release or cancellation | Stop all arrow timers; do not emit an additional tap. |

The existing optional drawer is retained because it is part of the current single-button design; it is not a newly introduced permanent arrow cluster. Previously user-configured directional keys in saved toolbar layouts are not destructively removed, but this feature adds none.

Joystick events must continue through the toolbar's modifier and terminal dispatch path. Preserve one-shot consumption **per emitted key**, as in the current toolbar: a one-shot modifier affects the next arrow event only; a locked modifier affects subsequent repeats. Do not silently change this to “one shot per whole drag.” [R3]

Add cancellation for target retirement, focus loss, scene deactivation, keyboard switching, and view reparenting wherever current integration does not already cover it. This is input-safety work, not a change to gesture feel.

## 5. Key and modifier semantics

### 5.1 Shared modifier state

Ctrl, Alt/Option, Command, and Shift use the existing inactive / one-shot / locked model. Preserve the 0.5-second double-tap threshold and current tap behavior. Esc is a momentary key and never a sticky modifier. [R4]

There must be one source of truth shared by body Shift, toolbar modifier buttons, keycap rendering, and dispatch. Do not maintain separate `shiftEnabled` booleans in several views. Extract the current modifier state into a small shared model or expose equivalent controlled access; a duplicate reducer with independently evolving behavior is not acceptable.

A one-shot is consumed by the next emitted terminal key or claimed shortcut. Repeated keys consume one-shots per emitted key, matching the toolbar. A mode/page button does not consume one-shots. Clear Modifiers resets all software modifiers without writing bytes.

A locked Shift retains the current toolbar's **Shift lock** semantics, including number/punctuation shifting. Do not label it “Caps Lock,” which would imply letter-only capitalization. A separate Caps Lock implementation is outside v1.

Switching keyboard implementation, leaving terminal focus, disconnecting, retiring a target, or deactivating the scene clears all software modifier state and tap-history timestamps. State must not leak into a password field, another pane, or a reconnect.

### 5.2 Text, control keys, and shortcuts

| Input | Required result |
| --- | --- |
| Letter/number/punctuation | One committed key action; no duplicated insertion through both text and key-event paths. |
| Space | Literal space. Holding it does not enter a second cursor-control mode. |
| Return | Existing terminal Return behavior and relevant overlay handling. No automatic LF substitution or draft buffering. |
| Backspace | Existing backward-delete key behavior; repeatable. Respect existing terminal configuration rather than globally forcing one byte. |
| Forward Delete | Distinct terminal Delete key, not a local text-edit operation. |
| Esc / Tab / Shift+Tab | Existing terminal and context-specific actions, including the native tmux gateway's Escape behavior. |
| Ctrl combinations | Existing binding dispatch first, then established terminal/control-character handling. Preserve local-shell Ctrl+C interruption. |
| Alt/Option combinations | Explicit terminal Alt semantics for the touch control, after local bindings. Do not invent Mac-style diacritic composition. Physical Option-side configuration stays unchanged. |
| Command combinations | Resolve configured local Shell keybindings, including sequences and explicitly configured send actions. Unclaimed Command chords are consumed without leaking an unmodified character; show accessible “No shortcut assigned” feedback. No global macOS commands are synthesized. |
| Paste | Invoke the existing paste action, preserving current confirmation, bracketed-paste, target binding, and input-gate behavior. |

The Command rule is an explicit v1 policy for the new replacement typing surface. It is not a change to physical-keyboard forwarding or a claim that terminal protocols can never represent a Super modifier.

Support multi-modifier combinations through the same normalization used by existing terminal input. The initial requirement is reliable tap-to-latch/tap-to-lock, not a new hold-to-chord gesture system. Ordinary two-thumb typing must work; simultaneous touches must never reorder already committed input or send twice.

### 5.3 Repeat and touch dispatch

Ordinary printable keys commit on a valid release. Dragging before release may retarget within the same typing row; leaving the keyboard cancels. A touch cannot activate a page switch and then “fall through” to a newly displayed key.

Backspace sends once on valid touch-down, then repeats after a proposed 0.4-second delay at 0.08-second intervals. Forward Delete may use the same policy. No accelerated word deletion. Return, Esc, page switches, Paste, and local app actions do not auto-repeat. Arrow timing remains the exact existing policy in section 4.

Any repeating action stops on release, touch cancellation, layout/page/mode change, responder change, window deactivation, target-generation change, or input rejection/backpressure. Do not run a second repeat timer on top of a control that already owns one.

When the terminal's supported protocol uses press/repeat/release events, keep the existing event lifecycle balanced. Cancellation may clean up the old engine's local key state, but must not send a stale release to a replacement connection.

## 6. Input routing and terminal correctness

### 6.1 One semantic dispatch path

Add a small **new** `TerminalKeyboardAction` representation and **new** `TerminalKeyboardDispatcher`, or an equivalently scoped extraction of existing handlers. Separate:

- Printable keys, carrying base identity, displayed text, and modifier context.
- Named terminal keys, such as Escape, Tab, Return, Backspace, Delete, Home, End, Page Up, and Page Down.
- Local actions, such as Paste, Clear Modifiers, and keyboard/page selection.

The dispatcher adapts into the existing `Swiftty.TerminalView` input and action paths. Verified integration points include `dispatchKeybindTrigger`, `executeKeybindAction`, `sendKeyViaSwiftty`, and `sendUserInput`; they are not interchangeable, and their current context-specific behavior must be retained. [R7]

Conceptual flow:

```text
Replacement body ─┐
                  ├─ shared software modifiers and action normalization
Existing toolbar ─┘       ├─ existing local binding/action handling
                          └─ existing terminal encoding and input admission
                                      └─ existing local / SSH / tmux destination
```

Do not make keyboard views know SSH clients, PTY file descriptors, tmux pane writers, or connection lifecycle internals.

### 6.2 Encoding rules

Do not use labels as wire data. Do not build a new hard-coded escape-sequence table in the view. New navigation buttons must use named terminal actions and the existing encoder, accounting for terminal modes and every keyboard protocol the pinned engine already supports.

Where the existing joystick reports an arrow as an escape-sequence-shaped string, retain its external delegate contract but normalize it through the existing arrow handler. Do not bypass that handler by directly appending the string to SSH.

Keep shifted key identity and text distinct. For Shift+1, an adapter must not both insert `!` and send a second shifted `1` event. Literal symbol keys need a consistent logical identity for shortcut matching, derived from the declared US layout; apply the existing shifted-symbol binding normalization once.

Do not send newly introduced special keys through `CustomKey.terminalData()` solely because that method exists. Existing user macros remain supported through their established dispatcher, but a new live navigation key needs terminal-mode-aware behavior.

No new keyboard protocol implementation is required. Any existing encoder limitation must be documented in tests or fixed at the shared encoder boundary, not patched with a contradictory view-local fallback.

### 6.3 Focus, ordering, and reconnect

Capture the target terminal/session identity and connection generation when an interaction begins. At dispatch and every repeat, validate that the original target is still active and eligible. Never resolve a fresh “currently selected terminal” for an old touch or timer.

The existing recovery gate rejects non-live and stale-generation input, bounds pending bytes, and disallows silent reconnect replay. The replacement must obey the same rules for typing, shortcuts that write bytes, repeat, accessibility actions, and paste. [R8]

Rejected typing must not be queued by the keyboard. Stop repeats, clear pending software modifiers, and use the existing recovery/backpressure indication. Local selection, search, and copy remain available under their existing policy. Compose is an explicit separate action, never a hidden fallback buffer for rejected keys.

Accepted events remain ordered with paste and macros. Do not start an independent asynchronous writer for each tap. Backpressure must not silently drop an earlier byte to make room for a later control key.

## 7. UIKit presentation and mode transitions

Keep keyboard preference separate from effective presentation. The former is a user setting; the latter includes hardware presence, hide intent, geometry, responder type, and platform support.

| Effective state | Primary input view | Accessory |
| --- | --- | --- |
| System software keyboard | `nil`, allowing UIKit's keyboard | Existing accessory, under existing visibility policy. |
| Shell software keyboard | **New** `ShellKeyboardInputView` | Existing accessory as a distinct instance/view. |
| Toolbar-only | Existing controller-owned toolbar/empty-input strategy | Existing controller policy; never duplicate the toolbar in both slots. |
| Explicitly hidden/pinned | Existing suppression strategy | Existing restore affordance and pin behavior. |
| Hardware keyboard, software hidden | Existing hardware/toolbar-only behavior | Existing accessory policy. |
| Unsupported responder or geometry | System or existing suppression, as appropriate | Existing behavior; do not override explicit hide intent. |

Extend `TerminalKeyboardAccessoryController` rather than replacing its state machine with an unconditional `inputView` override. Its existing code deliberately chooses different primary/accessory ownership in toolbar-only and detached-iPad cases. [R5]

For Shell mode, the body owns its bottom padding; the accessory above it must not also reserve bottom-screen safe-area padding as though it were toolbar-only. Keep one authoritative calculation of total keyboard occlusion. Do not subtract both a UIKit-reported combined keyboard frame and the accessory/body heights again.

Switching implementations must:

1. Cancel active body/toolbar gestures and repeat timers, and clear software modifier state.
2. Resolve any system marked-text composition through existing text-input lifecycle handling. Do not discard or force-commit an IME candidate by directly clearing marked text. Defer switching while composition cannot safely be resolved.
3. Update effective presentation and call `reloadInputViews()` on the actual terminal responder on the main actor.
4. Preserve the selected terminal, session, scrollback, and hide/pin intent; process geometry through the existing controller.

UIKit supports reloading custom primary and accessory input views on the first responder. [A1] Do not force resignation/reacquisition merely to show the new keyboard, and do not introduce a hidden `UITextField` to impersonate terminal input.

The System key changes the device preference to System and switches the current terminal. A later selection of **Use Shell Keyboard** switches it back. The menu is available from the terminal's keyboard/toolbar settings and its context menu, including when the toolbar has been collapsed or customized.

A transient fallback does not modify the stored preference. Reevaluate on the next safe presentation transition, not on every keystroke. Hardware attachment must not automatically reopen a keyboard the user pinned hidden.

## 8. Implementation structure

Favor a small body view, declarative layout data, shared state, and a thin adapter. Do not introduce a general-purpose keyboard framework or another process-wide singleton.

| Component | Change |
| --- | --- |
| **New** `shell/UI/Keyboard/ShellKeyboardInputView.swift` | `UIInputView` body container; intrinsic sizing, page hosting, accessibility, and lifecycle cancellation. |
| **New** `shell/UI/Keyboard/ShellKeyboardLayout.swift` | Stable key IDs, base/shifted output, explicit literal-symbol semantics, row definitions, and sizing calculations. |
| **New** `shell/UI/Keyboard/ShellKeyboardKeyView.swift` | Printable/action key rendering and touch lifecycle. Reuse existing styling and feedback tokens. |
| **New** `shell/UI/Keyboard/SoftwareKeyboardState.swift` | Small per-terminal state model: current page and shared software modifier state. No text buffer. |
| **New** `shell/UI/Terminal/TerminalKeyboardDispatcher.swift` | Typed adapter to existing terminal input/action handling; no transport ownership. |
| `TerminalKeyboardAccessoryController.swift` | Preference/effective-mode selection, body ownership, transitions, geometry, and hide/restore mode memory. |
| `KeyboardToolbarView.swift` | Shared modifier access; explicit System-versus-Shell Shift source; content-free logging; render the first-position keyboard visibility control with a keyboard glyph; preserve joystick, drawer, and arrow dispatch behavior. |
| `KeyboardModifierButton.swift` | Bind to shared state without changing tap/lock behavior. |
| `KeyboardArrowJoystickButton.swift` | Reuse. Only targeted lifecycle/accessibility additions supported by characterization tests. |
| `TerminalView+Keyboard.swift` and relevant text-input bridge | Reuse/extract entry points only as required; preserve local interrupt, bindings, sequences, and special context handling. |
| Existing settings definitions/UI | Typed device-only keyboard preference and discoverable mode menu. |
| `tests/` | Layout, modifier, dispatch, lifecycle, geometry, privacy, and UI tests. |

`SystemShiftReader` remains available for System mode. Shell mode must not query private/system keyboard internals to determine its own Shift state. Trusted physical modifier state comes from the existing input controller, with the same validity rules as current input.

Only the active responder presents an input view. Each terminal owns its state; a shared mutable keyboard view must not be reparented across two active windows. Destroying a terminal releases its keyboard callbacks and timers.

## 9. Settings, migration, and compatibility

Add one typed device-only preference, logically `softwareKeyboardMode = system | shell`. The exact settings namespace should follow the existing `SettingsStore` schema. Do not write a raw UserDefaults setting from the view or add a CloudKit record for this feature.

Apply the installation default from section 1 through a versioned migration. Determine an upgrade using existing durable installation/schema state, not an empty defaults read while protected data is unavailable. When classification is uncertain, remain in System until a safe migration or explicit user choice.

Persist neither active modifiers, Shift lock, key-repeat timers, current touches, input content, nor a recovery queue. Page selection is transient. System keyboard choice/language remains under UIKit's existing management.

Keep all saved toolbar keys, UUIDs, drawer rows, hidden-key choices, joystick mode, keybindings, and macros. Do not append navigation keys to a customized toolbar or reset the layout to make the new body work. Resetting the replacement preference must not reset toolbar customization.

The System fallback retains Apple's normal typing features. The new layout does not claim to reproduce prediction, swipe typing, international composition, emoji browsing, or dictation. The button is labeled System rather than pretending to be a system input-language globe.

## 10. Accessibility, privacy, and performance

### Accessibility

Each body key is an accessible element with a localized name, correct selected/locked state, and a stable test identifier. Distinguish Backspace from Forward Delete. Expose page and modifier state changes without speaking entered password characters through new custom announcements.

Keep the arrow control as one accessible element with named Move Up, Move Down, Move Left, and Move Right custom actions. These actions emit one directional event through the same dispatcher. Provide discoverable actions for changing joystick/drawer mode and opening its drawer; a timed long press cannot be the only accessible way to do this. UIKit provides accessibility custom-action support. [A2]

Provide accessible Lock/Unlock actions for modifiers so double-tap timing is not required with VoiceOver. Support Switch Control activation, Bold Text, Increase Contrast, Reduce Motion, and larger accessibility labels without making keys overlap. Never encode modifier state solely with color. Reuse existing input-click/haptic preferences.

### Privacy and safety

The replacement adds no network requests, microphone permission, keyboard extension entitlement, or text telemetry. Do not persist or log characters, composed strings, clipboard content, raw key payloads, or terminal output in keyboard diagnostics. Sensitive input can occur inside a terminal without a UIKit secure-field signal; treat every key as potentially sensitive.

Audit the existing toolbar debug logging before enabling ordinary typing through it. Allowed diagnostics are lifecycle/geometry state, non-content error categories, and aggregate timings; omit per-keystroke content and reconstructable content traces. Do not automatically read the clipboard to decorate the keyboard.

### Performance

Render and dispatch on the main actor without blocking disk or network work. Cache layout definitions and key views; do not rebuild the whole keyboard on each key press. Update only affected labels and modifier states.

Target a warm-keyboard p95 of less than one 60 Hz frame (16.7 ms) from accepted touch completion to local input-dispatch submission on the supported device test set. This excludes network transit and remote rendering and is not a claim about current performance. Geometry changes must not produce oscillating resize/input-view reload loops.

## 11. Acceptance and regression tests

Release requires automated tests plus simulator and physical-device validation. Existing keyboard behavior is the regression baseline; tests must not rely only on a new implementation comparing itself with itself.

| ID | Required result |
| --- | --- |
| K01 — scope | Terminal uses the chosen implementation; forms, search, secure fields, and compose retain System. Catalyst/visionOS/Watch behavior is unchanged. |
| K02 — inventory | All 95 printable ASCII characters are reachable. Symbol labels match output. No function-key layer or new arrow cluster exists. |
| K03 — plain typing | Type shell punctuation, paths, quotes, pipes, redirections, and spaces byte-exactly; no smart substitution, dropped character, or duplicate insertion. |
| K04 — modifiers | One-shot, double-tap lock, slow second-tap off, and explicit clear match the current behavior. Body/toolbar Shift remain synchronized. Shift+1 emits one `!`. |
| K05 — arrow compatibility | Existing `KeyboardArrowJoystickButton` remains visible in the toolbar in both Shell and System keyboard states. Preserve the 18-point dead zone, dominant-axis direction, 0.5/0.1-second repeat, 1.5-second mode switch, 8-point cancellation, and optional drawer. Replacing the visibility chevron with the keyboard glyph must not replace the joystick with chevrons or remove it. |
| K06 — arrow modifiers | One-shot Ctrl affects the next emitted arrow only; locked Ctrl affects repeats. No software-System Shift leaks into Shell mode. |
| K07 — terminal keys | Verify Tab, Backtab, Esc, Return, Backspace, Delete, Home/End, and Page Up/Down against reviewed fixtures and equivalent existing hardware paths. |
| K08 — terminal modes | Test normal/application cursor modes and every enhanced keyboard protocol supported by the pinned engine. Use a remote byte/event fixture and at least one interactive editor/TUI. |
| K09 — local special handling | Local-shell Ctrl+C interrupts correctly. Escape retains tmux gateway behavior. Configured keybindings and multi-key sequences run exactly once. |
| K10 — Command | Configured local shortcuts run; an unclaimed Command chord does not emit its plain letter. No operating-system shortcut injection occurs. |
| K11 — target safety | Change panes/tabs, close a session, or retire a connection during a held key/joystick drag. No further input reaches either the old or newly focused destination. |
| K12 — reconnect/backpressure | Offline input is visibly rejected, never replayed. A full input budget stops repeat. Accepted typing, paste, and macros remain ordered. |
| K13 — modes | Switch Shell → System → Shell repeatedly. Hide Shell with the first-position toolbar keyboard-glyph control and verify the same control restores Shell; hide System and verify it restores System. Repeat through pinned-hidden and toolbar-collapse flows, then attach/detach hardware. Hide/restore must not rewrite the saved keyboard preference. No duplicate input view, lost restore affordance, cross-terminal restore state, or stale modifier remains. |
| K14 — composition | Enter accented text, emoji, and CJK/Korean composition using System, then switch at a safe boundary. No marked text is discarded or accidentally submitted. |
| K15 — layout | Test portrait/landscape, the width matrix, iPad window resizing, safe areas, drawers, and transient fallback. No obscured Return/System key or double-counted occlusion. |
| K16 — touch/repeat | Two-thumb typing, rapid page changes, dragging off a key, backgrounding, and cancellation do not duplicate actions or leave timers alive. |
| K17 — accessibility | VoiceOver and Switch Control can type, invoke each arrow direction from the single control, lock/unlock modifiers, and switch to System. |
| K18 — migration | New install, existing install, uncertain/protected-data state, customized toolbar, and reset preserve the intended preference and existing customization. |
| K19 — privacy | Debug and release diagnostic capture contains none of a unique typed secret or clipboard payload. Check downstream toolbar/input logging too. |
| K20 — performance/lifecycle | Meet the dispatch target on the test set; no sustained allocation growth after repeated mode switches and terminal destruction. |

Baseline byte fixtures may include plain Tab `09`, Esc `1B`, and Backtab `1B 5B 5A` in the corresponding legacy modes. Backspace and navigation fixtures must name the configuration/mode rather than assume one sequence for every terminal. The implementation's own encoder is not the sole oracle: compare reviewed golden bytes and existing input behavior as well. [R7]

## 12. Delivery sequence

### Stage 1 — Characterize and isolate

Add regression tests for the existing joystick, modifier consumption, local Ctrl+C, keybindings, and hide/pin presentation. Establish shared software modifier access and an explicit modifier-source policy. Remove content-bearing logs from the affected dispatch paths. Gate the new mode until these tests pass.

### Stage 2 — Build and integrate the body

Implement layout data, keys, pages, and the primary `UIInputView`. Connect text and named keys to existing handlers. Integrate preference/effective-mode selection and the always-visible System escape hatch. Preserve the existing accessory as a separate view.

### Stage 3 — Validate lifecycle and compatibility

Exercise focus/generation binding, reconnect rejection, hardware keyboard coexistence, geometry, IME fallback, accessibility, and migration. Test local/SSH/tmux contexts on devices. Do not enable a geometry/platform combination whose input-view lifecycle has not passed.

### Stage 4 — Enable the documented defaults

Enable Shell for verified new installations and retain System for upgrades until explicit selection. Keep immediate rollback through the device preference. No schema migration may make System mode or saved toolbar layouts unusable.

## 13. Explicit non-goals

No F1–F12 implementation; no Fn layer; no separate numeric keypad; no permanent arrow cluster; no second arrow/space-bar trackpad gesture; no system-wide keyboard extension; no global Mac shortcut emulation; no new terminal protocol; no predictive text, swipe typing, custom IME, or built-in dictation; no arbitrary main-layout editor; no custom floating/split keyboard implementation; no SSH/tmux transport rewrite.

Existing hardware support, saved custom keys, and the optional arrow drawer are preserved, not removed as a consequence of these exclusions.

## 14. Source provenance

Source review establishes feasibility and the compatibility requirements above. It does not establish successful compilation, device behavior, or release performance.

All repository references below are pinned to:

```text
https://github.com/chr33s/shell/tree/e5d4465cd4f79d5b167216c2ecaaca13d7501101
```

Append the cited repository path to the equivalent `blob/<revision>/` source root to inspect that file. Source line ranges below refer to Swift source lines, not chat-tool JSON wrapper lines.

| Reference | Source and relevant evidence |
| --- | --- |
| R1 | `shell/UI/Keyboard/KeyboardAccessoryView.swift`: `UIInputView` wrapper and delegate/modifier callbacks. |
| R2 | `shell/UI/Keyboard/KeyboardArrowJoystickButton.swift`, full file: gesture constants, mode storage, repeat, touch cancellation, and direction dispatch. |
| R3 | `shell/UI/Keyboard/KeyboardToolbarView.swift`, approximately lines 980–end: arrow drawer, shared modifier states, one-shot clearing, forwarding, System Shift merge, and content-bearing debug logging. |
| R4 | `shell/UI/Keyboard/KeyboardModifierButton.swift`, full file: modifier state transitions, 0.5-second double-tap threshold, immediate Esc, and accessibility state. |
| R5 | `shell/UI/Terminal/TerminalKeyboardAccessoryController.swift`, especially lines 325–455: primary/accessory selection and callbacks; earlier sections define hide/pin and geometry state. |
| R6 | `shell/UI/Terminal/TerminalInputController.swift`: hardware/mod-tap state and IME-aware key command filtering. |
| R7 | `shell/UI/Terminal/TerminalView+Keyboard.swift`, especially lines 1700–2100 and 2170–end: Return/Escape/Tab behavior, keybinding dispatch, local control-character actions, and send paths. |
| R8 | `shell/Core/Terminal/Reconnect/RecoveryInputGate.swift`, full file: input-source categories, generation validation, admission/backpressure, retirement, and explicit memory-only drafts. |
| R9 | `shell/UI/Keyboard/KeyboardToolbarCustomization.swift` and `KeyboardToolbarManager.swift`: stable key identifiers, saved layouts/custom keys, and configurable drawers. |

**A1 — Apple, Custom Views for Data Input.** Supports a custom primary input view, a separate accessory, first-responder ownership, reloading, keyboard geometry notifications, and input clicks. This is Apple's archived programming guide; validate behavior against the repository's actual SDK and devices during implementation.

```text
https://developer.apple.com/library/archive/documentation/StringsTextFonts/Conceptual/TextAndWebiPhoneOS/InputViews/InputViews.html
```

**A2 — Apple, Accessibility for UIKit; Support Full Keyboard Access in your iOS app.** Accessibility customization and custom actions.

```text
https://developer.apple.com/documentation/uikit/accessibility-for-uikit
https://developer.apple.com/videos/play/wwdc2021/10120/
```
