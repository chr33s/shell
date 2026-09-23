import XCTest
@testable import Shell

final class TerminalScrollbarAvailabilityTests: XCTestCase {
    func testTmuxControlPanePreservesDocumentWhileSurfaceIsUnavailable() {
        XCTAssertTrue(TerminalScrollbarAvailabilityPolicy.preservesExistingDocument(
            isTmuxPane: true,
            hasSurface: false,
            hasValidSample: true
        ))
    }

    func testTmuxPaneResetsWhenExistingSurfaceReportsNoScrollback() {
        // The displayed-scrollbar query returns false when total <= len,
        // including after a resize consumes the remaining history.
        XCTAssertFalse(TerminalScrollbarAvailabilityPolicy.preservesExistingDocument(
            isTmuxPane: true,
            hasSurface: true,
            hasValidSample: true
        ))
    }

    func testFreshTmuxPaneStillUsesResetPath() {
        for hasSurface in [false, true] {
            XCTAssertFalse(TerminalScrollbarAvailabilityPolicy.preservesExistingDocument(
                isTmuxPane: true,
                hasSurface: hasSurface,
                hasValidSample: false
            ))
        }
    }

    func testOrdinaryTerminalStillUsesResetPath() {
        for hasSurface in [false, true] {
            for hasValidSample in [false, true] {
                XCTAssertFalse(TerminalScrollbarAvailabilityPolicy.preservesExistingDocument(
                    isTmuxPane: false,
                    hasSurface: hasSurface,
                    hasValidSample: hasValidSample
                ))
            }
        }
    }
}
