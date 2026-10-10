import Foundation
@testable import SwifttyKit
import SwifttyCore
import Synchronization
import Testing

/// OSC 7501 through the embedder API: Swiftty keeps the records, SwifttyKit
/// exposes them losslessly and keeps terminal replies apart from typing.
struct ProgramStatusBridgeTests {
    let esc = "\u{1B}"

    private func status(_ body: String) -> String {
        "\(esc)]7501;\(body)\(esc)\\"
    }

    private func base64(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
    }

    private func statusActions() -> Int {
        Recorder.shared.all.count(where: { $0 == .other(SWIFTTY_ACTION_PROGRAM_STATUS.rawValue) })
    }

    @Test func snapshotPreservesEveryField() {
        Recorder.shared.clear()
        let app = makeApp()
        let s = makeSurface(app)
        defer { swiftty_surface_free(s); swiftty_app_free(app) }
        write(swiftty_surface_get_slave_fd(s), status("state=blocked:id=deploy/approve:kind=permission:progress=42:app=agent:title=\(base64("Apply changes?")):msg=\(base64("3 files"))"))
        #expect(waitFor { swiftty_surface_program_status(s).records.count == 1 })
        let snapshot = swiftty_surface_program_status(s)
        let record = snapshot.records[0]
        #expect(record.id == "deploy/approve")
        #expect(record.state == .blocked)
        #expect(record.kind == .permission)
        #expect(record.progress == 42)
        #expect(record.app == "agent")
        #expect(record.title == "Apply changes?")
        #expect(record.message == "3 files")
        #expect(record.revision == snapshot.revision && snapshot.revision > 0)
        // Announced as an action, without cell damage being needed.
        #expect(Recorder.shared.wait(timeout: 2) { _ in statusActions() >= 1 })
    }

    @Test func supportQueryRepliesOnTheReplyPipeOnly() {
        let app = makeApp()
        let s = makeSurface(app)
        defer { swiftty_surface_free(s); swiftty_app_free(app) }
        write(swiftty_surface_get_slave_fd(s), "\(esc)]7501;?\(esc)\\")
        #expect(drain(swiftty_surface_reply_read_fd(s)) == "\(esc)]7501;?\(esc)\\")
        // Never with encoded input, so the host cannot mistake it for typing.
        #expect(drain(swiftty_surface_response_read_fd(s), timeout: 0.2) == "")
        // Replies keep their order with one another.
        write(swiftty_surface_get_slave_fd(s), "\(esc)[5n\(esc)]7501;?\u{07}\(esc)[c")
        let replies = drain(swiftty_surface_reply_read_fd(s))
        #expect(replies.hasPrefix("\(esc)[0n\(esc)]7501;?\u{07}\(esc)[?"))
    }

    @Test func programExitIsOrderedAfterWrittenOutput() {
        let app = makeApp()
        let s = makeSurface(app)
        defer { swiftty_surface_free(s); swiftty_app_free(app) }
        // Written immediately before the exit: still applied first, then
        // the exit drops the transient record and keeps the result.
        write(swiftty_surface_get_slave_fd(s), status("state=working:id=a") + status("state=done:id=b"))
        swiftty_surface_program_exited(s)
        #expect(waitFor { swiftty_surface_program_status(s).records.map(\.id) == ["b"] })
        #expect(swiftty_surface_program_status(s).records.first?.state == .done)
    }

    @Test func promptStartClearsTransientStatus() {
        let app = makeApp()
        let s = makeSurface(app)
        defer { swiftty_surface_free(s); swiftty_app_free(app) }
        let fd = swiftty_surface_get_slave_fd(s)
        write(fd, "\(esc)]133;A\u{07}$ \(esc)]133;C\u{07}" + status("state=working"))
        #expect(waitFor { swiftty_surface_program_status(s).records.count == 1 })
        // The next prompt after the command is a command boundary.
        write(fd, "\(esc)]133;D;0\u{07}\(esc)]133;A\u{07}$ ")
        #expect(waitFor { swiftty_surface_program_status(s).records.isEmpty })
    }
}

/// OSC 7501 through native tmux control mode: pane-addressed routing,
/// surface independence, capture, process exit and support detection. Part
/// of the serialized tmux suite: they share the action recorder.
extension TmuxIntegrationTests {
    private var esc: String { "\u{1B}" }

    private func allReconciles() -> [[String]] {
        Recorder.shared.all.compactMap { if case let .reconcile(ops) = $0 { ops } else { nil } }
    }

    /// Attaches, returning the first window's pane id.
    private func attach(_ gateway: swiftty_surface_t) throws -> UInt {
        #expect(Recorder.shared.wait { _ in allReconciles().contains { $0.contains { $0.hasPrefix("pane @") } } })
        let batch = try #require(allReconciles().last { $0.first == "begin" })
        let line = try #require(batch.first { $0.hasPrefix("pane @") })
        return UInt(line.split(separator: " ")[2].dropFirst())!
    }

    private func pane(_ gateway: swiftty_surface_t, _ id: UInt) -> TmuxPane? {
        Surface.from(gateway)?.tmux?.pane(id: Int(id))
    }

    private func records(_ gateway: swiftty_surface_t, _ id: UInt) -> [String: ProgramStatusState] {
        guard let pane = pane(gateway, id) else { return [:] }
        return Dictionary(uniqueKeysWithValues: pane.session.programStatusSnapshot.records.map { ($0.id, $0.state) })
    }

    /// A shell script in a fresh directory, its body given the directory;
    /// returns (script, directory).
    private func script(_ body: (URL) -> String) throws -> (String, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("swiftty-osc7501-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("run.sh")
        try body(dir).write(to: path, atomically: true, encoding: .utf8)
        return (path.path, dir)
    }

    @Test(.enabled(if: TmuxBridge.tmuxPath != nil))
    func reportsReachTheirPaneWithoutASurface() throws {
        Recorder.shared.clear()
        let app = makeApp()
        let gateway = makeSurface(app)
        defer { swiftty_surface_free(gateway); swiftty_app_free(app) }
        swiftty_surface_set_size(gateway, 800, 400)
        let bridge = try #require(TmuxBridge(gateway: gateway))
        defer { bridge.stop() }
        let first = try attach(gateway)
        #expect(waitFor { pane(gateway, first)?.initializing == false })

        // A second, hidden window; no surface exists for either pane.
        let second = try #require(UInt(bridge.tmux("new-window", "-d", "-P", "-F", "#{pane_id}", "/bin/sh").dropFirst()))
        #expect(waitFor { pane(gateway, second)?.initializing == false })
        bridge.tmux("send-keys", "-t", "%\(second)", "printf '\\033]7501;state=working:progress=7\\033\\\\'", "Enter")
        #expect(waitFor { records(gateway, second) == ["": .working] })
        #expect(records(gateway, first).isEmpty)

        // Capture reconstruction (RIS internally) keeps the records.
        let before = pane(gateway, second)?.session.programStatusSnapshot
        let syncs = Recorder.shared.all.count { if case .paneSynced = $0 { true } else { false } }
        swiftty_surface_tmux_reset(gateway)
        #expect(Recorder.shared.wait { $0.count { if case .paneSynced = $0 { true } else { false } } >= syncs + 2 })
        #expect(pane(gateway, second)?.session.programStatusSnapshot.records == before?.records)

        // A surface attached later starts from the pane's records.
        var cfg = swiftty_surface_config_new()
        let surface = try #require(swiftty_surface_new_tmux_pane(app, gateway, 0, second, nil, nil, &cfg))
        defer { swiftty_surface_free(surface) }
        #expect(swiftty_surface_program_status(surface).records.first?.progress == 7)
    }

    @Test(.enabled(if: TmuxBridge.tmuxPath != nil))
    func supportQueryIsAnsweredToTheOriginatingPane() throws {
        Recorder.shared.clear()
        let app = makeApp()
        let gateway = makeSurface(app)
        defer { swiftty_surface_free(gateway); swiftty_app_free(app) }
        swiftty_surface_set_size(gateway, 800, 400)
        let bridge = try #require(TmuxBridge(gateway: gateway))
        defer { bridge.stop() }
        let first = try attach(gateway)
        #expect(waitFor { pane(gateway, first)?.initializing == false })
        let other = try #require(UInt(bridge.tmux("split-window", "-d", "-P", "-F", "#{pane_id}", "-t", "%\(first)", "/bin/sh").dropFirst()))
        #expect(waitFor { pane(gateway, other)?.initializing == false })

        // Raw reads until a 2 s gap; the query alone.
        let (path, dir) = try script { dir in """
        stty -icanon -echo min 0 time 20
        printf '\\033]7501;?\\033\\\\'
        cat > "\(dir.path)/in.raw"
        stty sane
        touch "\(dir.path)/done"
        """ }
        defer { try? FileManager.default.removeItem(at: dir) }
        bridge.tmux("send-keys", "-t", "%\(first)", "sh \(path)", "Enter")
        #expect(waitFor(timeout: 15) { FileManager.default.fileExists(atPath: dir.appendingPathComponent("done").path) })
        let received = try String(decoding: Data(contentsOf: dir.appendingPathComponent("in.raw")), as: UTF8.self)
        #expect(received == "\(esc)]7501;?\(esc)\\")
        // Pane replies stay off the gateway's input and other panes.
        #expect(records(gateway, other).isEmpty)
    }

    /// Release gate (spec §17): a producer sends the OSC 7501 query with a
    /// standard query and treats OSC 7501 as unsupported if the standard
    /// reply comes first. A tmux with the `program-status` client flag holds
    /// later replies (DA) until Shell answers with `refresh-client -r`, so
    /// detection works; stock tmux answers DA at once, before the reply
    /// can make its round trip through Shell.
    @Test(.enabled(if: TmuxBridge.tmuxPath != nil))
    func combinedSupportProbeOrdering() throws {
        Recorder.shared.clear()
        let app = makeApp()
        let gateway = makeSurface(app)
        defer { swiftty_surface_free(gateway); swiftty_app_free(app) }
        swiftty_surface_set_size(gateway, 800, 400)
        let bridge = try #require(TmuxBridge(gateway: gateway))
        defer { bridge.stop() }
        let first = try attach(gateway)
        #expect(waitFor { pane(gateway, first)?.initializing == false })
        // A server with the program-status client flag holds the query.
        let holds = bridge.tmux("list-clients", "-F", "#{client_flags}").contains("program-status")

        let (path, dir) = try script { dir in """
        stty -icanon -echo min 0 time 20
        printf '\\033]7501;?\\033\\\\\\033[c'
        cat > "\(dir.path)/in.raw"
        stty sane
        touch "\(dir.path)/done"
        """ }
        defer { try? FileManager.default.removeItem(at: dir) }
        bridge.tmux("send-keys", "-t", "%\(first)", "sh \(path)", "Enter")
        #expect(waitFor(timeout: 15) { FileManager.default.fileExists(atPath: dir.appendingPathComponent("done").path) })
        let received = try String(decoding: Data(contentsOf: dir.appendingPathComponent("in.raw")), as: UTF8.self)
        let support = received.range(of: "\(esc)]7501;?\(esc)\\")
        let attributes = received.range(of: "\(esc)[?")
        // Both replies arrive.
        #expect(support != nil)
        #expect(attributes != nil)
        // Known limitation: tmux answers DA before Shell's OSC 7501 reply
        // can make the round trip. Producers that stop at the first standard
        // reply will not detect support through native tmux.
        if let support, let attributes {
            if holds {
                #expect(support.lowerBound < attributes.lowerBound)
            } else {
                withKnownIssue("stock tmux answers DA before the pane-addressed OSC 7501 reply") {
                    #expect(support.lowerBound < attributes.lowerBound)
                }
            }
        }
    }

    @Test(.enabled(if: TmuxBridge.tmuxPath != nil))
    func paneProcessExitCleansUpEarlyStatus() throws {
        Recorder.shared.clear()
        let app = makeApp()
        let gateway = makeSurface(app)
        defer { swiftty_surface_free(gateway); swiftty_app_free(app) }
        swiftty_surface_set_size(gateway, 800, 400)
        let bridge = try #require(TmuxBridge(gateway: gateway))
        defer { bridge.stop() }
        let first = try attach(gateway)
        #expect(waitFor { pane(gateway, first)?.initializing == false })
        bridge.tmux("set-option", "-g", "remain-on-exit", "on")

        // Reports written the instant the pane starts, before Shell knows
        // the pane or has captured it, are kept; the exit then drops the
        // transient one.
        let (path, dir) = try script { dir in """
        printf '\\033]7501;state=working:id=build\\033\\\\'
        printf '\\033]7501;state=done:id=test\\033\\\\'
        sleep 2
        """ }
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = try #require(UInt(bridge.tmux("new-window", "-d", "-P", "-F", "#{pane_id}", "sh \(path)").dropFirst()))
        #expect(waitFor { records(gateway, id) == ["build": .working, "test": .done] })
        #expect(waitFor(timeout: 10) { records(gateway, id) == ["test": .done] })
        #expect(pane(gateway, id)?.dead == true)
    }
}

extension TmuxIntegrationTests {
    /// `capture-pane -e` blocks carry raw escape sequences (colored
    /// prompts, `❯`); recapturing such a pane must not end control mode.
    @Test(.enabled(if: TmuxBridge.tmuxPath != nil))
    func coloredPaneRecaptures() throws {
        Recorder.shared.clear()
        let app = makeApp()
        let gateway = makeSurface(app)
        defer { swiftty_surface_free(gateway); swiftty_app_free(app) }
        swiftty_surface_set_size(gateway, 800, 400)
        let bridge = try #require(TmuxBridge(gateway: gateway))
        defer { bridge.stop() }
        #expect(Recorder.shared.wait { $0.contains { if case .paneSynced = $0 { true } else { false } } })
        bridge.tmux("send-keys", "-t", "%0", "printf '\\033[35m\\342\\235\\257\\033[39m colored\\n'", "Enter")
        Thread.sleep(forTimeInterval: 0.5)
        let syncs = Recorder.shared.all.count { if case .paneSynced = $0 { true } else { false } }
        swiftty_surface_tmux_reset(gateway)
        #expect(Recorder.shared.wait { $0.count { if case .paneSynced = $0 { true } else { false } } > syncs })
        #expect(swiftty_surface_tmux_active(gateway))
        var cfg = swiftty_surface_config_new()
        let pane = try #require(swiftty_surface_new_tmux_pane(app, gateway, 0, 0, nil, nil, &cfg))
        defer { swiftty_surface_free(pane) }
        swiftty_surface_set_size(pane, 800, 400)
        #expect(waitFor { screenText(pane).contains { $0.contains("❯ colored") } })
    }
}

extension TmuxBridge {
    /// Runs a tmux command against this bridge's server; returns stdout
    /// without the trailing newline.
    @discardableResult
    func tmux(_ arguments: String...) -> String {
        guard let path = Self.tmuxPath else { return "" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-L", socket] + arguments
        let out = Pipe()
        process.standardOutput = out
        try? process.run()
        process.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
}

// Drive control-mode replies directly so capture completion always lands
// between the two output chunks, without timing a real tmux process.
extension TmuxIntegrationTests {
    private func captureReply(_ body: String = "") -> String {
        "%begin 1 1 0\n" + (body.isEmpty ? "" : body + "\n") + "%end 1 1 0\n"
    }

    private func outputNotification(_ bytes: ArraySlice<UInt8>) -> String {
        "%output %0 " + bytes.map { String(format: "\\%03o", Int($0)) }.joined() + "\n"
    }

    @Test(arguments: ["orphan", "initial", "recapture", "recapture-quiet"])
    func splitStatusSurvivesCaptureHandoff(_ boundary: String) throws {
        let report = "\u{1B}]7501;state=working:id=build:progress=42\u{1B}\\"
        let queries = ["\u{1B}]7501;?\u{1B}\\", "\u{1B}]7501;?\u{07}"]
        for sequence in [report] + queries {
            let bytes = Array(sequence.utf8)
            for split in 1 ..< bytes.count {
                let app = makeApp()
                let gateway = makeSurface(app)
                defer { swiftty_surface_free(gateway); swiftty_app_free(app) }
                let viewer = TmuxViewer(gateway: try #require(Surface.from(gateway)))
                defer { viewer.close() }
                viewer.start()
                // Attach, session info, flag enable/readback, subscriptions,
                // then window topology. The pane is not listed yet.
                viewer.receive(Array((captureReply() + captureReply("$0 test") +
                    captureReply() + captureReply("program-status") +
                    captureReply() + captureReply() +
                    captureReply("@0 0 80 24 0000,80x24,0,0,0 0 1 test")).utf8))
                if boundary == "orphan" {
                    viewer.receive(Array(outputNotification(bytes[..<split]).utf8))
                }
                let paneList = "%0 @0 1 80 24 0 0 0 1 0 0 1 0 0 0 0 0 0 0 23 test"
                viewer.receive(Array(captureReply(paneList).utf8))
                let pane = try #require(viewer.pane(id: 0))
                let replies = Mutex<[[UInt8]]>([])
                pane.session.onTerminalReply = { reply in replies.withLock { $0.append(reply) } }
                if boundary.hasPrefix("recapture") {
                    viewer.receive(Array((captureReply() + captureReply("old screen")).utf8))
                    #expect(viewer.pane(id: 0)?.initializing == false)
                    // Prefix was parsed live before recapture began.
                    viewer.receive(Array(outputNotification(bytes[..<split]).utf8))
                    _ = viewer.pane(id: 0) // drain the viewer queue
                } else if boundary == "initial" {
                    viewer.receive(Array(outputNotification(bytes[..<split]).utf8))
                }
                if boundary.hasPrefix("recapture") {
                    // Resume starts with a probe; a fresh stream uses the
                    // ordinary attach/topology replies and recaptures panes.
                    viewer.start()
                    viewer.receive(Array((captureReply() + captureReply("$0 test") +
                        captureReply() + captureReply("program-status") +
                        captureReply() + captureReply() +
                        captureReply("@0 0 80 24 0000,80x24,0,0,0 0 1 test") +
                        captureReply(paneList)).utf8))
                }
                if boundary == "recapture" {
                    // Force a stand-in to adopt the pane's pending prefix.
                    viewer.receive(Array("%output %0 \n".utf8))
                }
                viewer.receive(Array((captureReply() + captureReply("captured screen")).utf8))
                #expect(viewer.pane(id: 0)?.initializing == false)
                viewer.receive(Array(outputNotification(bytes[split...]).utf8))
                _ = viewer.pane(id: 0) // enqueue all live bytes before reading
                let snapshot = pane.session.programStatusSnapshot
                if sequence == report {
                    #expect(snapshot.records.count == 1)
                    #expect(snapshot.records.first?.id == "build")
                    #expect(snapshot.records.first?.progress == 42)
                } else if sequence.hasSuffix("\u{1B}\\"), split == bytes.count - 1,
                          !boundary.hasPrefix("recapture") {
                    // The parser dispatches an ST-terminated OSC at ESC,
                    // so this reply was already routed by the stand-in.
                    _ = viewer.pane(id: 0)
                    #expect(drain(swiftty_surface_response_read_fd(gateway), timeout: 0.01)
                        .contains("refresh-client -r"))
                    #expect(replies.withLock { $0.isEmpty })
                } else {
                    #expect(replies.withLock { $0 } == [bytes])
                }
            }
        }
    }
}
