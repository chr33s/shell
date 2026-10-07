import Foundation
import SwifttyCore

/// One tmux pane: its terminal, fed by `%output`, and the surface (if the
/// host made one) that renders it.
final class TmuxPane: @unchecked Sendable {
    let id: Int
    var window: Int
    let session: TerminalSession
    var width: Int
    var height: Int
    /// `%output` before the initial capture is already part of it.
    var initializing = true
    /// State from `list-panes`, applied after the capture.
    var state: TmuxViewer.PaneState?
    /// The surface currently rendering this pane (the host may briefly have two).
    weak var surface: Surface?
    /// History capture waiting for the visible-area capture.
    var pendingHistory: [[UInt8]]?
    var captureRequested = false
    var title = ""
    /// `#{pane_dead}`: the pane's process exited (`remain-on-exit`).
    var dead = false
    /// While initializing: a stand-in terminal fed the `%output` the capture
    /// already contains, so OSC 7501 status and support queries in it are
    /// not lost. Its records replace the pane's once the capture is applied.
    var standIn: TerminalSession?

    init(id: Int, window: Int, width: Int, height: Int, scrollbackRows: Int) {
        self.id = id
        self.window = window
        self.width = max(1, width)
        self.height = max(1, height)
        var config = SessionConfiguration()
        config.scrollbackLimitBytes = Int.max / 4
        config.scrollbackLimitRows = max(1, scrollbackRows)
        config.programStatusEnabled = true
        session = TerminalSession(columns: self.width, rows: self.height, configuration: config)
        Self.answerOnlyProgramStatus(session)
    }

    /// tmux answers the application's queries itself, except OSC 7501's
    /// support query, which it passes through.
    static func answerOnlyProgramStatus(_ session: TerminalSession) {
        session.mutateAsync {
            $0.discardsReplies = true
            $0.answersProgramStatusWhileDiscarding = true
        }
    }

    /// A terminal that only collects program status (see `standIn`),
    /// starting from `snapshot`. One row and no scrollback: it parses the
    /// stream for OSC 7501 and prompt marks, and its screen is thrown away,
    /// so laying text out costs next to nothing.
    static func makeStandIn(from snapshot: ProgramStatusSnapshot = .empty) -> TerminalSession {
        var config = SessionConfiguration()
        config.scrollbackLimitBytes = 0
        config.scrollbackLimitRows = 1
        config.programStatusEnabled = true
        let session = TerminalSession(columns: 80, rows: 1, configuration: config)
        answerOnlyProgramStatus(session)
        session.mutateAsync { $0.replaceProgramStatus(with: snapshot) }
        return session
    }
}

/// The tmux control-mode client for a gateway surface: parses the
/// `%`-protocol, keeps windows and panes, issues commands, and reports the
/// topology to the host as reconcile batches.
final class TmuxViewer: @unchecked Sendable {
    enum State: UInt8 { case none = 0, startup = 1, resync = 2, commandQueue = 3, defunct = 4 }

    struct PaneState {
        var cursorX = 0, cursorY = 0
        var alternate = false
        var cursorVisible = true
        var keypad = false, cursorKeys = false, wrap = true, insert = false
        var mouse = (any: false, button: false, standard: false, sgr: false, utf8: false)
        var scrollTop = 0, scrollBottom = 0
    }

    struct Window {
        var id: Int
        var index: Int
        var width: Int
        var height: Int
        var layout: TmuxLayout
        var zoomed: Bool
        var activePane: Int
        var name: String
    }

    enum CommandKind: UInt8 {
        case listWindows = 1, paneHistory = 2, paneVisible = 3, paneState = 4, version = 5
        case subscribeTitles = 6, clientSize = 8, user = 11, userQuery = 13, probe = 14, sessionInfo = 15
        case clientFlags = 16
    }

    struct Command {
        var kind: CommandKind
        var tag: UInt32 = 0
        var pane: Int = 0
        var line: [UInt8] = []
    }

    /// Bytes of command text allowed in flight: a PTY's input queue holds
    /// about 1 KB, and tmux reads it a line at a time.
    static let maxInFlightBytes = 768

    weak var gateway: Surface?
    private let queue = DispatchQueue(label: "swiftty.runtime.tmux", qos: .userInteractive)
    private var lines = TmuxProtocol.LineSplitter()

    // All below is owned by `queue`.
    private(set) var state = State.none
    private var inBlock = false
    private var blockHeader = (time: "", number: "")
    private var blockLines: [[UInt8]] = []
    private var sent: [Command] = []
    private var queued: [Command] = []
    private var inFlightBytes = 0
    private var windows: [Int: Window] = [:]
    private var panes: [Int: TmuxPane] = [:]
    private var activeWindow: Int?
    private var sessionID: Int?
    private var titles: [Int: String] = [:]
    /// How pane replies (OSC 7501's) reach tmux. `report`: the server holds
    /// support queries for this client (the `program-status` client flag),
    /// keeping later replies (DA) behind ours, and takes the answer as
    /// `refresh-client -r`. `keys`: `send-keys`. `unknown` until the flag
    /// is read back; replies wait meanwhile (bounded).
    private enum ReplyRoute { case unknown, report, keys }
    private var replyRoute = ReplyRoute.unknown
    private var pendingReplies: [(pane: Int, bytes: [UInt8])] = []
    static let maxPendingReplies = 32
    /// Stand-ins (see `TmuxPane.standIn`) for `%output` from panes not yet
    /// listed, adopted when the pane appears.
    private var orphanStandIns: [Int: TerminalSession] = [:]
    static let maxOrphanStandIns = 8
    private var clientSize: (columns: Int, rows: Int)?
    private var probeMarker: String?
    private var probeCount = 0
    private var pendingTopology: (windows: Bool, panes: Bool) = (false, false)
    private var listedWindows: [Window]?
    private var priorityWindow: Int?
    private var emittedTopology = false
    /// Bumped per control-mode stream; tags events so a host can ignore
    /// ones from a superseded stream.
    private(set) var generation: UInt64 = 0

    // Diagnostics.
    private var created = DispatchTime.now().uptimeNanoseconds
    private var lastOutput: UInt64 = 0, lastBlock: UInt64 = 0, lastNotification: UInt64 = 0, lastCommand: UInt64 = 0
    private var resyncStarted: UInt64 = 0
    private var totalBlocks: UInt64 = 0, totalNotifications: UInt64 = 0, totalOutput: UInt64 = 0, totalCommands: UInt64 = 0
    private var bytesIn: UInt64 = 0
    private var sentHighwater = 0

    init(gateway: Surface) {
        self.gateway = gateway
    }

    // MARK: Lifecycle

    /// `DCS 1000 p` seen. A live `tmux -CC` first answers its own attach
    /// command with one block; a resumed gateway waits for a probe instead.
    /// A control-mode stream began (`DCS 1000 p`). On a viewer whose
    /// previous stream died without `%exit`, nothing from it is trusted: its
    /// pending replies are failed and every pane is recaptured.
    func start() {
        queue.async { [self] in
            if state != .none, state != .defunct {
                for pane in panes.values {
                    pane.initializing = true
                    pane.captureRequested = false
                    pane.pendingHistory = nil
                }
            }
            reset()
            state = .startup
        }
    }

    /// Re-enters control mode on a gateway restored mid-session.
    func resume(priority window: Int?) {
        queue.async { [self] in
            priorityWindow = window
            switch state {
            case .resync:
                sendProbe()
            case .startup, .none, .defunct:
                reset()
                beginResync()
            case .commandQueue:
                beginResync()
            }
        }
    }

    private func reset() {
        generation &+= 1
        replyRoute = .unknown
        pendingReplies = []
        lines.reset()
        inBlock = false
        blockLines = []
        failPendingQueries()
        sent = []
        queued = []
        inFlightBytes = 0
        created = DispatchTime.now().uptimeNanoseconds
        resyncStarted = 0
    }

    func receive(_ data: [UInt8]) {
        queue.async { [self] in
            bytesIn &+= UInt64(data.count)
            lines.push(data) { line(Array($0)) }
        }
    }

    /// The DCS ended (`%exit` and ST, or a forced exit).
    func controlModeEnded() {
        queue.async { [self] in
            guard state != .defunct else { return }
            finish()
        }
    }

    func close() {
        queue.sync {
            state = .defunct
            failPendingQueries()
        }
    }

    /// Ends control mode: report an empty topology so the host prunes.
    private func finish() {
        state = .defunct
        failPendingQueries()
        sent = []
        queued = []
        inFlightBytes = 0
        if emittedTopology {
            emit([.syncBegin, .pruneAbsent(windows: [], panes: []), .syncEnd])
        }
        windows = [:]
        panes = [:]
        orphanStandIns = [:]
        emittedTopology = false
    }

    private func failPendingQueries() {
        for command in sent + queued where command.kind == .userQuery {
            respond(tag: command.tag, error: true, body: [])
        }
        sent.removeAll { $0.kind == .userQuery }
        queued.removeAll { $0.kind == .userQuery }
    }

    // MARK: Lines

    private static let trace = ProcessInfo.processInfo.environment["SWIFTTY_TMUX_TRACE"] != nil

    private func line(_ bytes: [UInt8]) {
        if Self.trace {
            FileHandle.standardError.write(Data(("tmux< " + String(decoding: bytes.prefix(200), as: UTF8.self) + "\n").utf8))
        }
        if inBlock {
            if let end = blockEnd(bytes) {
                inBlock = false
                let body = blockLines
                blockLines = []
                blockCompleted(error: end, body: body)
            } else {
                blockLines.append(bytes)
            }
            return
        }
        guard bytes.first == 0x25 else { // '%'
            strayLine(bytes)
            return
        }
        let text = String(decoding: bytes, as: UTF8.self)
        if text.hasPrefix("%begin ") {
            let parts = text.split(separator: " ")
            blockHeader = (parts.count > 1 ? String(parts[1]) : "", parts.count > 2 ? String(parts[2]) : "")
            inBlock = true
            blockLines = []
            return
        }
        lastNotification = now
        totalNotifications &+= 1
        notification(text, raw: bytes)
    }

    /// `%end`/`%error` matching the open `%begin`: returns whether it is an error.
    private func blockEnd(_ bytes: [UInt8]) -> Bool? {
        guard bytes.first == 0x25 else { return nil }
        let text = String(decoding: bytes.prefix(64), as: UTF8.self)
        for (prefix, isError) in [("%end ", false), ("%error ", true)] where text.hasPrefix(prefix) {
            let parts = text.split(separator: " ")
            if parts.count >= 3, parts[1] == blockHeader.time, parts[2] == blockHeader.number {
                return isError
            }
        }
        return nil
    }

    /// Output that is not control-mode protocol: a dead shell echoing our
    /// probe (resume against a session that has no tmux) ends control mode.
    private func strayLine(_ bytes: [UInt8]) {
        guard state == .resync, !bytes.isEmpty else { return }
        forceExitLocked()
    }

    private var now: UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    // MARK: Blocks

    private func blockCompleted(error: Bool, body: [[UInt8]]) {
        lastBlock = now
        totalBlocks &+= 1
        switch state {
        case .startup:
            // The attach command's own reply.
            state = .commandQueue
            synchronize(recapture: true)
            return
        case .resync:
            let text = body.map { String(decoding: $0, as: UTF8.self) }
            guard let marker = probeMarker, text.contains(where: { $0.contains(marker) }) else { return }
            probeMarker = nil
            sent = []
            queued = []
            inFlightBytes = 0
            state = .commandQueue
            resyncStarted = 0
            synchronize(recapture: true)
            return
        case .none, .defunct:
            return
        case .commandQueue:
            break
        }
        guard !sent.isEmpty else { return } // a block for a command sent by someone else
        let command = sent.removeFirst()
        inFlightBytes -= command.line.count
        handleReply(command, error: error, body: body)
        pump()
    }

    private func handleReply(_ command: Command, error: Bool, body: [[UInt8]]) {
        switch command.kind {
        case .user, .clientSize, .subscribeTitles, .probe, .version:
            break
        case .clientFlags:
            // A server without the flag ignores it, so read back what stuck.
            let flags = body.first.map { String(decoding: $0, as: UTF8.self) } ?? ""
            replyRoute = !error && flags.split(separator: ",").contains("program-status") ? .report : .keys
            let waiting = pendingReplies
            pendingReplies = []
            for reply in waiting {
                sendReply(pane: reply.pane, reply.bytes)
            }
        case .userQuery:
            let joined = body.map { $0 }.joined(separator: [0x0A])
            respond(tag: command.tag, error: error, body: Array(joined))
        case .sessionInfo:
            guard !error, let line = body.first else { return }
            let parts = String(decoding: line, as: UTF8.self).split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            if let first = parts.first, let id = TmuxProtocol.id(first, prefix: "$") {
                sessionChanged(id: id, name: parts.count > 1 ? String(parts[1]) : "")
            }
        case .listWindows:
            guard !error else { return }
            listedWindows = body.compactMap { parseWindow(String(decoding: $0, as: UTF8.self)) }
        case .paneState:
            guard !error else { return }
            applyPaneList(body.map { String(decoding: $0, as: UTF8.self) })
        case .paneHistory:
            guard let pane = panes[command.pane] else { return }
            pane.pendingHistory = error ? [] : body
        case .paneVisible:
            guard let pane = panes[command.pane] else { return }
            applyCapture(pane, visible: error ? [] : body)
        }
    }

    // MARK: Synchronization

    /// Re-reads windows and panes; with `recapture`, every pane's content too.
    private func synchronize(recapture: Bool) {
        if recapture {
            for pane in panes.values {
                pane.initializing = true
            }
        }
        send(.sessionInfo, "display-message -p \"#{session_id} #{session_name}\"")
        send(.user, "refresh-client -f program-status")
        send(.clientFlags, "display-message -p \"#{client_flags}\"")
        send(.subscribeTitles, "refresh-client -B \"shell-title:@*:#{pane_title}\"")
        send(.subscribeTitles, "refresh-client -B \"shell-dead:%*:#{pane_dead}\"")
        if let size = clientSize {
            send(.clientSize, "refresh-client -C \(size.columns)x\(size.rows)")
        }
        refreshTopology()
    }

    private func refreshTopology() {
        send(.listWindows, "list-windows -F \"#{window_id} #{window_index} #{window_width} #{window_height} #{window_layout} #{window_zoomed_flag} #{window_active} #{window_name}\"")
        send(.paneState, "list-panes -s -F \"" + [
            "#{pane_id}", "#{window_id}", "#{pane_active}", "#{pane_width}", "#{pane_height}", "#{cursor_x}",
            "#{cursor_y}", "#{alternate_on}", "#{cursor_flag}", "#{keypad_cursor_flag}", "#{keypad_flag}",
            "#{wrap_flag}", "#{insert_flag}", "#{mouse_any_flag}", "#{mouse_button_flag}", "#{mouse_standard_flag}",
            "#{mouse_sgr_flag}", "#{mouse_utf8_flag}", "#{scroll_region_upper}", "#{scroll_region_lower}", "#{pane_title}"
        ].joined(separator: " ") + "\"")
    }

    private func parseWindow(_ line: String) -> Window? {
        let f = line.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: false)
        guard f.count >= 7, let id = TmuxProtocol.id(f[0], prefix: "@"), let index = Int(f[1]),
              let w = Int(f[2]), let h = Int(f[3]), let layout = TmuxLayout.parse(String(f[4])) else { return nil }
        if f[6] == "1" {
            activeWindow = id
        }
        return Window(id: id, index: index, width: w, height: h, layout: layout, zoomed: f[5] == "1",
                      activePane: layout.panes.first?.paneID ?? 0, name: f.count > 7 ? String(f[7]) : "")
    }

    /// `list-panes` reply: completes a topology refresh started by `list-windows`.
    private func applyPaneList(_ lines: [String]) {
        guard let listed = listedWindows else { return }
        listedWindows = nil
        var newWindows: [Int: Window] = [:]
        for w in listed {
            newWindows[w.id] = w
        }
        var seen = Set<Int>()
        var toCapture: [TmuxPane] = []
        let scrollback = gateway?.config.scrollbackLines ?? 10000
        for line in lines {
            let f = line.split(separator: " ", maxSplits: 20, omittingEmptySubsequences: false)
            guard f.count >= 20, let id = TmuxProtocol.id(f[0], prefix: "%"), let window = TmuxProtocol.id(f[1], prefix: "@"),
                  newWindows[window] != nil, let w = Int(f[3]), let h = Int(f[4]) else { continue }
            seen.insert(id)
            if f[2] == "1" {
                newWindows[window]?.activePane = id
            }
            var st = PaneState()
            st.cursorX = Int(f[5]) ?? 0
            st.cursorY = Int(f[6]) ?? 0
            st.alternate = f[7] == "1"
            st.cursorVisible = f[8] != "0"
            st.cursorKeys = f[9] == "1"
            st.keypad = f[10] == "1"
            st.wrap = f[11] != "0"
            st.insert = f[12] == "1"
            st.mouse = (f[13] == "1", f[14] == "1", f[15] == "1", f[16] == "1", f[17] == "1")
            st.scrollTop = Int(f[18]) ?? 0
            st.scrollBottom = Int(f[19]) ?? max(0, h - 1)
            let pane: TmuxPane
            if let existing = panes[id] {
                pane = existing
                pane.window = window
                if existing.width != w || existing.height != h {
                    resize(pane, columns: w, rows: h)
                }
            } else {
                pane = TmuxPane(id: id, window: window, width: w, height: h, scrollbackRows: scrollback)
                pane.session.onTerminalReply = { [weak self] bytes in self?.reply(pane: id, bytes) }
                pane.standIn = orphanStandIns.removeValue(forKey: id)
                panes[id] = pane
            }
            if f.count > 20 {
                pane.title = String(f[20])
            }
            pane.state = st
            if pane.initializing, !pane.captureRequested {
                toCapture.append(pane)
            }
        }
        for id in panes.keys where !seen.contains(id) {
            panes[id] = nil
        }
        orphanStandIns = [:]
        windows = newWindows
        emitTopology()
        // The window the host asked for first, then the active one; the
        // rest follow and stay interruptible between commands.
        let first = priorityWindow ?? activeWindow
        if !toCapture.isEmpty {
            priorityWindow = nil
        }
        let ordered = toCapture.filter { $0.window == first } + toCapture.filter { $0.window != first }
        for pane in ordered {
            pane.captureRequested = true
            send(.paneHistory, "capture-pane -p -e -J -S - -E -1 -t %\(pane.id)", pane: pane.id)
            send(.paneVisible, "capture-pane -p -e -t %\(pane.id)", pane: pane.id)
        }
    }

    private func resize(_ pane: TmuxPane, columns: Int, rows: Int) {
        pane.width = max(1, columns)
        pane.height = max(1, rows)
        let (c, r) = (pane.width, pane.height)
        pane.session.mutateAsync { $0.resize(columns: c, rows: r) }
    }

    /// Replays captured history and screen into the pane, then its cursor
    /// and modes, then lets `%output` through.
    private func applyCapture(_ pane: TmuxPane, visible: [[UInt8]]) {
        let history = pane.pendingHistory ?? []
        pane.pendingHistory = nil
        pane.captureRequested = false
        let st = pane.state ?? PaneState()
        // RIS, start clean, but keep program status: the pane's program
        // never retracted it. The stand-in's records cover what arrived
        // while the capture was taken.
        pane.session.mutateAsync { $0.resetPreservingProgramStatus() }
        if let standIn = pane.standIn {
            pane.standIn = nil
            let status = standIn.programStatusSnapshot
            pane.session.mutateAsync { $0.replaceProgramStatus(with: status) }
        }
        var bytes: [UInt8] = Array("\u{1B}[H\u{1B}[2J".utf8)
        // tmux trims trailing blank lines of the visible capture; keep exactly
        // `height` screen lines so history scrolls off correctly.
        var screen = visible
        if screen.count > pane.height {
            screen.removeFirst(screen.count - pane.height)
        }
        let all = history + screen
        for (i, line) in all.enumerated() {
            bytes += line
            bytes += Array("\u{1B}[0m".utf8)
            if i < all.count - 1 {
                bytes += [0x0D, 0x0A]
            }
        }
        // Pad so the screen holds `height` rows with history above it.
        let missing = pane.height - screen.count
        if missing > 0, !history.isEmpty || !screen.isEmpty {
            bytes += Array(repeating: [0x0D, 0x0A], count: missing).flatMap { $0 }
        }
        if st.alternate {
            bytes += Array("\u{1B}[?1049h\u{1B}[H\u{1B}[2J".utf8)
            for (i, line) in screen.enumerated() {
                bytes += Array("\u{1B}[\(i + 1);1H".utf8) + line + Array("\u{1B}[0m".utf8)
            }
        }
        var modes = ""
        modes += st.cursorVisible ? "\u{1B}[?25h" : "\u{1B}[?25l"
        modes += st.cursorKeys ? "\u{1B}[?1h" : "\u{1B}[?1l"
        modes += st.keypad ? "\u{1B}=" : "\u{1B}>"
        modes += st.wrap ? "\u{1B}[?7h" : "\u{1B}[?7l"
        modes += st.insert ? "\u{1B}[4h" : "\u{1B}[4l"
        if st.mouse.any { modes += "\u{1B}[?1003h" } else if st.mouse.button { modes += "\u{1B}[?1002h" } else if st.mouse.standard { modes += "\u{1B}[?1000h" }
        if st.mouse.sgr { modes += "\u{1B}[?1006h" }
        if st.mouse.utf8 { modes += "\u{1B}[?1005h" }
        if st.scrollTop > 0 || st.scrollBottom < pane.height - 1 {
            modes += "\u{1B}[\(st.scrollTop + 1);\(st.scrollBottom + 1)r"
        }
        modes += "\u{1B}[\(st.cursorY + 1);\(st.cursorX + 1)H"
        bytes += Array(modes.utf8)
        pane.session.receive(bytes)
        pane.initializing = false
        paneSynced(pane.id)
    }

    /// Reports that `pane` now shows tmux's state (visible-pane sync).
    private func paneSynced(_ id: Int) {
        guard let gateway else { return }
        let generation = generation
        gateway.app.post(gateway, tag: SWIFTTY_ACTION_TMUX_PANE_SYNCED) {
            $0.tmux_pane_synced = swiftty_action_tmux_pane_synced_s(pane_id: UInt64(id), generation: generation)
        }
    }

    // MARK: Notifications

    private func notification(_ text: String, raw: [UInt8]) {
        let parts = text.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        let name = parts[0]
        switch name {
        case "%output":
            guard parts.count >= 2, let id = TmuxProtocol.id(parts[1], prefix: "%") else { return }
            // Data starts after "%output %N ".
            let offset = 8 + parts[1].utf8.count + 1
            output(pane: id, raw.count > offset ? raw[offset...] : [])
        case "%extended-output":
            // %extended-output %N age ... : data
            guard parts.count >= 2, let id = TmuxProtocol.id(parts[1], prefix: "%"),
                  let colon = raw.firstIndex(of: 0x3A).map({ $0 + 2 }), colon <= raw.count else { return }
            output(pane: id, raw[colon...])
        case "%layout-change":
            let f = text.split(separator: " ")
            guard f.count >= 3, let window = TmuxProtocol.id(f[1], prefix: "@"), let layout = TmuxLayout.parse(String(f[2])) else { return }
            let zoomed = f.count >= 5 && f[4].contains("Z")
            if var w = windows[window] {
                w.layout = layout
                w.zoomed = zoomed
                windows[window] = w
                let known = layout.panes.allSatisfy { panes[$0.paneID] != nil }
                for leaf in layout.panes {
                    if let pane = panes[leaf.paneID], pane.width != leaf.width || pane.height != leaf.height {
                        resize(pane, columns: leaf.width, rows: leaf.height)
                    }
                }
                if known {
                    emitTopology()
                    return
                }
            }
            refreshTopology()
        case "%window-add", "%window-close", "%unlinked-window-close", "%unlinked-window-add", "%window-pane-changed",
             "%session-window-changed":
            if name == "%session-window-changed", parts.count >= 3, let w = TmuxProtocol.id(parts[2].split(separator: " ").first ?? "", prefix: "@") {
                activeWindow = w
            }
            if name == "%window-pane-changed", parts.count >= 3, let w = TmuxProtocol.id(parts[1], prefix: "@"),
               let p = TmuxProtocol.id(parts[2], prefix: "%"), windows[w] != nil {
                windows[w]?.activePane = p
                emitTopology()
                return
            }
            refreshTopology()
        case "%window-renamed":
            guard parts.count >= 3, let window = TmuxProtocol.id(parts[1], prefix: "@") else { return }
            windows[window]?.name = String(parts[2])
            if titles[window] == nil {
                emit([.setTabTitle(window: window, title: String(parts[2]))])
            }
        case "%subscription-changed":
            // %subscription-changed shell-title $S @W idx %P : value
            if parts.count >= 3, parts[1] == "shell-dead" {
                paneDeadChanged(parts[2])
                return
            }
            guard parts.count >= 3, parts[1] == "shell-title" else { return }
            let rest = parts[2]
            let fields = rest.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: false)
            guard fields.count >= 2, let window = TmuxProtocol.id(fields[1], prefix: "@"),
                  let colon = rest.range(of: " : ") else { return }
            let title = String(rest[colon.upperBound...])
            guard titles[window] != title else { return }
            titles[window] = title
            emit([.setTabTitle(window: window, title: title)])
        case "%session-changed":
            guard parts.count >= 2, let id = TmuxProtocol.id(parts[1], prefix: "$") else { return }
            sessionChanged(id: id, name: parts.count > 2 ? String(parts[2]) : "")
            titles = [:]
            // A different session: every pane is new.
            for pane in panes.values { pane.initializing = true }
            synchronize(recapture: true)
        case "%session-renamed":
            if let id = sessionID {
                sessionChanged(id: id, name: parts.count > 1 ? String(text.dropFirst("%session-renamed ".count)) : "")
            }
        case "%sessions-changed":
            gateway.map { g in g.app.post(g, tag: SWIFTTY_ACTION_TMUX_SESSIONS_CHANGED) }
        case "%exit":
            finish()
        default:
            break // %pane-mode-changed, %client-*, %pause, %continue, %message, ...
        }
    }

    private func output(pane id: Int, _ data: ArraySlice<UInt8>) {
        lastOutput = now
        totalOutput &+= 1
        guard let pane = panes[id] else {
            orphanOutput(pane: id, data)
            return
        }
        guard !pane.initializing else {
            // Already in the capture, but its program status is not.
            if pane.standIn == nil {
                pane.standIn = TmuxPane.makeStandIn(from: pane.session.programStatusSnapshot)
                pane.standIn?.onTerminalReply = { [weak self] bytes in self?.reply(pane: id, bytes) }
            }
            pane.standIn?.receive(TmuxProtocol.decodeOutput(data))
            return
        }
        pane.session.receive(TmuxProtocol.decodeOutput(data))
    }

    /// `%output` from a pane `list-panes` has not reported yet.
    private func orphanOutput(pane id: Int, _ data: ArraySlice<UInt8>) {
        guard state == .commandQueue else { return }
        if orphanStandIns[id] == nil {
            guard orphanStandIns.count < Self.maxOrphanStandIns else { return }
            let standIn = TmuxPane.makeStandIn()
            standIn.onTerminalReply = { [weak self] bytes in self?.reply(pane: id, bytes) }
            orphanStandIns[id] = standIn
        }
        orphanStandIns[id]?.receive(TmuxProtocol.decodeOutput(data))
    }

    /// `shell-dead $S @W idx %P : 0|1`: a `remain-on-exit` pane's process
    /// exited (or was respawned). Exit drops transient program status.
    private func paneDeadChanged(_ rest: Substring) {
        let fields = rest.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: false)
        guard fields.count >= 4, let id = TmuxProtocol.id(fields[3], prefix: "%"), let pane = panes[id],
              let colon = rest.range(of: " : ") else { return }
        let dead = rest[colon.upperBound...] == "1"
        guard dead != pane.dead else { return }
        pane.dead = dead
        if dead {
            pane.session.programExited()
            pane.standIn?.programExited()
        }
    }

    private func sessionChanged(id: Int, name: String) {
        sessionID = id
        guard let gateway else { return }
        let generation = generation
        gateway.app.post(gateway) { send in
            let bytes = Array(name.utf8)
            bytes.withUnsafeBufferPointer { buf in
                var action = swiftty_action_s()
                action.tag = SWIFTTY_ACTION_TMUX_SESSION_CHANGED
                action.action.tmux_session_changed = swiftty_action_tmux_session_changed_s(
                    session_id: UInt64(id), name: buf.baseAddress, name_len: UInt(buf.count),
                    generation: generation,
                )
                send(action)
            }
        }
    }

    // MARK: Reconcile

    private func emitTopology() {
        let sorted = windows.values.sorted { $0.index < $1.index }.prefix(128)
        var ops: [TmuxOp] = [.syncBegin]
        var paneIDs: [Int] = []
        for w in sorted {
            ops.append(.ensureWindow(window: w.id, width: w.width, height: w.height, index: w.index))
        }
        for w in sorted {
            for leaf in w.layout.panes {
                guard let pane = panes[leaf.paneID], paneIDs.count < 512 else { continue }
                paneIDs.append(pane.id)
                ops.append(.ensurePane(window: w.id, pane: pane))
            }
        }
        for w in sorted {
            ops.append(.setLayout(window: w.id, layout: w.layout, zoomedPane: w.zoomed ? w.activePane : nil))
        }
        if let active = activeWindow, let w = windows[active] {
            ops.append(.setFocus(window: active, pane: w.activePane))
        }
        ops.append(.pruneAbsent(windows: sorted.map(\.id), panes: paneIDs))
        ops.append(.syncEnd)
        emittedTopology = true
        emit(ops)
        for w in sorted where titles[w.id] == nil && !w.name.isEmpty {
            emit([.setTabTitle(window: w.id, title: w.name)])
        }
    }

    private func emit(_ ops: [TmuxOp]) {
        guard let gateway else { return }
        let payload = TmuxReconcilePayload(ops: ops, generation: generation)
        gateway.app.post(gateway, tag: SWIFTTY_ACTION_TMUX_RECONCILE) {
            // Retained only once delivery is certain: the host frees it with
            // swiftty_tmux_reconcile_free.
            $0.tmux_reconcile = Unmanaged.passRetained(payload).toOpaque()
        }
    }

    private func respond(tag: UInt32, error: Bool, body: [UInt8]) {
        guard let gateway, tag != 0 else { return }
        gateway.app.post(gateway) { send in
            body.withUnsafeBufferPointer { buf in
                var action = swiftty_action_s()
                action.tag = SWIFTTY_ACTION_TMUX_COMMAND_RESPONSE
                action.action.tmux_command_response = swiftty_action_tmux_command_response_s(
                    tag: tag, is_err: error, body: buf.isEmpty ? nil : buf.baseAddress, body_len: UInt(buf.count),
                )
                send(action)
            }
        }
    }

    // MARK: Commands

    private func send(_ kind: CommandKind, _ command: String, tag: UInt32 = 0, pane: Int = 0) {
        guard state == .commandQueue else { return }
        let command = Command(kind: kind, tag: tag, pane: pane, line: Array((command + "\n").utf8))
        // Host commands (typing, splits) go ahead of background captures, but
        // never between a pane's history and visible captures, which must
        // see the same pane state.
        if kind == .user || kind == .userQuery,
           let i = queued.firstIndex(where: { $0.kind == .paneHistory }) {
            queued.insert(command, at: i)
        } else {
            queued.append(command)
        }
        pump()
    }

    /// Writes queued commands while the in-flight budget allows (always at
    /// least one, however long).
    private func pump() {
        guard let gateway else { return }
        while let next = queued.first, sent.isEmpty || inFlightBytes + next.line.count <= Self.maxInFlightBytes {
            queued.removeFirst()
            sent.append(next)
            inFlightBytes += next.line.count
            sentHighwater = max(sentHighwater, sent.count + queued.count)
            lastCommand = now
            totalCommands &+= 1
            if Self.trace {
                FileHandle.standardError.write(Data("tmux> [\(next.kind)] \(String(decoding: next.line.prefix(120), as: UTF8.self))".utf8))
            }
            gateway.writeToTransport(next.line)
        }
    }

    private func beginResync() {
        state = .resync
        resyncStarted = now
        probeCount = 0
        sendProbe()
    }

    private func sendProbe() {
        guard state == .resync, let gateway else { return }
        probeCount += 1
        let marker = "SHELL-RESYNC-\(UInt32.random(in: 1 ... .max))-\(probeCount)"
        probeMarker = marker
        lastCommand = now
        gateway.writeToTransport(Array("display-message -p \"\(marker)\"\n".utf8))
    }

    private func forceExitLocked() {
        finish()
        // Return the gateway's parser to ground: CAN aborts control mode
        // wherever the stream stopped (ST ends it only at a line start).
        gateway?.session.receive([0x18])
    }

    /// Host API: a command whose reply is reported with `tag` (0: none).
    func command(_ text: String, tag: UInt32?) {
        queue.async { [self] in
            guard state == .commandQueue else {
                if let tag { respond(tag: tag, error: true, body: []) }
                return
            }
            let trimmed = text.hasSuffix("\n") ? String(text.dropLast()) : text
            send(tag == nil ? .user : .userQuery, trimmed, tag: tag ?? 0)
        }
    }

    func setClientSize(columns: Int, rows: Int) {
        queue.async { [self] in
            let size = (max(10, columns), max(3, rows))
            guard clientSize.map({ $0 != size }) ?? true else { return }
            clientSize = size
            send(.clientSize, "refresh-client -C \(size.0)x\(size.1)")
        }
    }

    func detach() {
        queue.async { [self] in
            send(.user, "detach-client")
        }
    }

    func forceExit() {
        queue.async { [self] in forceExitLocked() }
    }

    func recover() {
        queue.async { [self] in
            guard state == .commandQueue || state == .resync else { return }
            beginResync()
        }
    }

    /// Discards pane contents and recaptures everything.
    func resetPanes(priority window: Int?) {
        queue.async { [self] in
            priorityWindow = window
            for pane in panes.values {
                pane.initializing = true
                pane.captureRequested = false
            }
            if state == .commandQueue {
                synchronize(recapture: true)
            } else if state == .resync {
                sendProbe()
            }
        }
    }

    func reprobe() {
        queue.async { [self] in
            if state == .resync { sendProbe() }
        }
    }

    func flushDeferred() {
        // Pane writes are never deferred; topology is re-sent on change.
    }

    var isActive: Bool {
        queue.sync { state == .startup || state == .resync || state == .commandQueue }
    }

    func pane(id: Int) -> TmuxPane? {
        queue.sync { panes[id] }
    }

    /// A reply the pane's terminal generated (only OSC 7501's: tmux answers
    /// the rest). To a server holding the query, as the report it waits
    /// for; otherwise as input to the pane.
    func reply(pane: Int, _ bytes: [UInt8]) {
        queue.async { [self] in
            guard state == .commandQueue else { return }
            sendReply(pane: pane, bytes)
        }
    }

    private func sendReply(pane: Int, _ bytes: [UInt8]) {
        switch replyRoute {
        case .unknown:
            if pendingReplies.count < Self.maxPendingReplies {
                pendingReplies.append((pane, bytes))
            }
        case .report:
            let report = TmuxProtocol.quote("%\(pane):" + String(decoding: bytes, as: UTF8.self))
            send(.user, "refresh-client -r \(report)")
        case .keys:
            sendKeysLocked(pane: pane, bytes)
        }
    }

    /// Input typed into a pane surface: `send-keys -H`, chunked.
    func sendKeys(pane: Int, _ bytes: [UInt8]) {
        queue.async { [self] in
            guard state == .commandQueue else { return }
            sendKeysLocked(pane: pane, bytes)
        }
    }

    private func sendKeysLocked(pane: Int, _ bytes: [UInt8]) {
        var i = 0
        while i < bytes.count {
            let chunk = bytes[i ..< min(i + 256, bytes.count)]
            let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
            send(.user, "send-keys -t %\(pane) -H \(hex)")
            i += 256
        }
    }

    func debugSnapshot(_ out: inout swiftty_tmux_debug_snapshot_s) {
        queue.sync {
            let t = now
            func age(_ v: UInt64) -> UInt64 { v == 0 ? 0 : (t - min(v, t)) / 1_000_000 }
            out = swiftty_tmux_debug_snapshot_s()
            out.abi_version = 2
            out.viewer_state = state.rawValue
            out.parser_state = state == .none || state == .defunct ? 0 : inBlock ? 3 : 1
            out.tmux_active = state == .defunct || state == .none ? 0 : 1
            out.resume_pending = state == .resync ? 1 : 0
            out.command_in_flight = sent.isEmpty ? 0 : 1
            out.in_flight_cmd_kind = sent.first?.kind.rawValue ?? 0
            out.command_queue_depth = UInt32(max(0, sent.count - 1) + queued.count)
            out.command_queue_highwater = UInt32(sentHighwater)
            out.sent_fifo_depth = UInt32(sent.count)
            out.sent_fifo_highwater = UInt32(sentHighwater)
            out.session_id = UInt32(clamping: sessionID ?? 0)
            out.window_count = UInt32(windows.count)
            out.pane_count = UInt32(panes.count)
            out.uninitialized_pane_count = UInt32(panes.values.filter(\.initializing).count)
            out.ms_since_last_output = age(lastOutput)
            out.ms_since_last_block = age(lastBlock)
            out.ms_since_last_command_sent = age(lastCommand)
            out.ms_since_last_notification = age(lastNotification)
            out.ms_since_viewer_created = age(created)
            out.resync_age_ms = age(resyncStarted)
            out.total_notifications = totalNotifications
            out.total_blocks = totalBlocks
            out.total_output_events = totalOutput
            out.total_commands_sent = totalCommands
            out.gw_read_enter_bytes = bytesIn
            out.gw_read_done_bytes = bytesIn
            out.gw_tmux_put_bytes = bytesIn
        }
    }
}
