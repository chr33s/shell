# Native macOS: assessment and plan

Status: Option B complete as of 2026-09-05. Phases 0 and 2-5 as planned; phase 1
took the plan's documented alternative to native NSWindow tabs (see below).
Original assessment written against commit `6185571`.

## Implementation checkpoint

- Added `ShellMacSupport`, a native macOS bundle target, and a shared Objective-C
  `MacBridge` protocol. The bundle is built and embedded only for Catalyst and loaded
  at launch; iOS builds do not depend on it.
- Migrated the window configuration, titlebar controls, drag views, drag-frame polling,
  fullscreen command, and terminal scale detection in the Phase 0 files to typed
  AppKit calls. Scene claims remain in Catalyst to preserve existing reopen logic.
  Scale detection now uses the terminal's own scene instead of the first window.
- Replaced runtime-created titlebar classes with real `NSView` subclasses and tracking
  areas. Removed the optional undocumented `setTitlebarColor:` call. Theme content
  continues to show through the transparent titlebar.
- Gated two remaining general-purpose impact feedback paths out of Catalyst.
  Selection loupe/handles and status-bar handling were already excluded. The keyboard
  tracker also owns physical modifier handling, so deleting it wholesale is incorrect.
- Removed the AppKit reflection outside the Phase 0 files: the window background
  material (liquid-glass backdrop and the NSVisualEffectView blur) moved out of
  `GhosttyApp.swift` into `ShellMacSupport/NativeWindowMaterial.swift` behind four
  bridge calls, and `AppearanceManager` now sets `NSApp.appearance` through the
  bridge instead of `NSClassFromString`. The two global blur sweeps collapsed into
  one, since the per-window pass already decides between the CGS and
  NSVisualEffectView paths. The only reflection left in the bundle is ghostty's own
  private `_cornerRadius` read and `NSGlassEffectView.style`, neither of which is in
  the SDK headers. `GhosttyApp.themeBackgroundNSColor` had no callers and was
  deleted with the rest of the block.
- Phase 2 is done: the `UIMenuBuilder` rail is gone and `AppCommands` owns the menu
  bar, with `MacApplicationCommands` supplying About / Close Tab / Close Window /
  tab navigation through the bridge.
- **Baseline repaired.** The Catalyst app compiles again: the deleted
  `HelperConnection` / `FDReceiver` were replaced by `MacLocalShellManager` +
  the bundle's `NativeShellProcess`, so the PTY is created natively with no helper
  process or socket service. The last compile error (`UIMenuElement.attributes`,
  which only leaf elements have) is fixed in `MacTerminalEvents`.
- Validation on 2026-09-05: Catalyst build clean (0 errors), iOS Simulator build
  clean, `ShellMacSupport` builds fat arm64 + x86_64, and the standalone smoke test
  passes — now also covering blur idempotence and per-window isolation, the glass
  deferral rule, appearance override, the Dock menu's no-delegate path, a real
  fork/exec through `PTYSpawn.c` (output read back off the duplicated master, and
  a failed exec surfacing as a thrown error rather than a live process), and the
  Text Input Services entry points. None of this is interactive testing. The AppKit
  titlebar, the glass backdrop, native scroll, the context menu, the Dock menu, and
  multi-window restore across a quit and relaunch all still need to be exercised in
  a running Catalyst app. Two menu-bar behaviours also need a running app to
  settle: whether File now shows both "Close Tab" (⌘W, from `MacApplicationCommands`)
  and SwiftUI's own "Close", and whether a Settings window left open at quit is
  restored by UIKit on the next launch.
- Review follow-ups applied after the checkpoint above:
  - The Text Input Services calls in `NativeKeyboard` no longer force-unwrap
    `TISCreateInputSourceList` / `TISCopyCurrent*`, which return NULL rather than
    an empty list when TIS is unavailable — the code they replaced guarded, and
    the `as!` would have crashed the app from the input-source switcher.
  - `takeConnectingWindow` and `bindConnectingScene` refuse the visor id. Visor
    detection is heuristic, so a missed detection could stamp "visor" onto an
    ordinary scene's restoration activity and let a regular window claim the
    visor's tabs — the case the deleted `getPendingStateExactly` guarded.
  - `MacLocalShellManager` only treats a configured shell as a path when it is
    absolute. `execve` does no PATH lookup, so a bare `fish` used to fail to
    launch; non-absolute commands now go through `/bin/sh -c`, which does.
  - `routeAutomationURL` addresses the `ssh://` notification to one scene (the one
    it arrived on, else the focused terminal window). It is delivered to every
    `MainView`, so an untargeted post connected every open window; `ShellApp`'s
    duplicate untargeted post is now iOS-only for the same reason.
  - The Settings window is a `UIWindowScene` with no `MainView` in it, so
    `preferredRegularScene()` and `shouldHandleNotification`'s window count skip
    it via the new `CatalystSceneDelegate.isTerminalScene`. Otherwise opening
    Settings made the sole terminal window start refusing untargeted commands,
    and Dock-menu actions could land in a window that observes nothing.
  - `NativeShellProcess.terminate` no longer signals the child twice, and the
    context-menu path no longer force-unwraps `contentView`.
- Phase 5 is complete.
  - **Per-window restoration.** `NSWindow.restorationClass` is the wrong hook here:
    AppKit's window restoration is not the mechanism under Catalyst, where UIKit
    scene sessions own it. The equivalent is `stateRestorationActivity(for:)`, which
    `CatalystSceneDelegate` now implements, stamping each scene with its window id.
    That also fixes the root cause of the app-global behaviour: UIKit only persists
    a scene's `@SceneStorage` when the delegate returns an activity, so
    `MainView.sceneWindowId` was being regenerated every launch and every window
    fell through to `getPendingState`'s "first unclaimed entry in file order"
    fallback.
    Restoration is now id-based end to end and the order heuristics are gone.
    `willConnectTo` binds each connecting scene to exactly one saved window —
    from the id in its state-restoration activity, or the id the app passed to
    `requestSceneSessionActivation` for a window the system did not recreate — and
    that one id drives both the pre-size and the later claim, so they can no longer
    disagree. `WindowStateManager` lost `getPendingStateExactly`,
    `nextPendingRestoreFrame` and its two independent file-order cursors; the
    remaining assignment is the unavoidable one, for the launch scene that carries
    no identity at all, and it happens once at connect rather than twice.
  - **Dock menu.** New Window, New Local Shell, and the five most recently used SSH
    profiles, built in `MacDockMenu` and rendered by the bundle. AppKit reads the
    Dock menu from `applicationDockMenu(_:)` on the application delegate, which under
    Catalyst is UIKit's shim, so the bundle adds that one method to the shim's class
    with `class_addMethod` — the same interposition the STANDALONE
    `applicationShouldHandleReopen:` path already uses, and it declines rather than
    overrides if UIKit ever implements the method itself. A Dock click with no window
    open parks its action and `MainView.handleOnAppear` drains it once the new
    window's observers exist, so there is no timer racing window creation.
  - **Open Recent.** File > Open Recent lists saved SSH profiles, most recently used
    first, from the `lastUsedAt` the profiles already record. It is a `View` inside
    the command group so `@Observable` tracking rebuilds it as profiles are used.
    There is deliberately no "Clear Menu": the order comes from usage stats the user
    manages in Settings, and clearing here would silently discard them.
  - Close Tab / Close Window were already in `MacApplicationCommands`.
- Removed the paths that assumed an older app.
  - The bundle's deployment target moved from macOS 15 to 26 (the Catalyst app
    already required 26), so `NSGlassEffectView` is a real type: the glass backdrop
    dropped its `NSClassFromString` construction, its `setValue(forKey:)` style and
    corner-radius writes, and the "unavailable, fall through to the standard
    material" branch in `GhosttyApp`.
  - The local-shell path lost the last traces of the deleted helper process:
    `MacLocalShellManager.ensureAvailable()` (an `async` wrapper around a constant),
    the `checkHelperAndCreateInitialTab` warm-up dance and the comments explaining
    why the first window took a slower path than the rest. Availability is now just
    "is the support bundle loaded", checked synchronously.
- Also moved the last AppKit reflection in `CatalystAppDelegate`'s window handling to
  the bridge (`activate`, `setAlpha`). The reflection that remains in that file is
  about NSWorkspace, NSRunningApplication, the reopen interposer and the Continuity
  pasteboard — different subsystems, not window furniture.
- Phase 1 took the branch this plan already specifies: **native `NSWindow` tabs were
  not adopted**, and the Window menu gained the affordances they would have brought.
  The reason is stronger than the "deliberate product choice" the plan anticipated.
  AppKit tabs are one window per tab, but a tab here is not a window's worth of
  content: `TabModel` owns a `SplitTree` of panes, tabs carry group identity derived
  from the remote host/domain/network, a tmux gateway tab owns child window tabs that
  must move with it, and Tab Exposé and grouped mode operate across the tabs of one
  window. One scene per tab cannot express any of that, so adopting native tabs would
  mean deleting tab groups, tmux window tabs, splits-within-a-tab and Tab Exposé —
  a product decision, not a refactor. Note this makes the plan's stated main risk
  (ghostty's `CAMetalLayer` on tear-off) moot: the incompatibility is in the tab
  model, so there is nothing to prototype.
  What shipped instead, in the Window menu and backed by the existing tab model:
  - The system-standard tab chords ⌃⇥ / ⌃⇧⇥, alongside the rebindable
    Previous/Next Tab actions that stay in the Tabs menu.
  - **Move Tab to New Window**, reusing the same staged transfer the tab bar's own
    tear-off already performs.
  - **Merge All Windows**, which walks the other windows' tab models and moves their
    tabs in through `TabTransferCoordinator`; each emptied source window then closes
    itself through the existing transfer path.
  The dynamic window list the plan mentions was not added: Catalyst's Window menu
  already lists the app's open windows, so it would only duplicate it.

The standalone smoke test can be run after building the `ShellMacSupport` target:

```sh
xcrun swiftc Shared/MacBridge.swift tests/MacSupportSmoke.swift -o /tmp/shell-mac-support-smoke
/tmp/shell-mac-support-smoke .derivedData/Build/Products/Debug/ShellMacSupport.bundle
```


## Where the Mac build stands today

The Mac build is **Mac Catalyst**, not native macOS:

```
Configuration/Base.xcconfig
  SUPPORTED_PLATFORMS      = iphoneos iphonesimulator xros xrsimulator
  SUPPORTS_MACCATALYST     = YES
  TARGETED_DEVICE_FAMILY   = 1,2,7
  IPHONEOS_DEPLOYMENT_TARGET = 18.0
```

`shell/Info.plist` does not set `UIDesignRequiresCompatibility`, so the Catalyst build
should already run the Mac idiom rather than scaled-iPad. Confirm via the target's
General tab ("Optimize Interface for Mac") — if that is off, turning it on changes
control metrics app-wide for one checkbox.

Scale of the UIKit dependency:

- 350 Swift files; 100 `import UIKit`
- 450 `#if targetEnvironment(macCatalyst)` sites across ~100 files
- 16 `UIViewRepresentable` / `UIViewControllerRepresentable` bridges

Raw API usage: `UIKeyCommand` 313, `UIApplication` 229, `UIView` 185, `UIColor` 80,
`UIWindowScene` 58, `UIScrollView` 56, `UIMenu` 52, `UIFont` 35, `UIDevice` 30,
`UITextInput` 28, `UIPasteboard` 23, `UIGestureRecognizer` 18.

---

# Option A — Full native macOS port

A real port, not a build-setting flip.

## Hard blockers

**1. libghostty has no native macOS slice.**
`ghosttykit-rootshell/Package.swift` declares `platforms: [.iOS(.v17), .macCatalyst(.v17), .visionOS(.v1)]`
and ships prebuilt xcframeworks. Catalyst binaries cannot link into a native macOS
(`SDKROOT = macosx`) target. GhosttyKit must be rebuilt with a `macos-arm64_x86_64`
slice and the xcframework + checksum republished. `scripts/build-framework.sh`
currently emits only those three platforms. Nothing else proceeds until this is done.

**2. UIKit surface area.** See counts above. The UI layer is effectively a rewrite.

## What must be rewritten

| Area | Now | Native macOS |
|---|---|---|
| Terminal view | `TerminalView: UIView` + `UIScrollView`, gestures, `UITextInput` (`shell/UI/Terminal/`) | `NSView`, `NSScrollView` or manual scroll, `NSTextInputClient`, `NSGestureRecognizer`, tracking areas |
| Key handling | `UIKeyCommand` x313, `pressesBegan` (`KeybindCommandGenerator`, `KeybindManager`) | `NSEvent` local monitors / `performKeyEquivalent`, real `NSMenu` items |
| Windows / scenes | `UIWindowScene`, `UISceneSession`, `CatalystAppDelegate`, `WindowAccessor`, `WindowSizeManager`, `TransparencyManager`, `TabWindowTransfer` | `NSWindow`, `NSWindowController`, native tabbing (`NSWindow.tabbingMode`), `NSToolbar` |
| Menus | `UIMenuBuilder` in `AppCommands.swift` + `CatalystAppDelegate` | SwiftUI `Commands` / `NSMenu` |
| Cursor / pointer | `CatalystCursorCoordinator`, `UIPointerInteraction` | `NSCursor` + tracking areas |
| Clipboard | `UIPasteboard` (23) | `NSPasteboard` |
| On-screen keyboard | `KeyboardAccessoryView`, `KeyboardTracker`, `KeyboardGeometryMonitor`, `InputSourceCarbonShim`, `CatalystKeyboardLayout` | Delete — no software keyboard on Mac |
| Colors / fonts | `UIColor` / `UIFont` | `NSColor` / `NSFont` |
| Loupe / selection handles | `SelectionLoupe`, `SelectionHandleView` | Delete; mouse selection |
| Haptics, status bar, orientations | `UIImpactFeedback`, `StatusBarStyleController`, orientation Info.plist keys | Delete |

## What ports cleanly

- **Core is platform-neutral**: SSH (Citadel/NIO), tmux control mode, CloudKit sync,
  Keychain / Secure Enclave, the `spec.md` model layer, scrollback persistence.
- **Local shell is already right**: `CatalystLocalShellSession` uses a real PTY master
  FD + `DispatchSourceRead` — exactly the macOS approach. Gate it on `os(macOS)`
  instead of `targetEnvironment(macCatalyst)`.
- **`ios_system` and all of `Core/Shell/`** (the in-process interpreter) can be dropped
  on macOS; exec a real `/bin/zsh`.
- **Metal rendering**: ghostty creates its own `CAMetalLayer`, which attaches to
  `NSView.layer` the same way (`shell/UI/Terminal/TerminalView.swift:3219`).
- **Entitlements** mostly carry over. The open question is app sandbox +
  fork/exec of a login shell: keep the sandbox and accept the restrictions, or drop
  `ENABLE_APP_SANDBOX` for direct distribution (the App Store then requires the
  sandbox and a temporary-exception dance).

## Build config changes

```
SDKROOT                  = macosx     # new target
MACOSX_DEPLOYMENT_TARGET = 15.0
SUPPORTED_PLATFORMS      = macosx     # for the Mac target
SUPPORTS_MACCATALYST     = NO
TARGETED_DEVICE_FAMILY   = 1,2,7      # unchanged on the iOS target
```

Also: drop the `EXCLUDED_SOURCE_FILE_NAMES[sdk=macosx*]` ios_system rule, remove the
`INFOPLIST_KEY_UI*` orientation / launch-screen keys from the Mac target, and add a
second app target to `shell.xcodeproj` (currently a single application target) sharing
`Core/` + `Features/` with a separate UI tree.

## Shape

Split into `UI/` (UIKit, iOS/visionOS) and a new `UIMac/` (AppKit), with `Core/` and
`Features/` shared and the 450 `macCatalyst` conditionals collapsed behind a
`PlatformDetection`-style protocol boundary. The AppKit layer is a from-scratch
rewrite of roughly 60 files; the terminal view, key routing, and window/tab management
are the bulk of it. Multi-month, and blocked on the GhosttyKit rebuild.

---

# Option B — Cheaper middle path (recommended)

Stay on Catalyst and deepen the AppKit bridge.

**Premise:** the two expensive halves are already done — a working Catalyst build with
a real PTY, and ~15 files reaching into AppKit. What is missing is that the reach is
ad-hoc: KVC string reflection (`value(forKey: "windows")`) scattered across 6 files,
`UIMenuBuilder` menus, a custom-drawn tab bar. This buys "feels native" without a
rewrite or a new libghostty slice.

## Phase 0 — One typed AppKit bridge (the enabler)

Everything else depends on this. `NSApplication` / `NSWindow` are unavailable to
Catalyst at compile time, so the code does string-key reflection in:

- `shell/UI/Window/WindowAccessor.swift` (1628 lines)
- `shell/UI/Window/WindowDragObserver.swift:131`
- `shell/UI/Shared/DraggableTabBar.swift:64`
- `shell/UI/Terminal/TerminalView+Gestures.swift:3590`
- `shell/UI/Shell/MainViewModifiers.swift:89`

Replace with a **Mac bundle plugin**: a separate `macos` target
(`ShellMacSupport.bundle`) built against the real macOS SDK, embedded in the Catalyst
app and `dlopen`'d at launch. It gets genuine `NSApplication` / `NSWindow` / `NSMenu`
types. The Catalyst side talks to it through one protocol:

```swift
// Shared/MacBridge.swift — compiled into both targets
@objc public protocol MacBridge: NSObjectProtocol {
    func window(forSceneSessionID: String) -> NSObject?
    func setTitlebarStyle(_ style: Int, forWindow: NSObject)
    func beginWindowDrag(forWindow: NSObject)
    func setTabbingIdentifier(_ id: String, forWindow: NSObject)
    // ...
}
```

Loader is ~40 lines (`Bundle(path:)?.principalClass`). This removes the reflection,
gives compile-time checking, and removes the App Store review risk of KVC into
undeclared AppKit surface. Each later phase becomes a method on the bundle rather than
another reflection site.

Cost: ~1-2 days for bundle + loader, then a mechanical sweep of the ~35 call sites.

## Phase 1 — Native window tabs (biggest visual payoff)

`DraggableTabBar.swift` + `TabWindowTransfer.swift` + `MainViewTabDrag.swift`
reimplement in SwiftUI what `NSWindow` does natively. Through the bridge, set
`tabbingIdentifier` / `tabbingMode = .preferred` on each scene's `NSWindow` and let
AppKit own the tab bar, drag-to-reorder, tear-off, and merge-all-windows.

Win: tabs draggable between windows and to the Dock, Cmd-Shift-[ / ] for free,
"Merge All Windows" in the Window menu. Cost: loses the custom styling in
`MainView+TabBarStyling.swift`, and the ghostty surface must re-parent correctly on
tear-off. Keep the existing tab bar behind a preference for iPad parity.

Skip this phase if the custom tab appearance is a deliberate product choice — in that
case add only native tab keyboard and Window-menu integration.

## Phase 2 — Menu bar cleanup

`CatalystAppDelegate.buildMenu(with:)` (lines 940-1400, ~460 lines of `UIMenuBuilder`)
coexists awkwardly with `AppCommands.swift`'s SwiftUI `Commands`, gated on macOS 26
via `MenuShortcutState.menuRailOwnsShortcuts`. Two rails for the same menus is a
maintenance tax and the source of the duplicate-item comments in the code.

With a macOS 26 floor for the Mac build, delete the `UIMenuBuilder` path entirely and
let `AppCommands` own it. Add through the bridge what `UIMenuBuilder` cannot express:
dynamic Window menu items, Services submenu, and proper `NSMenuItem` state
(checkmarks, mixed state) for toggles.

## Phase 3 — Mouse, cursor, scroll

- `CatalystCursorCoordinator` is already good — extend it over the terminal grid
  (I-beam over text, arrow over the scrollbar region).
- Real `NSTrackingArea`-driven hover through the bridge instead of `UIPointerInteraction`.
- Scroll: `TerminalScrollView` / `TerminalView+Scroll.swift` use `UIScrollView`
  inertia. Route `NSEvent.scrollingDeltaY` + `hasPreciseScrollingDeltas` from the
  bridge so trackpad scroll matches other Mac terminals and momentum stops at
  scrollback bounds instead of rubber-banding.
- Right-click: native `NSMenu` context menus rather than `UIMenu`'s long-press-derived
  presentation.

## Phase 4 — Delete the iPad-isms on Mac

Pure subtraction, no new code. Highest ratio of "feels less like an iPad app" to
effort in the whole plan, and independent of Phase 0 — can ship first.

| File | Action on Catalyst |
|---|---|
| `SelectionLoupe.swift`, `SelectionHandleView.swift` | `#if !targetEnvironment(macCatalyst)` — no touch selection |
| `KeyboardAccessoryView`, `TerminalKeyboardAccessoryController`, `KeyboardToolbarOrnament` | compile out; no software keyboard |
| `KeyboardGeometryMonitor`, `KeyboardTracker` | compile out |
| `UIImpactFeedback` (5 sites) | compile out |
| `StatusBarStyleController` | compile out |
| `TerminalView+Gestures.swift` pinch / long-press | gate to touch idiom |

## Phase 5 — Mac window furniture

- Separate **Settings window** (`Settings` scene / Cmd-,) instead of the in-window
  `showSettings` sheet in `MainView+Notifications.swift`.
- `NSWindow.restorationClass` wired to the existing `WindowStateManager` so windows
  restore per-window, not app-globally.
- Standard New Window / Close Window semantics, Dock menu, Open Recent for SSH profiles.

## What Option B does not fix

- **Key handling stays `UIKeyCommand`** (313 sites). Catalyst translates these to menu
  key equivalents; dead keys, some Option-composed characters, and non-Latin input
  methods stay slightly off versus AppKit's `NSTextInputClient`. This is the residual
  "not quite native" that only Option A removes.
- **Text input stays `UITextInput`**, so macOS input-method behavior (Japanese/Korean
  candidate windows — see `TerminalView+KoreanComposition.swift`) remains an
  approximation.
- Accessibility (VoiceOver on Mac) stays UIKit-derived.

## Effort and sequencing

Phase 0 is the prerequisite for 1-3 and 5; Phase 4 is independent and can ship first.

| Phase | Estimate |
|---|---|
| 0 — AppKit bridge | ~1 week |
| 1 — Native tabs | 1-2 weeks |
| 2 — Menu bar | 1-2 weeks |
| 3 — Mouse/cursor/scroll | 1-2 weeks |
| 4 — Delete iPad-isms | ~2 days |
| 5 — Window furniture | ~1 week |

Roughly 4-6 weeks total, versus a multi-month AppKit rewrite that also blocks on
rebuilding GhosttyKit.

**Main risk:** Phase 1 — native tabs interacting with ghostty's `CAMetalLayer` on
window tear-off. Prototype that specific interaction before committing to the phase.
