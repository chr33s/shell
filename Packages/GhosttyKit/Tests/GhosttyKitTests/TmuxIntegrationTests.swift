import Foundation
@testable import GhosttyKit
import SwifttyCore
import Testing

/// Runs a real `tmux -CC` on a PTY and connects it to a gateway surface's
/// external I/O, as an SSH channel would.
final class TmuxBridge {
    let process: PTYProcess
    let socket = "ghostty-runtime-test-\(UUID().uuidString.prefix(8))"
    private var running = true
    private let gateway: ghostty_surface_t

    static var tmuxPath: String? {
        let candidates = [ProcessInfo.processInfo.environment["TMUX_BIN"], "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux",
                          NSHomeDirectory() + "/.local/share/mise/installs/tmux/3.7b/tmux"]
        return candidates.compactMap(\.self).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    init?(gateway: ghostty_surface_t) {
        guard let tmux = Self.tmuxPath else { return nil }
        self.gateway = gateway
        var config = SessionConfiguration(command: [tmux, "-L", socket, "-f", "/dev/null", "-CC", "new-session", "-x", "100", "-y", "30", "/bin/sh"])
        config.removedEnvironment = ["TMUX"]
        config.environment = ["PS1": "$ "]
        guard let p = try? PTYProcess.spawn(config, columns: 100, rows: 30) else { return nil }
        process = p
        let master = p.master.rawValue
        // Mirror the PTY's ONLCR-free control stream into the surface.
        let slave = ghostty_surface_get_slave_fd(gateway)
        let response = ghostty_surface_response_read_fd(gateway)
        Thread.detachNewThread { [weak self] in
            var buf = [UInt8](repeating: 0, count: 65536)
            while self?.running == true {
                let n = Darwin.read(master, &buf, buf.count)
                if n > 0 { _ = buf.withUnsafeBytes { Darwin.write(slave, $0.baseAddress, n) } } else if n == 0 { break } else if errno != EAGAIN && errno != EINTR { break } else { usleep(5000) }
            }
        }
        Thread.detachNewThread { [weak self] in
            var buf = [UInt8](repeating: 0, count: 65536)
            while self?.running == true {
                let n = Darwin.read(response, &buf, buf.count)
                if n > 0 { _ = buf.withUnsafeBytes { Darwin.write(master, $0.baseAddress, n) } } else { break }
            }
        }
    }

    func stop() {
        running = false
        process.hangUp()
        if let tmux = Self.tmuxPath {
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: tmux)
            kill.arguments = ["-L", socket, "kill-server"]
            try? kill.run()
            kill.waitUntilExit()
        }
    }
}

@Suite(.serialized)
struct TmuxIntegrationTests {
    private func reconciles() -> [[String]] {
        Recorder.shared.all.compactMap { if case let .reconcile(ops) = $0 { ops } else { nil } }
    }

    @Test(.enabled(if: TmuxBridge.tmuxPath != nil))
    func controlModeLifecycle() throws {
        Recorder.shared.clear()
        let app = makeApp()
        let gateway = makeSurface(app)
        defer { ghostty_surface_free(gateway); ghostty_app_free(app) }
        ghostty_surface_set_size(gateway, 800, 400)
        let bridge = try #require(TmuxBridge(gateway: gateway))
        defer { bridge.stop() }

        // Attach: one window with one pane.
        #expect(Recorder.shared.wait { _ in reconciles().contains { $0.contains { $0.hasPrefix("pane @") } } })
        #expect(ghostty_surface_tmux_active(gateway))
        let first = try #require(reconciles().last { $0.first == "begin" })
        #expect(first.contains { $0.hasPrefix("window @") })
        let paneLine = try #require(first.first { $0.hasPrefix("pane @") })
        let ids = paneLine.split(separator: " ")
        let window = UInt(ids[1].dropFirst())!, pane = UInt(ids[2].dropFirst())!

        // A pane surface renders the pane and turns typing into send-keys.
        var cfg = ghostty_surface_config_new()
        let paneSurface = try #require(ghostty_surface_new_tmux_pane(app, gateway, window, pane, nil, nil, &cfg))
        defer { ghostty_surface_free(paneSurface) }
        ghostty_surface_set_size(paneSurface, 800, 400)
        "echo swiftty-$((40+2))\r".withCString { ghostty_surface_send_input(paneSurface, $0, UInt(strlen($0))) }
        #expect(waitFor { screenText(paneSurface).contains("swiftty-42") })

        // Commands with replies come back by tag.
        "display-message -p 'hello #{session_id}'".withCString {
            ghostty_surface_tmux_command_with_reply(gateway, $0, UInt(strlen($0)), 7)
        }
        #expect(Recorder.shared.wait { $0.contains { if case let .response(7, false, body) = $0 { body.hasPrefix("hello $") } else { false } } })

        // Splitting reports a two-pane layout.
        let split = "split-window -h -t %\(pane)"
        split.withCString { ghostty_surface_tmux_command(gateway, $0, UInt(strlen($0))) }
        #expect(Recorder.shared.wait { _ in reconciles().last { $0.first == "begin" }?.filter { $0.hasPrefix("pane @") }.count == 2 })
        #expect(reconciles().last { $0.first == "begin" }?.contains { $0.contains("children=2") } == true)

        // Recovery re-synchronizes through a probe without losing the panes.
        ghostty_surface_tmux_recover(gateway)
        var snap = ghostty_tmux_debug_snapshot_s()
        #expect(waitFor {
            _ = ghostty_surface_tmux_debug_snapshot(gateway, &snap)
            return snap.viewer_state == 3 && snap.command_in_flight == 0 && snap.pane_count == 2
        })
        "echo after-$((1+1))\r".withCString { ghostty_surface_send_input(paneSurface, $0, UInt(strlen($0))) }
        #expect(waitFor { screenText(paneSurface).contains("after-2") })

        // Detach: empty topology, control mode over.
        ghostty_surface_tmux_detach(gateway)
        #expect(Recorder.shared.wait { _ in reconciles().last == ["begin", "prune windows=0 panes=0", "end"] })
        #expect(waitFor { !ghostty_surface_tmux_active(gateway) })
    }

    private func paneSyncs() -> [(pane: UInt64, generation: UInt64)] {
        Recorder.shared.all.compactMap { if case let .paneSynced(pane, generation) = $0 { (pane, generation) } else { nil } }
    }

    /// A new control-mode stream on a live viewer (the old one died without
    /// `%exit`) starts a new generation: the old stream's pending replies
    /// fail instead of resolving later, and every pane is captured again and
    /// reported synced under the new generation (mobile-connectivity §8.5).
    @Test(.enabled(if: TmuxBridge.tmuxPath != nil))
    func restartedStreamIsGenerationBound() throws {
        Recorder.shared.clear()
        let app = makeApp()
        let gateway = makeSurface(app)
        defer { ghostty_surface_free(gateway); ghostty_app_free(app) }
        ghostty_surface_set_size(gateway, 800, 400)
        let bridge = try #require(TmuxBridge(gateway: gateway))
        defer { bridge.stop() }

        // The first stream: topology, then the pane's capture is applied.
        #expect(Recorder.shared.wait { _ in !paneSyncs().isEmpty })
        let first = try #require(paneSyncs().first)
        #expect(Recorder.shared.all.contains(.reconcileGeneration(first.generation)))
        #expect(Recorder.shared.all.contains { if case let .sessionChanged(_, g) = $0 { g == first.generation } else { false } })

        // A reply still owed by the old stream...
        "run-shell 'sleep 1'".withCString { ghostty_surface_tmux_command_with_reply(gateway, $0, UInt(strlen($0)), 11) }
        // ...when a new stream begins on the same viewer.
        let viewer = try #require(Surface.from(gateway)?.tmux)
        viewer.start()

        // The old reply fails exactly once and never resolves later.
        #expect(Recorder.shared.wait { $0.contains(.response(tag: 11, error: true, body: "")) })
        Thread.sleep(forTimeInterval: 1.5)
        let tagged = Recorder.shared.all.filter { if case let .response(tag, _, _) = $0 { tag == 11 } else { false } }
        #expect(tagged == [.response(tag: 11, error: true, body: "")])

        // The pane is captured again under the new generation.
        #expect(Recorder.shared.wait { _ in paneSyncs().contains { $0.pane == first.pane && $0.generation > first.generation } })
    }
}
