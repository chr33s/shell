import Foundation
import GhosttyKit
@testable import GhosttyRuntime
import SwifttyCore
import Testing

@Suite(.serialized)
struct RuntimeTests {
    @Test func outputRendersAndKeysReachTheResponsePipe() {
        Recorder.shared.clear()
        let app = makeApp()
        let s = makeSurface(app)
        defer { ghostty_surface_free(s); ghostty_app_free(app) }
        ghostty_surface_set_size(s, 800, 400)
        let size = ghostty_surface_size(s)
        #expect(size.columns > 10 && size.rows > 5)
        #expect(Recorder.shared.wait { $0.contains(.ptyResize(rows: UInt32(size.rows), cols: UInt32(size.columns))) })

        write(ghostty_surface_get_slave_fd(s), "hello \u{1B}[1mworld\u{1B}[0m\r\n$ ")
        #expect(waitFor { screenText(s).first == "hello world" })

        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_PRESS
        key.keycode = 0x00 // a
        key.unshifted_codepoint = 0x61
        "a".withCString { key.text = $0; _ = ghostty_surface_key(s, key) }
        key.keycode = 0x7E // up
        key.text = nil
        _ = ghostty_surface_key(s, key)
        key.keycode = 0x08 // c with ctrl
        key.mods = GHOSTTY_MODS_CTRL
        key.unshifted_codepoint = 0x63
        _ = ghostty_surface_key(s, key)
        #expect(drain(ghostty_surface_response_read_fd(s)) == "a\u{1B}[A\u{03}")
    }

    @Test func repliesAndDumpRoundTrip() {
        let app = makeApp()
        let s = makeSurface(app)
        defer { ghostty_surface_free(s); ghostty_app_free(app) }
        ghostty_surface_set_size(s, 800, 400)
        write(ghostty_surface_get_slave_fd(s), "x\u{1B}[6n")
        #expect(drain(ghostty_surface_response_read_fd(s)) == "\u{1B}[1;2R")
        write(ghostty_surface_get_slave_fd(s), "\r\n\u{1B}[31mred\u{1B}[0m")
        #expect(waitFor { screenText(s).count > 1 && screenText(s)[1] == "red" })
        var len: UInt = 0
        let dump = ghostty_surface_dump_primary_screen(s, &len)!
        let text = String(decoding: UnsafeRawBufferPointer(start: dump, count: Int(len)), as: UTF8.self)
        ghostty_surface_free_dump(dump, len)
        #expect(text == "x\r\n\u{1B}[0;31mred\u{1B}[0m")
    }

    @Test func bindingsSelectionAndSearch() {
        let app = makeApp()
        let s = makeSurface(app)
        defer { ghostty_surface_free(s); ghostty_app_free(app) }
        ghostty_surface_set_size(s, 800, 400)
        write(ghostty_surface_get_slave_fd(s), "alpha beta\r\ngamma beta")
        #expect(waitFor { screenText(s).count > 1 && screenText(s)[1] == "gamma beta" })
        #expect(!ghostty_surface_has_selection(s))
        "select_all".withCString { _ = ghostty_surface_binding_action(s, $0, 10) }
        #expect(waitFor { ghostty_surface_has_selection(s) })
        var text = ghostty_text_s()
        #expect(ghostty_surface_read_selection(s, &text))
        #expect(String(cString: text.text).hasPrefix("alpha beta\ngamma beta"))
        ghostty_surface_free_text(s, &text)
        "search:beta".withCString { _ = ghostty_surface_binding_action(s, $0, UInt(strlen($0))) }
        let surface = Surface.from(s)!
        #expect(surface.session.withState { $0.searchMatches.count } == 2)
    }
}
