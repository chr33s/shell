import Foundation
@testable import SwifttyKit
import SwifttyCore
import Testing

/// OSC 133 prompts, mode 2031 and links through the embedder API.
@Suite(.serialized)
struct ShellIntegrationTests {
    private static let esc = "\u{1B}"

    /// A prompt and command line, with output when `output` is non-nil.
    private func command(_ line: String, output: [String]?) -> String {
        var s = "\(Self.esc)]133;A\u{07}$ \(Self.esc)]133;B\u{07}\(line)"
        if let output {
            s += "\r\n\(Self.esc)]133;C\u{07}" + output.map { $0 + "\r\n" }.joined() + "\(Self.esc)]133;D;0\u{07}"
        }
        return s
    }

    /// The point (as the host passes to mouse calls) at a cell's centre.
    private func point(_ s: swiftty_surface_t, column: Int, row: Int) -> (x: Double, y: Double) {
        let m = Surface.from(s)!.renderer.metrics
        return ((m.paddingX + (Double(column) + 0.5) * m.cellWidth) / m.scale, (m.paddingY + (Double(row) + 0.5) * m.cellHeight) / m.scale)
    }

    private func selection(_ s: swiftty_surface_t) -> String? {
        var text = swiftty_text_s()
        guard swiftty_surface_read_selection(s, &text) else { return nil }
        defer { swiftty_surface_free_text(s, &text) }
        return String(cString: text.text)
    }

    @Test func selectsCommandOutput() {
        let app = makeApp()
        let s = makeSurface(app)
        defer { swiftty_surface_free(s); swiftty_app_free(app) }
        swiftty_surface_set_size(s, 800, 400)
        write(swiftty_surface_get_slave_fd(s), command("one", output: ["first"]) + command("two", output: ["second a", "second b"]) + command("", output: nil))
        #expect(waitFor { screenText(s).contains("second b") })

        "select_command_output".withCString { _ = swiftty_surface_binding_action(s, $0, UInt(strlen($0))) }
        #expect(waitFor { swiftty_surface_has_selection(s) })
        #expect(selection(s)?.hasPrefix("second a\nsecond b") == true)

        // At a point: the first command's output.
        let p = point(s, column: 1, row: 1)
        #expect(swiftty_surface_has_command_output(s, p.x, p.y))
        #expect(swiftty_surface_select_command_output(s, p.x, p.y))
        #expect(selection(s)?.hasPrefix("first") == true)
    }

    @Test func jumpsBetweenPrompts() {
        let app = makeApp()
        let s = makeSurface(app)
        defer { swiftty_surface_free(s); swiftty_app_free(app) }
        swiftty_surface_set_size(s, 800, 400)
        let rows = Int(swiftty_surface_size(s).rows)
        let lines = (1 ... rows * 2).map { "line \($0)" }
        write(swiftty_surface_get_slave_fd(s), command("a", output: lines) + command("b", output: lines) + command("", output: nil))
        #expect(waitFor { screenText(s).contains("line \(rows * 2)") })
        let surface = Surface.from(s)!
        #expect(surface.session.withState { $0.viewportOffset } == 0)

        "jump_to_prompt:-1".withCString { _ = swiftty_surface_binding_action(s, $0, UInt(strlen($0))) }
        #expect(screenText(s).first == "$ b")
        // Shell's keybind names map to the same action.
        "jump_to_previous_prompt".withCString { _ = swiftty_surface_binding_action(s, $0, UInt(strlen($0))) }
        #expect(screenText(s).first == "$ a")
        "jump_to_next_prompt".withCString { _ = swiftty_surface_binding_action(s, $0, UInt(strlen($0))) }
        #expect(screenText(s).first == "$ b")
    }

    @Test func clickInCommandLineMovesCursor() {
        let app = makeApp()
        let s = makeSurface(app)
        defer { swiftty_surface_free(s); swiftty_app_free(app) }
        swiftty_surface_set_size(s, 800, 400)
        write(swiftty_surface_get_slave_fd(s), command("echo hi", output: nil))
        #expect(waitFor { screenText(s).first == "$ echo hi" })
        _ = drain(swiftty_surface_response_read_fd(s), timeout: 0.2)

        // Click on the "h" of "hi": two characters left of the cursor.
        let p = point(s, column: 7, row: 0)
        swiftty_surface_mouse_pos(s, p.x, p.y, SWIFTTY_MODS_NONE)
        _ = swiftty_surface_mouse_button(s, SWIFTTY_MOUSE_PRESS, SWIFTTY_MOUSE_LEFT, SWIFTTY_MODS_NONE)
        _ = swiftty_surface_mouse_button(s, SWIFTTY_MOUSE_RELEASE, SWIFTTY_MOUSE_LEFT, SWIFTTY_MODS_NONE)
        #expect(drain(swiftty_surface_response_read_fd(s)) == String(repeating: "\(Self.esc)[D", count: 2))
    }

    @Test func reportsColorSchemeFromTheme() {
        let app = makeApp()
        let s = makeSurface(app)
        defer { swiftty_surface_free(s); swiftty_app_free(app) }
        let fd = swiftty_surface_get_slave_fd(s)
        write(fd, "\(Self.esc)[?996n")
        #expect(drain(swiftty_surface_reply_read_fd(s)) == "\(Self.esc)[?997;1n")

        // A light theme, with mode 2031 on, is reported as it applies.
        write(fd, "\(Self.esc)[?2031h")
        _ = drain(swiftty_surface_reply_read_fd(s), timeout: 0.2)
        let config = swiftty_config_new()!
        defer { swiftty_config_free(config) }
        swiftty_config_finalize(config)
        let light = Unmanaged<Config>.fromOpaque(config).takeUnretainedValue()
        light.applyTheme("background = #fdf6e3\nforeground = #586e75")
        #expect(light.colorScheme == .light)
        swiftty_app_update_config(app, config)
        #expect(drain(swiftty_surface_reply_read_fd(s)) == "\(Self.esc)[?997;2n")
    }

    @Test func detectsLinksThroughCore() {
        let app = makeApp()
        let s = makeSurface(app)
        defer { swiftty_surface_free(s); swiftty_app_free(app) }
        swiftty_surface_set_size(s, 800, 400)
        write(swiftty_surface_get_slave_fd(s), "see https://example.com/a. ok\r\n\(Self.esc)]8;;https://osc8.example\u{07}here\(Self.esc)]8;;\u{07}")
        #expect(waitFor { screenText(s).count > 1 && screenText(s)[1] == "here" })
        let surface = Surface.from(s)!
        let detected = surface.link(at: (column: 8, row: 0))
        #expect(detected?.url == "https://example.com/a")
        #expect(detected?.id == 0)
        #expect(detected?.range.start.column == 4)
        #expect(surface.link(at: (column: 1, row: 1))?.url == "https://osc8.example")
        #expect(surface.link(at: (column: 0, row: 0)) == nil)
    }
}
