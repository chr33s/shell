import Citadel
import XCTest

@testable import Shell

/// Pins `CitadelSSHSession.failedHopAttribution` — which HOST gets blamed when
/// an `ssh -J` connection fails to authenticate.
///
/// THE REGRESSION THIS EXISTS FOR: attribution once keyed off
/// `config.usesJumpHost`, so a jump host merely being *configured* meant any
/// auth failure was reported as the bastion's. A target rejection therefore
/// raised a retry prompt naming the bastion, and the password the user typed
/// for the target was applied to the bastion hop and written into the bastion's
/// Keychain row. Attribution now keys off `connectionHop` — the hop that was
/// actually in flight.
///
/// Consumers turn `isJumpHost` straight into the subject of a password prompt
/// and into the host a typed secret is stored against, so a wrong answer here
/// is a credential-misdirection bug, not a cosmetic one. Every test below fails
/// if attribution reverts to "is a jump host configured?".
@MainActor
final class SSHHopAttributionTests: XCTestCase {

    private let targetHost = "target.example.com"
    private let bastionHost = "bastion.example.com"

    /// A session with a bastion configured. Nothing is connected: `init` only
    /// stores the two values and wires echo callbacks, and `transition(to:)`
    /// mutates `connectionHop` and calls an unset `onStateChange`. No socket,
    /// no event loop, no I/O.
    private func makeSession(withJumpHost: Bool) -> CitadelSSHSession {
        var config = SSHConfig(host: targetHost, port: 22, username: "user")
        if withJumpHost {
            config.jumpHost = SSHConfig.JumpHostConfig(
                host: bastionHost,
                port: 22,
                username: "admin",
                authMethod: .savedPassword
            )
        }
        return CitadelSSHSession(pty: TerminalPTY(), config: config)
    }

    /// Unwraps the `(host, isJumpHost)` an auth failure is reported under.
    private func authFailure(
        _ error: Error,
        from session: CitadelSSHSession,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (host: String, isJumpHost: Bool)? {
        guard case .authenticationFailed(let host, let isJumpHost)? =
                session.categorizeError(error) as? SSHJumpError else {
            XCTFail("expected SSHJumpError.authenticationFailed", file: file, line: line)
            return nil
        }
        return (host, isJumpHost)
    }

    // MARK: - The three cases

    /// A failure while the BASTION handshake is in flight is the bastion's.
    /// This is the case that was always right, and it must stay right — a fix
    /// for the target case that simply inverts the answer would break here.
    func testAuthFailureDuringBastionHandshakeIsAttributedToTheBastion() {
        let session = makeSession(withJumpHost: true)
        session.transition(to: .authenticating(host: bastionHost, isJumpHost: true))

        let hop = authFailure(SSHClientError.allAuthenticationOptionsFailed, from: session)

        XCTAssertEqual(hop?.host, bastionHost)
        XCTAssertEqual(hop?.isJumpHost, true)
    }

    /// THE DEFECT. The bastion authenticated, the tunnelled target handshake
    /// began, and the TARGET rejected the credential. With a jump host
    /// configured throughout, this must still be attributed to the target.
    ///
    /// Goes red if `failedHopAttribution` reads `config.jumpHost != nil` (or any
    /// other "a bastion exists" test) instead of `connectionHop`, and red if
    /// `transition(to:)` stops moving the hop back to `.target` on
    /// `.authenticatingTarget`.
    func testTargetAuthFailureAfterBastionSucceedsIsAttributedToTheTargetNotTheBastion() {
        let session = makeSession(withJumpHost: true)
        session.transition(to: .connecting(host: bastionHost, isJumpHost: true))
        session.transition(to: .authenticating(host: bastionHost, isJumpHost: true))
        session.transition(to: .authenticatingTarget(host: targetHost))

        let hop = authFailure(SSHClientError.allAuthenticationOptionsFailed, from: session)

        XCTAssertEqual(
            hop?.host, targetHost,
            "a target rejection reported as the bastion's aims the retry prompt at the wrong host"
        )
        XCTAssertEqual(
            hop?.isJumpHost, false,
            "isJumpHost true here writes the target's password into the bastion's Keychain row"
        )
    }

    /// `.connectingToTarget` is the other state that means "past the bastion",
    /// and it must move attribution the same way `.authenticatingTarget` does.
    ///
    /// Goes red if only one of the two target states is handled in
    /// `transition(to:)` — a partial fix that leaves the defect alive on the
    /// path where the failure surfaces during the tunnelled connect.
    func testFailureAfterConnectingToTargetIsAttributedToTheTarget() {
        let session = makeSession(withJumpHost: true)
        session.transition(to: .authenticating(host: bastionHost, isJumpHost: true))
        session.transition(to: .connectingToTarget(host: targetHost))

        let hop = authFailure(SSHClientError.allAuthenticationOptionsFailed, from: session)

        XCTAssertEqual(hop?.host, targetHost)
        XCTAssertEqual(hop?.isJumpHost, false)
    }

    /// No bastion at all: a direct connection blames the host the user named.
    func testAuthFailureWithNoJumpHostIsAttributedToTheTarget() {
        let session = makeSession(withJumpHost: false)
        session.transition(to: .authenticating(host: targetHost, isJumpHost: false))

        let hop = authFailure(SSHClientError.allAuthenticationOptionsFailed, from: session)

        XCTAssertEqual(hop?.host, targetHost)
        XCTAssertEqual(hop?.isJumpHost, false)
    }

    // MARK: - Edges that keep the attribution honest

    /// Before any hop has begun, nothing has rejected a credential — and with a
    /// bastion configured, the safe default is still the host the user typed.
    ///
    /// Goes red if `connectionHop` is initialised to `.jumpHost` "because there
    /// is a bastion", which is the exact reasoning the defect came from.
    func testAttributionDefaultsToTheTargetBeforeAnyHopBegins() {
        let session = makeSession(withJumpHost: true)

        let hop = authFailure(SSHClientError.allAuthenticationOptionsFailed, from: session)

        XCTAssertEqual(hop?.host, targetHost)
        XCTAssertEqual(hop?.isJumpHost, false)
    }

    /// `.failed` is emitted immediately BEFORE `categorizeError` runs, so a
    /// state that names no hop must leave the recorded hop alone. Clearing it
    /// would erase the very attribution the next line reads.
    ///
    /// Goes red if `transition(to:)` gains a `case .failed: connectionHop =
    /// .target` (or any reset in its `default:` arm): a bastion rejection would
    /// then be reported as the target's.
    func testStatesThatNameNoHopDoNotClearTheRecordedAttribution() {
        let session = makeSession(withJumpHost: true)
        session.transition(to: .authenticating(host: bastionHost, isJumpHost: true))
        session.transition(to: .failed)

        let hop = authFailure(SSHClientError.allAuthenticationOptionsFailed, from: session)

        XCTAssertEqual(hop?.host, bastionHost)
        XCTAssertEqual(hop?.isJumpHost, true)
    }

    /// A host-key rejection uses the same attribution as an auth failure: the
    /// target's host key is validated during the tunnelled `jump(to:)`, long
    /// after the bastion's was accepted.
    ///
    /// Goes red if the host-key branch of `categorizeError` reverts to
    /// `config.jumpHost != nil` — the user would be asked to trust the wrong
    /// host's key, and a "yes" would pin a fingerprint against the bastion.
    func testHostKeyRejectionAfterTheBastionIsAttributedToTheTarget() {
        let session = makeSession(withJumpHost: true)
        session.transition(to: .authenticating(host: bastionHost, isJumpHost: true))
        session.transition(to: .authenticatingTarget(host: targetHost))

        guard case .hostKeyRejected(let host, let isJumpHost)? =
                session.categorizeError(HostKeyRejectedError()) as? SSHJumpError else {
            return XCTFail("expected SSHJumpError.hostKeyRejected")
        }

        XCTAssertEqual(host, targetHost)
        XCTAssertEqual(isJumpHost, false)
    }

    /// A host-key rejection during the BASTION handshake is the bastion's.
    /// Pairs with the test above so neither direction can be satisfied by a
    /// constant.
    func testHostKeyRejectionDuringTheBastionHandshakeIsAttributedToTheBastion() {
        let session = makeSession(withJumpHost: true)
        session.transition(to: .connecting(host: bastionHost, isJumpHost: true))

        guard case .hostKeyRejected(let host, let isJumpHost)? =
                session.categorizeError(HostKeyRejectedError()) as? SSHJumpError else {
            return XCTFail("expected SSHJumpError.hostKeyRejected")
        }

        XCTAssertEqual(host, bastionHost)
        XCTAssertEqual(isJumpHost, true)
    }

    /// Every auth-failure variant Citadel can raise routes through the same
    /// attribution, so none of them can regress independently.
    ///
    /// Goes red if a new `SSHClientError` arm is given its own hard-coded host
    /// instead of `failedHopAttribution`.
    func testAllAuthFailureVariantsShareTheSameHopAttribution() {
        let variants: [SSHClientError] = [
            .allAuthenticationOptionsFailed,
            .unsupportedPasswordAuthentication,
            .unsupportedPrivateKeyAuthentication,
            .unsupportedKeyboardInteractiveAuthentication,
            .unsupportedHostBasedAuthentication,
        ]

        for variant in variants {
            let session = makeSession(withJumpHost: true)
            session.transition(to: .authenticating(host: bastionHost, isJumpHost: true))
            session.transition(to: .authenticatingTarget(host: targetHost))

            let hop = authFailure(variant, from: session)
            XCTAssertEqual(hop?.host, targetHost, "\(variant) mis-attributed")
            XCTAssertEqual(hop?.isJumpHost, false, "\(variant) mis-attributed")
        }
    }

    /// A bastion recorded as the failing hop but absent from the config falls
    /// back to the target rather than force-unwrapping. Naming a bastion the
    /// session cannot identify would be worse than a crash — it would prompt
    /// for a host that is not in the connection.
    ///
    /// Goes red if the `guard let jump = config.jumpHost` in
    /// `failedHopAttribution` becomes a force-unwrap.
    func testJumpHopWithNoJumpConfigFallsBackToTheTargetInsteadOfTrapping() {
        let session = makeSession(withJumpHost: false)
        session.transition(to: .authenticating(host: bastionHost, isJumpHost: true))

        let hop = authFailure(SSHClientError.allAuthenticationOptionsFailed, from: session)

        XCTAssertEqual(hop?.host, targetHost)
        XCTAssertEqual(hop?.isJumpHost, false)
    }
}
