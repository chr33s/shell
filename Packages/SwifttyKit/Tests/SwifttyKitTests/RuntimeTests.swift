import Foundation
@testable import SwifttyKit
import SwifttyCore
import Testing

@Suite(.serialized)
struct RuntimeTests {
    @Test func outputRendersAndKeysReachTheResponsePipe() {
        Recorder.shared.clear()
        let app = makeApp()
        let s = makeSurface(app)
        defer { swiftty_surface_free(s); swiftty_app_free(app) }
        swiftty_surface_set_size(s, 800, 400)
        let size = swiftty_surface_size(s)
        #expect(size.columns > 10 && size.rows > 5)
        #expect(Recorder.shared.wait { $0.contains(.ptyResize(rows: UInt32(size.rows), cols: UInt32(size.columns))) })

        write(swiftty_surface_get_slave_fd(s), "hello \u{1B}[1mworld\u{1B}[0m\r\n$ ")
        #expect(waitFor { screenText(s).first == "hello world" })

        var key = swiftty_input_key_s()
        key.action = SWIFTTY_ACTION_PRESS
        key.keycode = 0x00 // a
        key.unshifted_codepoint = 0x61
        "a".withCString { key.text = $0; _ = swiftty_surface_key(s, key) }
        key.keycode = 0x7E // up
        key.text = nil
        _ = swiftty_surface_key(s, key)
        key.keycode = 0x08 // c with ctrl
        key.mods = SWIFTTY_MODS_CTRL
        key.unshifted_codepoint = 0x63
        _ = swiftty_surface_key(s, key)
        #expect(drain(swiftty_surface_response_read_fd(s)) == "a\u{1B}[A\u{03}")
    }

    @Test func repliesAndDumpRoundTrip() {
        let app = makeApp()
        let s = makeSurface(app)
        defer { swiftty_surface_free(s); swiftty_app_free(app) }
        swiftty_surface_set_size(s, 800, 400)
        write(swiftty_surface_get_slave_fd(s), "x\u{1B}[6n")
        // A terminal reply, on the reply pipe and never with typed input.
        #expect(drain(swiftty_surface_reply_read_fd(s)) == "\u{1B}[1;2R")
        #expect(drain(swiftty_surface_response_read_fd(s), timeout: 0.2) == "")
        write(swiftty_surface_get_slave_fd(s), "\r\n\u{1B}[31mred\u{1B}[0m")
        #expect(waitFor { screenText(s).count > 1 && screenText(s)[1] == "red" })
        var len: UInt = 0
        let dump = swiftty_surface_dump_primary_screen(s, &len)!
        let text = String(decoding: UnsafeRawBufferPointer(start: dump, count: Int(len)), as: UTF8.self)
        swiftty_surface_free_dump(dump, len)
        #expect(text == "x\r\n\u{1B}[0;31mred\u{1B}[0m")
    }

    @Test func bindingsSelectionAndSearch() {
        let app = makeApp()
        let s = makeSurface(app)
        defer { swiftty_surface_free(s); swiftty_app_free(app) }
        swiftty_surface_set_size(s, 800, 400)
        write(swiftty_surface_get_slave_fd(s), "alpha beta\r\ngamma beta")
        #expect(waitFor { screenText(s).count > 1 && screenText(s)[1] == "gamma beta" })
        #expect(!swiftty_surface_has_selection(s))
        "select_all".withCString { _ = swiftty_surface_binding_action(s, $0, 10) }
        #expect(waitFor { swiftty_surface_has_selection(s) })
        var text = swiftty_text_s()
        #expect(swiftty_surface_read_selection(s, &text))
        #expect(String(cString: text.text).hasPrefix("alpha beta\ngamma beta"))
        swiftty_surface_free_text(s, &text)
        "search:beta".withCString { _ = swiftty_surface_binding_action(s, $0, UInt(strlen($0))) }
        let surface = Surface.from(s)!
        #expect(surface.session.withState { $0.searchMatches.count } == 2)
    }
}

@Suite(.serialized)
struct SelectionDragTests {
    @Test func dragPastTopEdgeKeepsScrolling() {
        let app = makeApp()
        let s = makeSurface(app)
        defer { swiftty_surface_free(s); swiftty_app_free(app) }
        swiftty_surface_set_size(s, 800, 400)
        write(swiftty_surface_get_slave_fd(s), (1 ... 200).map { "line \($0)" }.joined(separator: "\r\n"))
        #expect(waitFor { screenText(s).contains("line 200") })
        swiftty_surface_mouse_pos(s, 20, 60, SWIFTTY_MODS_NONE)
        _ = swiftty_surface_mouse_button(s, SWIFTTY_MOUSE_PRESS, SWIFTTY_MOUSE_LEFT, SWIFTTY_MODS_NONE)
        swiftty_surface_mouse_pos(s, 20, -40, SWIFTTY_MODS_NONE)
        // The main-queue timer keeps scrolling while the pointer stays above.
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        var bar = swiftty_action_scrollbar_s()
        #expect(swiftty_surface_display_scrollbar(s, &bar))
        #expect(bar.offset + bar.len < bar.total - 10)
        var text = swiftty_text_s()
        #expect(swiftty_surface_read_selection(s, &text))
        let lines = String(cString: text.text).split(separator: "\n").count
        swiftty_surface_free_text(s, &text)
        #expect(lines > 10)
        _ = swiftty_surface_mouse_button(s, SWIFTTY_MOUSE_RELEASE, SWIFTTY_MOUSE_LEFT, SWIFTTY_MODS_NONE)
    }
}

@Suite(.serialized)
struct KeybindTests {
    @Test func defaultLineEditingBindings() {
        let app = makeApp()
        let s = makeSurface(app)
        defer { swiftty_surface_free(s); swiftty_app_free(app) }
        swiftty_surface_set_size(s, 800, 400)
        var key = swiftty_input_key_s()
        key.action = SWIFTTY_ACTION_PRESS
        key.keycode = 0x7B // left
        key.mods = SWIFTTY_MODS_SUPER
        #expect(swiftty_surface_key(s, key))
        key.mods = SWIFTTY_MODS_ALT
        #expect(swiftty_surface_key(s, key))
        #expect(drain(swiftty_surface_response_read_fd(s)) == "\u{01}\u{1B}b")
    }
}

@Suite(.serialized)
struct KeyReleaseTests {
    @Test func consumedPressSwallowsRelease() {
        let app = makeApp()
        let s = makeSurface(app)
        defer { swiftty_surface_free(s); swiftty_app_free(app) }
        swiftty_surface_set_size(s, 800, 400)
        write(swiftty_surface_get_slave_fd(s), "\u{1B}[>3u") // kitty: disambiguate + event types
        #expect(waitFor { Surface.from(s)!.session.withState { $0.keyboardFlags } == 3 })
        var key = swiftty_input_key_s()
        key.keycode = 0x74 // page up
        key.mods = SWIFTTY_MODS_SHIFT // bound to scroll_page_up
        key.action = SWIFTTY_ACTION_PRESS
        #expect(swiftty_surface_key(s, key))
        key.action = SWIFTTY_ACTION_RELEASE
        _ = swiftty_surface_key(s, key)
        #expect(drain(swiftty_surface_response_read_fd(s)) == "")
    }

    @Test func releaseReusesItsPress() {
        let app = makeApp(configText: "macos-option-as-alt = true")
        let s = makeSurface(app)
        defer { swiftty_surface_free(s); swiftty_app_free(app) }
        swiftty_surface_set_size(s, 800, 400)
        write(swiftty_surface_get_slave_fd(s), "\u{1B}[>3u")
        #expect(waitFor { Surface.from(s)!.session.withState { $0.keyboardFlags } == 3 })
        var key = swiftty_input_key_s()
        key.action = SWIFTTY_ACTION_PRESS
        key.keycode = 0x00 // a
        key.unshifted_codepoint = 0x61
        key.mods = SWIFTTY_MODS_ALT
        "a".withCString { key.text = $0; _ = swiftty_surface_key(s, key) }
        // The host's release carries only the keycode and modifiers.
        key.action = SWIFTTY_ACTION_RELEASE
        key.text = nil
        key.unshifted_codepoint = 0
        _ = swiftty_surface_key(s, key)
        // F13 has no encoding: nothing is sent.
        var f13 = swiftty_input_key_s()
        f13.action = SWIFTTY_ACTION_PRESS
        f13.keycode = 0x69
        _ = swiftty_surface_key(s, f13)
        #expect(drain(swiftty_surface_response_read_fd(s)) == "\u{1B}[97;3u\u{1B}[97;3:3u")
    }

    @Test func metaShiftSendsShiftedText() {
        let app = makeApp(configText: "macos-option-as-alt = true")
        let s = makeSurface(app)
        defer { swiftty_surface_free(s); swiftty_app_free(app) }
        swiftty_surface_set_size(s, 800, 400)
        var key = swiftty_input_key_s()
        key.action = SWIFTTY_ACTION_PRESS
        key.keycode = 0x12 // 1
        key.unshifted_codepoint = 0x31
        key.mods = swiftty_input_mods_e(SWIFTTY_MODS_ALT.rawValue | SWIFTTY_MODS_SHIFT.rawValue)
        "!".withCString { key.text = $0; _ = swiftty_surface_key(s, key) }
        #expect(drain(swiftty_surface_response_read_fd(s)) == "\u{1B}!")
    }
}
