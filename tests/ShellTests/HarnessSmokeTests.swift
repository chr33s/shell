import XCTest

@testable import Shell

/// End-to-end proof that the `ShellTests` harness works.
///
/// This is deliberately the only test in the target for now. It exists to pin
/// three things that the rest of the test suite depends on, and that fail
/// loudly here rather than mysteriously later:
///
/// 1. The bundle builds, links against the host app, loads, and runs.
/// 2. `@testable import Shell` reaches app-*internal* types — the module is
///    `Shell` (from `PRODUCT_NAME`), not `shell`, and `ENABLE_TESTABILITY`
///    really is on for the Debug configuration the test action uses.
/// 3. The tests run on the **iOS Simulator**, not Mac Catalyst. `ShellTokenizer`
///    and `ShellParser` — like the whole local-shell stack — sit behind
///    `#if !targetEnvironment(macCatalyst)`, so this file does not compile at
///    all on a Catalyst destination. If someone repoints `scripts/test.sh` at
///    Catalyst, this is the tripwire.
@MainActor
final class HarnessSmokeTests: XCTestCase {
    func testTestableImportReachesInternalShellTypes() throws {
        let parser = ShellParser(tokenizer: ShellTokenizer(source: "echo hi"))
        XCTAssertNoThrow(try parser.parse())
    }
}
