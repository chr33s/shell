import Foundation
import Testing

@testable import Shell

/// Pins the local shell's `ssh` contract: it is Shell-native and interactive
/// only. There is no bundled OpenSSH to fall back to, so a form the native
/// path cannot honour must fail explicitly instead of being silently ignored
/// or handed to ios_system.
@MainActor
@Suite
final class SSHNativeCommandContractTests {

    private let defaultKeyID = UUID()

    init() {
        // A default identity makes every well-formed line resolve to
        // `.success`, so assertions are about the parsed config.
        let keyID = defaultKeyID
        SSHCommandParser.credentials = SSHCommandParser.CredentialSources(
            hasSavedPassword: { _, _, _ in false },
            keyIDForIdentityPath: { _ in nil },
            defaultKeyIDs: { [keyID] }
        )
    }

    isolated deinit {
        SSHCommandParser.credentials = .live
    }

    private struct UnexpectedParseResult: Error {}

    private func parsed(_ command: String) throws -> SSHConfig {
        switch SSHCommandParser.parse(command: command) {
        case .success(let config):
            return config
        case .error(let message):
            Issue.record("parse failed: \(message)")
        case .needsPassword, .help:
            Issue.record("expected .success")
        }
        throw UnexpectedParseResult()
    }

    private func error(_ command: String) -> String? {
        if case .error(let message) = SSHCommandParser.parse(command: command) {
            return message
        }
        return nil
    }

    // MARK: - Supported forms

    @Test
    func testPlainDestination() throws {
        let config = try parsed("ssh user@host.example.com")
        #expect(config.host == "host.example.com")
        #expect(config.username == "user")
        #expect(config.port == 22)
    }

    @Test
    func testPortAndUserFlags() throws {
        let config = try parsed("ssh -p 2222 user@host")
        #expect(config.port == 2222)
        #expect(config.username == "user")

        let byFlag = try parsed("ssh -l admin host")
        #expect(byFlag.username == "admin")
        #expect(byFlag.host == "host")
    }

    @Test
    func testAttachedFlagValues() throws {
        let config = try parsed("ssh -p2222 -ladmin host")
        #expect(config.port == 2222)
        #expect(config.username == "admin")
    }

    @Test
    func testSupportedConnectionOptions() throws {
        let config = try parsed("ssh -o Port=2200 -o user=bob -o \"ProxyJump jump@bastion\" host")
        #expect(config.port == 2200)
        #expect(config.username == "bob")
        #expect(config.jumpHost?.host == "bastion")
        #expect(config.jumpHost?.username == "jump")
    }

    @Test
    func testJumpHostStaysNative() throws {
        let config = try parsed("ssh -J admin@bastion.example.com user@target.example.com")
        #expect(config.host == "target.example.com")
        #expect(config.jumpHost?.host == "bastion.example.com")
        #expect(config.jumpHost?.username == "admin")
    }

    @Test
    func testEndOfOptions() throws {
        let config = try parsed("ssh -p 2022 -- host")
        #expect(config.host == "host")
        #expect(config.port == 2022)
    }

    @Test
    func testHelp() {
        for command in ["ssh", "ssh -h", "ssh --help"] {
            guard case .help = SSHCommandParser.parse(command: command) else {
                Issue.record("\(command) should show help")
                continue
            }
        }
    }

    // MARK: - Refused forms

    /// Flags the native client does not implement must not be accepted with
    /// different routing or security semantics (e.g. `-A`, `-L`).
    @Test
    func testUnsupportedFlagsAreRejected() {
        for flag in ["-A", "-L", "-R", "-D", "-N", "-t", "-v", "-4", "--foo"] {
            let message = error("ssh \(flag) 8080:localhost:80 host")
            #expect(message?.contains("unsupported option: \(flag)") == true, "\(flag)")
        }
    }

    @Test
    func testUnsupportedConnectionOptionsAreRejected() {
        for option in ["ForwardAgent=yes", "RemoteCommand=ls", "StrictHostKeyChecking=no", "LocalForward=1:a:2"] {
            let key = String(option.prefix(while: { $0 != "=" }))
            let message = error("ssh -o \(option) host")
            #expect(message?.contains("unsupported option: -o \(key)") == true, "\(option)")
        }
        #expect(error("ssh -o Port host")?.contains("unsupported option") == true)
        #expect(error("ssh -o Port=abc host") == "Invalid port number")
    }

    @Test
    func testRemoteCommandIsRejected() {
        #expect(error("ssh host uname -a") == SSHCommandParser.remoteCommandUnsupported)
        #expect(error("ssh -p 22 user@host ls") == SSHCommandParser.remoteCommandUnsupported)
    }

    @Test
    func testShellCompositionIsRejected() {
        #expect(error("ssh host ls | grep x") == SSHCommandParser.compositionUnsupported)
        #expect(error("ssh host ls > out.txt") == SSHCommandParser.compositionUnsupported)
    }

    // MARK: - No subprocess fallback

    /// `commandInvokesSSH` is the gate that keeps `ssh` in a pipeline stage,
    /// redirection, `$(...)` capture or background job from reaching
    /// ios_system, which has no `ssh` executable.
    @Test
    func testSubprocessSSHIsDetectedInEveryCommandPosition() {
        for command in [
            "ssh host",
            "ssh host uname > out.txt",
            "ssh host ls | grep x",
            "echo hi | ssh host",
            "X=1 ssh host",
            "true && ssh host",
            "false || ssh host",
            "true; ssh host",
            "(ssh host)",
            "if true; then ssh host; fi",
            "SSH host"
        ] {
            #expect(LocalShellSession.commandInvokesSSH(command), "\(command)")
        }
    }

    @Test
    func testSSHAsArgumentIsNotRefused() {
        for command in [
            "echo ssh",
            "grep ssh /etc/services",
            "sshd -t",
            "for h in ssh scp; do echo $h; done",
            "cat ~/.ssh/config"
        ] {
            #expect(!LocalShellSession.commandInvokesSSH(command), "\(command)")
        }
    }

    // MARK: - Legacy local-agent state

    @Test
    func testLegacyLocalAgentStateIsCleared() throws {
        let suite = "SSHNativeCommandContractTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: "localSSHAgentEnabled")
        defaults.set(true, forKey: "localSSHAgentV2Enabled")
        defaults.set(Data("[\"\(UUID().uuidString)\"]".utf8), forKey: "localSSHAgentAllowedKeyIDs")
        defaults.set(true, forKey: "autoReconnectEnabled")

        LegacyLocalSSHAgentCleanup.run(defaults: defaults)

        // An older build reads these as their defaults: Off, no grants.
        #expect(defaults.object(forKey: "localSSHAgentEnabled") == nil)
        #expect(defaults.object(forKey: "localSSHAgentV2Enabled") == nil)
        #expect(defaults.object(forKey: "localSSHAgentAllowedKeyIDs") == nil)
        #expect(defaults.bool(forKey: "autoReconnectEnabled"))
    }
}
