//
//  TmuxControlModeStreamTrackerTests.swift
//  ShellTests
//
//  Host decorations must not be injected into a tmux control-mode DCS: an
//  ESC there ends control mode and dumps the protocol onto the screen.
//

import Foundation
import Testing
@testable import Shell

@Suite
struct TmuxControlModeStreamTrackerTests {
    private func bytes(_ s: String) -> Data { Data(s.utf8) }

    @Test func entersAndLeavesControlMode() {
        var t = TmuxControlModeStreamTracker()
        t.observe(bytes("login banner\r\n\u{1B}[1mhi\u{1B}[0m"))
        #expect(!t.isInside)
        t.observe(bytes("\u{1B}P1000p%begin 1 1 0\n%end 1 1 0\n"))
        #expect(t.isInside)
        t.observe(bytes("%output %0 \\033[1mx\n"))
        #expect(t.isInside)
        t.observe(bytes("%exit\n\u{1B}\\"))
        #expect(!t.isInside)
    }

    @Test func markersSplitAcrossChunks() {
        var t = TmuxControlModeStreamTracker()
        t.observe(bytes("abc\u{1B}P10"))
        #expect(!t.isInside)
        t.observe(bytes("00p%begin"))
        #expect(t.isInside)
        t.observe(bytes("%exit\n\u{1B}"))
        #expect(t.isInside)
        t.observe(bytes("\\$ "))
        #expect(!t.isInside)
    }

    @Test func capturedEscapesInsideBlocksDoNotEndControlMode() {
        var t = TmuxControlModeStreamTracker()
        t.observe(bytes("\u{1B}P1000p%begin 1 2 1\n"))
        // capture-pane -e: SGR at a line start and mid-line, and a mid-line ST
        // (an OSC 8 hyperlink) are all block data.
        t.observe(bytes("\u{1B}[35m❯\u{1B}[39m \u{1B}]8;;x\u{1B}\\link\u{1B}]8;;\u{1B}\\\n"))
        #expect(t.isInside)
        t.observe(bytes("%end 1 2 1\n%exit\n\u{1B}\\"))
        #expect(!t.isInside)
    }

    @Test func parserStateOverridesTheByteStream() {
        var t = TmuxControlModeStreamTracker()
        t.observe(bytes("\u{1B}P1000p%begin 1 1 0\n%output %0 partial"))
        #expect(t.isInside)
        // A forced exit ends control mode in the parser (CAN sent to it
        // directly); the tracker never saw the bytes.
        t.setInside(false)
        #expect(!t.isInside)
        t.observe(bytes("$ \u{1B}]0;title\u{1B}\\"))
        #expect(!t.isInside)
        // A resumed gateway enters control mode without the DCS bytes.
        t.setInside(true)
        #expect(t.isInside)
        t.observe(bytes("%exit\n\u{1B}\\"))
        #expect(!t.isInside)
    }

    @Test func otherDCSIsNotControlMode() {
        var t = TmuxControlModeStreamTracker()
        t.observe(bytes("\u{1B}P+q544e\u{1B}\\"))
        #expect(!t.isInside)
    }
}
