import Foundation
import Testing

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
/// 3. The local-shell stack compiles on **every** test destination. `ShellTokenizer`
///    and `ShellParser` used to sit behind `#if !targetEnvironment(macCatalyst)`;
///    since `LocalShellBackend` made the interpreter the sandboxed Catalyst shell
///    (docs/specs/shell.md section 9.6) they must build there too, and
///    `scripts/test.sh --catalyst` runs this suite on My Mac. If someone fences
///    the stack off Catalyst again, this file stops compiling there: the tripwire.
@MainActor
@Suite
final class HarnessSmokeTests {
    @Test
    func testTestableImportReachesInternalShellTypes() throws {
        let parser = ShellParser(tokenizer: ShellTokenizer(source: "echo hi"))
        do { _ = try parser.parse() } catch { Issue.record("unexpected error: \(error)") }
    }
}
