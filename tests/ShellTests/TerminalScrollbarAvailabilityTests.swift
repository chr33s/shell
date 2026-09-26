import Foundation
import Testing
@testable import Shell

@Suite
final class TerminalScrollbarAvailabilityTests {
    @Test
    func testTmuxControlPanePreservesDocumentWhileSurfaceIsUnavailable() throws {
        #expect(TerminalScrollbarAvailabilityPolicy.preservesExistingDocument(
            isTmuxPane: true,
            hasSurface: false,
            hasValidSample: true
        ))
    }

    @Test
    func testTmuxPaneResetsWhenExistingSurfaceReportsNoScrollback() throws {
        // The displayed-scrollbar query returns false when total <= len,
        // including after a resize consumes the remaining history.
        #expect(!(TerminalScrollbarAvailabilityPolicy.preservesExistingDocument(
            isTmuxPane: true,
            hasSurface: true,
            hasValidSample: true
        )))
    }

    @Test
    func testFreshTmuxPaneStillUsesResetPath() throws {
        for hasSurface in [false, true] {
            #expect(!(TerminalScrollbarAvailabilityPolicy.preservesExistingDocument(
                isTmuxPane: true,
                hasSurface: hasSurface,
                hasValidSample: false
            )))
        }
    }

    @Test
    func testOrdinaryTerminalStillUsesResetPath() throws {
        for hasSurface in [false, true] {
            for hasValidSample in [false, true] {
                #expect(!(TerminalScrollbarAvailabilityPolicy.preservesExistingDocument(
                    isTmuxPane: false,
                    hasSurface: hasSurface,
                    hasValidSample: hasValidSample
                )))
            }
        }
    }
}
