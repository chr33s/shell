import XCTest

@testable import Shell

/// Pins `SSHCommandParser.resolveJumpAuth` — the credential ladder that decides
/// what a `ssh -J bastion target` connection presents at the BASTION.
///
/// Two properties matter here and neither shows up in a build:
///
/// 1. **Rung order.** `-i` identity, then a password saved for the bastion's own
///    `host:port:user`, then the primary default identity, then prompt. Reorder
///    them and the app silently presents a different credential to a host the
///    user never typed a password for.
/// 2. **The bastion is offered exactly ONE identity.** A bastion's
///    `MaxAuthTries` is commonly 6 and `MultiKeyAuthDelegate` spends two
///    `MSG_USERAUTH_REQUEST`s per certified key, so walking the default list
///    locks the account out on the first hop with no budget left for a
///    password. `JumpHostConfig.fallbackKeyIDs` must stay `nil`.
///
/// Driven through the real `parse(command:)` entry point rather than the
/// private ladder, so the assertions are about what actually reaches
/// `SSHConfig` — the value a session is built from.
@MainActor
final class SSHJumpAuthLadderTests: XCTestCase {

    // MARK: - Fake credential store

    /// Every `(host, port, username)` the parser asked about, in order.
    private var savedPasswordQueries: [String] = []

    private let identityKeyID = UUID()
    private let defaultKeyA = UUID()
    private let defaultKeyB = UUID()
    private let defaultKeyC = UUID()

    /// Installs a deterministic `CredentialSources`. `savedPasswordHosts` holds
    /// `"host:port:user"` keys; `identityPaths` maps a `-i` argument to a key.
    private func installCredentials(
        identityPaths: [String: UUID] = [:],
        savedPasswordHosts: Set<String> = [],
        defaultKeyIDs: [UUID] = []
    ) {
        SSHCommandParser.credentials = SSHCommandParser.CredentialSources(
            hasSavedPassword: { [weak self] host, port, username in
                let key = "\(host):\(port):\(username)"
                self?.savedPasswordQueries.append(key)
                return savedPasswordHosts.contains(key)
            },
            keyIDForIdentityPath: { identityPaths[$0] },
            defaultKeyIDs: { defaultKeyIDs }
        )
    }

    override func tearDown() {
        SSHCommandParser.credentials = .live
        savedPasswordQueries = []
        super.tearDown()
    }

    // MARK: - Helpers

    private struct UnexpectedParseResult: Error {}

    private func jumpConfig(
        _ command: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> SSHConfig.JumpHostConfig {
        switch SSHCommandParser.parse(command: command) {
        case .success(let config):
            return try XCTUnwrap(config.jumpHost, "expected a jump host", file: file, line: line)
        case .needsPassword(let partial):
            return try XCTUnwrap(partial.jumpHost, "expected a jump host", file: file, line: line)
        case .error(let message):
            XCTFail("parse failed: \(message)", file: file, line: line)
            throw UnexpectedParseResult()
        case .help:
            XCTFail("parse returned .help", file: file, line: line)
            throw UnexpectedParseResult()
        }
    }

    private func successConfig(
        _ command: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> SSHConfig {
        guard case .success(let config) = SSHCommandParser.parse(command: command) else {
            XCTFail("expected .success", file: file, line: line)
            throw UnexpectedParseResult()
        }
        return config
    }

    // MARK: - Rung order

    /// Rung 1 beats rungs 2 and 3: with a saved bastion password AND default
    /// identities available, an explicit `-i` still wins. OpenSSH applies `-i`
    /// to every hop of the chain, and the user naming a key is the strongest
    /// statement of intent there is.
    ///
    /// Goes red if `resolveJumpAuth` checks the saved password or the default
    /// key before the `-i` identity.
    func testExplicitIdentityOutranksSavedBastionPasswordAndDefaultKey() throws {
        installCredentials(
            identityPaths: ["/keys/work_ed25519": identityKeyID],
            savedPasswordHosts: ["bastion.example.com:22:admin"],
            defaultKeyIDs: [defaultKeyA, defaultKeyB]
        )

        let jump = try jumpConfig(
            "ssh -i /keys/work_ed25519 -J admin@bastion.example.com user@target.example.com"
        )

        XCTAssertEqual(jump.authMethod, .key(identityKeyID))
    }

    /// Rung 2 beats rung 3: with no `-i`, a password saved for the bastion is
    /// used even though default identities exist.
    ///
    /// Goes red if the default-key rung is moved ahead of the saved-password
    /// rung — which would present a key to a host the user had deliberately
    /// stored a password for, burning `MaxAuthTries` before the credential that
    /// works is ever offered.
    func testSavedBastionPasswordOutranksDefaultKey() throws {
        installCredentials(
            savedPasswordHosts: ["bastion.example.com:22:admin"],
            defaultKeyIDs: [defaultKeyA, defaultKeyB]
        )

        let jump = try jumpConfig("ssh -J admin@bastion.example.com user@target.example.com")

        XCTAssertEqual(jump.authMethod, .savedPassword)
    }

    /// Rung 3: nothing explicit, nothing saved — the PRIMARY default identity,
    /// which is `defaultKeyIDs.first`, not an arbitrary member of the list.
    ///
    /// Goes red if the ladder starts picking a different default (last, or a
    /// name/host match) for the bastion.
    func testPrimaryDefaultKeyIsUsedWhenNothingElseIsStored() throws {
        installCredentials(defaultKeyIDs: [defaultKeyA, defaultKeyB, defaultKeyC])

        let jump = try jumpConfig("ssh -J admin@bastion.example.com user@target.example.com")

        XCTAssertEqual(jump.authMethod, .key(defaultKeyA))
    }

    /// Rung 4 — exhausted. Nothing resolves, so the parser asks, and it asks for
    /// the BASTION first: it is the first hop, and OpenSSH prompts in the same
    /// order. `targetAuthMethod` stays nil, which the prompt site reads as "the
    /// target has no credential either" and chains a second prompt.
    ///
    /// Goes red if an empty password is invented for the bastion and the parse
    /// reports `.success` — i.e. if a connection is launched that silently sends
    /// `""` to a host the user was never asked about.
    func testExhaustedLadderPromptsForTheBastionAndNotTheTarget() {
        installCredentials()

        guard case .needsPassword(let partial) =
                SSHCommandParser.parse(command: "ssh -J admin@bastion.example.com user@target.example.com")
        else {
            return XCTFail("expected .needsPassword when no credential resolves for either hop")
        }

        XCTAssertEqual(partial.passwordSubject, .jumpHost)
        XCTAssertNil(partial.targetAuthMethod)
        XCTAssertEqual(partial.host, "target.example.com")
        XCTAssertEqual(partial.jumpHost?.host, "bastion.example.com")
    }

    /// The bastion's saved-password lookup is keyed on the BASTION's own
    /// `host:port:user`, never the target's.
    ///
    /// This is the same failure class as the hop-attribution defect: get the
    /// subject wrong and a Keychain row belonging to one host answers for
    /// another. Here the target and bastion differ in all three components, so
    /// any mix-up is visible.
    ///
    /// Goes red if `resolveJumpAuth` is passed the target's host, port, or
    /// username — e.g. by reusing `finalHost`/`port`/`finalUsername` from the
    /// enclosing parse.
    func testBastionPasswordIsLookedUpUnderTheBastionsOwnHostPortUser() throws {
        installCredentials(defaultKeyIDs: [defaultKeyA])

        _ = try jumpConfig("ssh -p 2222 -J admin@bastion.example.com:2200 user@target.example.com")

        // Exactly two probes, each under its OWN host:port:user, bastion first.
        // Any mix-up — the bastion probed on port 2222, or as `user` — shows up
        // here as a changed tuple rather than a passing `contains`.
        XCTAssertEqual(
            savedPasswordQueries,
            ["bastion.example.com:2200:admin", "target.example.com:2222:user"]
        )
    }

    /// An unqualified `-J bastion.example.com` inherits the target's username,
    /// matching OpenSSH, and the saved-password probe uses that inherited user.
    ///
    /// Goes red if the inheritance is dropped (the bastion would be probed under
    /// the device's local username instead) or applied after the lookup.
    func testUnqualifiedBastionInheritsTargetUsernameForItsOwnLookup() throws {
        installCredentials(defaultKeyIDs: [defaultKeyA])

        let jump = try jumpConfig("ssh -J bastion.example.com deploy@target.example.com")

        XCTAssertEqual(jump.username, "deploy")
        XCTAssertTrue(
            savedPasswordQueries.contains("bastion.example.com:22:deploy"),
            "queries were \(savedPasswordQueries)"
        )
    }

    // MARK: - The one-credential invariant (KEEP-LIST)

    /// THE INVARIANT: with three default identities configured, the TARGET hop
    /// receives the remaining two as fallbacks — and the bastion receives NONE.
    ///
    /// The asymmetry is the whole point, so it is asserted in one test: the
    /// target is a separate SSH connection over the tunnel with its own
    /// `MaxAuthTries` budget, while the bastion's budget is the scarce resource
    /// that a full default-key walk exhausts.
    ///
    /// Goes red the moment anyone "makes the bastion consistent with the target"
    /// by handing `JumpHostConfig` a `fallbackKeyIDs` list.
    func testBastionGetsNoFallbackIdentitiesWhileTargetKeepsItsOwn() throws {
        installCredentials(defaultKeyIDs: [defaultKeyA, defaultKeyB, defaultKeyC])

        let config = try successConfig("ssh -J admin@bastion.example.com user@target.example.com")

        XCTAssertEqual(config.fallbackKeyIDs, [defaultKeyB, defaultKeyC])
        XCTAssertNil(
            config.jumpHost?.fallbackKeyIDs,
            "a bastion must be offered exactly one identity — MaxAuthTries is the scarce resource"
        )
    }

    /// Same invariant on the `-i` path: naming an identity must not turn the
    /// default list into bastion fallbacks either.
    ///
    /// Goes red if fallbacks are synthesized for the jump host anywhere in the
    /// `-i` branch.
    func testBastionGetsNoFallbackIdentitiesOnTheExplicitIdentityPath() throws {
        installCredentials(
            identityPaths: ["/keys/work_ed25519": identityKeyID],
            defaultKeyIDs: [defaultKeyA, defaultKeyB, defaultKeyC]
        )

        let config = try successConfig(
            "ssh -i /keys/work_ed25519 -J admin@bastion.example.com user@target.example.com"
        )

        XCTAssertEqual(config.jumpHost?.authMethod, .key(identityKeyID))
        XCTAssertNil(config.jumpHost?.fallbackKeyIDs)
    }

    /// A resolved TARGET credential survives the bastion password prompt round
    /// trip instead of being re-asked. The parser carries it in
    /// `targetAuthMethod`/`targetFallbackKeyIDs`, and `toSSHConfig(password:)`
    /// applies the typed secret to the BASTION only.
    ///
    /// Goes red if `resultAwaitingJumpPassword` stops forwarding the target's
    /// method — the user would be prompted twice, and the second prompt would
    /// overwrite a working key with a password.
    func testTypedBastionPasswordIsAppliedToTheBastionAndLeavesTheTargetKeyIntact() throws {
        // Only the TARGET has a stored credential, so only the bastion needs a
        // prompt. No default keys: a default would resolve the bastion too.
        installCredentials(
            savedPasswordHosts: ["target.example.com:22:user"],
            defaultKeyIDs: []
        )

        guard case .needsPassword(let partial) =
                SSHCommandParser.parse(command: "ssh -J admin@bastion.example.com user@target.example.com")
        else {
            return XCTFail("expected a bastion-only prompt")
        }

        XCTAssertEqual(partial.passwordSubject, .jumpHost)
        XCTAssertEqual(partial.targetAuthMethod, .savedPassword)

        let resolved = partial.toSSHConfig(password: "bastion-secret")
        XCTAssertEqual(resolved.jumpHost?.authMethod, .password("bastion-secret"))
        XCTAssertEqual(
            resolved.authMethod, .savedPassword,
            "the typed bastion secret must never be written onto the target hop"
        )
    }

    /// No `-J` at all: the target ladder still runs, and no jump host is
    /// invented. Guards against a refactor that gives every connection an
    /// implicit bastion.
    ///
    /// Goes red if `jumpHost` becomes non-nil without `-J`/`ProxyJump`.
    func testNoJumpHostConfiguredLeavesJumpConfigNil() throws {
        installCredentials(defaultKeyIDs: [defaultKeyA, defaultKeyB])

        let config = try successConfig("ssh user@target.example.com")

        XCTAssertNil(config.jumpHost)
        XCTAssertEqual(config.authMethod, .key(defaultKeyA))
        XCTAssertEqual(config.fallbackKeyIDs, [defaultKeyB])
    }

    /// `-o ProxyJump=` is the config-file spelling of `-J` and must take the same
    /// single-credential ladder.
    ///
    /// Goes red if the `ProxyJump` option path bypasses `resolveJumpAuth` and
    /// builds a `JumpHostConfig` directly.
    func testProxyJumpOptionUsesTheSameSingleCredentialLadder() throws {
        installCredentials(defaultKeyIDs: [defaultKeyA, defaultKeyB, defaultKeyC])

        let config = try successConfig(
            "ssh -o ProxyJump=admin@bastion.example.com user@target.example.com"
        )

        XCTAssertEqual(config.jumpHost?.host, "bastion.example.com")
        XCTAssertEqual(config.jumpHost?.authMethod, .key(defaultKeyA))
        XCTAssertNil(config.jumpHost?.fallbackKeyIDs)
    }
}
