import Foundation
@testable import GhosttyKit
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

@Suite(.serialized)
struct SelectionDragTests {
    @Test func dragPastTopEdgeKeepsScrolling() {
        let app = makeApp()
        let s = makeSurface(app)
        defer { ghostty_surface_free(s); ghostty_app_free(app) }
        ghostty_surface_set_size(s, 800, 400)
        write(ghostty_surface_get_slave_fd(s), (1 ... 200).map { "line \($0)" }.joined(separator: "\r\n"))
        #expect(waitFor { screenText(s).contains("line 200") })
        ghostty_surface_mouse_pos(s, 20, 60, GHOSTTY_MODS_NONE)
        _ = ghostty_surface_mouse_button(s, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
        ghostty_surface_mouse_pos(s, 20, -40, GHOSTTY_MODS_NONE)
        // The main-queue timer keeps scrolling while the pointer stays above.
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        var bar = ghostty_action_scrollbar_s()
        #expect(ghostty_surface_display_scrollbar(s, &bar))
        #expect(bar.offset + bar.len < bar.total - 10)
        var text = ghostty_text_s()
        #expect(ghostty_surface_read_selection(s, &text))
        let lines = String(cString: text.text).split(separator: "\n").count
        ghostty_surface_free_text(s, &text)
        #expect(lines > 10)
        _ = ghostty_surface_mouse_button(s, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
    }
}

@Suite(.serialized)
struct KeybindTests {
    @Test func defaultLineEditingBindings() {
        let app = makeApp()
        let s = makeSurface(app)
        defer { ghostty_surface_free(s); ghostty_app_free(app) }
        ghostty_surface_set_size(s, 800, 400)
        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_PRESS
        key.keycode = 0x7B // left
        key.mods = GHOSTTY_MODS_SUPER
        #expect(ghostty_surface_key(s, key))
        key.mods = GHOSTTY_MODS_ALT
        #expect(ghostty_surface_key(s, key))
        #expect(drain(ghostty_surface_response_read_fd(s)) == "\u{01}\u{1B}b")
    }
}

@Suite(.serialized)
struct KeyReleaseTests {
    @Test func consumedPressSwallowsRelease() {
        let app = makeApp()
        let s = makeSurface(app)
        defer { ghostty_surface_free(s); ghostty_app_free(app) }
        ghostty_surface_set_size(s, 800, 400)
        write(ghostty_surface_get_slave_fd(s), "\u{1B}[>3u") // kitty: disambiguate + event types
        #expect(waitFor { Surface.from(s)!.session.withState { $0.keyboardFlags } == 3 })
        var key = ghostty_input_key_s()
        key.keycode = 0x74 // page up
        key.mods = GHOSTTY_MODS_SHIFT // bound to scroll_page_up
        key.action = GHOSTTY_ACTION_PRESS
        #expect(ghostty_surface_key(s, key))
        key.action = GHOSTTY_ACTION_RELEASE
        _ = ghostty_surface_key(s, key)
        #expect(drain(ghostty_surface_response_read_fd(s)) == "")
    }

    @Test func releaseReusesItsPress() {
        let app = makeApp(configText: "macos-option-as-alt = true")
        let s = makeSurface(app)
        defer { ghostty_surface_free(s); ghostty_app_free(app) }
        ghostty_surface_set_size(s, 800, 400)
        write(ghostty_surface_get_slave_fd(s), "\u{1B}[>3u")
        #expect(waitFor { Surface.from(s)!.session.withState { $0.keyboardFlags } == 3 })
        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_PRESS
        key.keycode = 0x00 // a
        key.unshifted_codepoint = 0x61
        key.mods = GHOSTTY_MODS_ALT
        "a".withCString { key.text = $0; _ = ghostty_surface_key(s, key) }
        // The host's release carries only the keycode and modifiers.
        key.action = GHOSTTY_ACTION_RELEASE
        key.text = nil
        key.unshifted_codepoint = 0
        _ = ghostty_surface_key(s, key)
        // F13 has no encoding: nothing is sent.
        var f13 = ghostty_input_key_s()
        f13.action = GHOSTTY_ACTION_PRESS
        f13.keycode = 0x69
        _ = ghostty_surface_key(s, f13)
        #expect(drain(ghostty_surface_response_read_fd(s)) == "\u{1B}[97;3u\u{1B}[97;3:3u")
    }

    @Test func metaShiftSendsShiftedText() {
        let app = makeApp(configText: "macos-option-as-alt = true")
        let s = makeSurface(app)
        defer { ghostty_surface_free(s); ghostty_app_free(app) }
        ghostty_surface_set_size(s, 800, 400)
        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_PRESS
        key.keycode = 0x12 // 1
        key.unshifted_codepoint = 0x31
        key.mods = ghostty_input_mods_e(GHOSTTY_MODS_ALT.rawValue | GHOSTTY_MODS_SHIFT.rawValue)
        "!".withCString { key.text = $0; _ = ghostty_surface_key(s, key) }
        #expect(drain(ghostty_surface_response_read_fd(s)) == "\u{1B}!")
    }
}
