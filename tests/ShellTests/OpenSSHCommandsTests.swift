//
//  OpenSSHCommandsTests.swift
//  ShellTests
//
//  The OpenSSH clients the local SSH agent serves (Packages/OpenSSHCommands):
//  embedded where expected, loadable, and every registered command names an
//  entry point the framework actually exports.
//

import Foundation
import Testing

@testable import Shell

@Suite
struct OpenSSHCommandsTests {

    @Test
    func testFrameworkIsEmbeddedOnIOSAndCatalyst() {
        #if os(iOS)
        #expect(LocalSSHAgent.hasOpenSSHClients)
        #else
        #expect(!LocalSSHAgent.hasOpenSSHClients)
        #endif
    }

    @Test(.enabled(if: LocalSSHAgent.hasOpenSSHClients, "ssh_cmd.framework is not embedded in this build"))
    func testEveryRegisteredCommandResolves() throws {
        let plist = try #require(Bundle.main.url(forResource: "sshCommandsDictionary", withExtension: "plist"))
        let commands = try #require(NSDictionary(contentsOf: plist) as? [String: [String]])
        #expect(Set(commands.keys) == ["ssh", "scp", "sftp", "openssh"])

        let frameworks = try #require(Bundle.main.privateFrameworksPath)
        for (name, entry) in commands {
            let binary = frameworks + "/" + entry[0]
            let handle = try #require(dlopen(binary, RTLD_NOW), "\(name): \(String(cString: dlerror()))")
            #expect(dlsym(handle, entry[1]) != nil, "\(name): \(entry[1]) not exported")
        }
    }
}
