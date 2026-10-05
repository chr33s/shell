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

    @Test func otherDCSIsNotControlMode() {
        var t = TmuxControlModeStreamTracker()
        t.observe(bytes("\u{1B}P+q544e\u{1B}\\"))
        #expect(!t.isInside)
    }
}
