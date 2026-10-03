//
//  LocalSSHAgentProtocolTests.swift
//  ShellTests
//
//  Framing and request dispatch of the local SSH agent
//  (ssh-agent-bridge-spec.md §8, §18.1).
//

import Foundation
import Testing
import NIOCore
import Citadel

@testable import Shell

@Suite
struct LocalSSHAgentProtocolTests {

    // MARK: - Framing

    private func frames(from chunks: [[UInt8]]) throws -> [[UInt8]] {
        var buffer = ByteBuffer()
        var out: [[UInt8]] = []
        for chunk in chunks {
            buffer.writeBytes(chunk)
            while let frame = try LocalSSHAgentFrameDecoder.nextFrame(from: &buffer) {
                out.append(Array(frame.readableBytesView))
            }
        }
        return out
    }

    @Test
    func testOneRequestInOneRead() throws {
        #expect(try frames(from: [AgentWire.frame([11])]) == [[11]])
    }

    @Test
    func testHeaderSplitAcrossReads() throws {
        let frame = AgentWire.frame([11])
        #expect(try frames(from: [Array(frame[0..<2]), Array(frame[2...])]) == [[11]])
    }

    @Test
    func testPayloadSplitAcrossReads() throws {
        let payload: [UInt8] = [27] + AgentWire.string("query")
        let frame = AgentWire.frame(payload)
        let split = [Array(frame[0..<6]), Array(frame[6..<9]), Array(frame[9...])]
        #expect(try frames(from: split) == [payload])
    }

    @Test
    func testMultipleRequestsInOneRead() throws {
        let joined = AgentWire.frame([11]) + AgentWire.frame([17, 1, 2]) + AgentWire.frame([11])
        #expect(try frames(from: [joined]) == [[11], [17, 1, 2], [11]])
    }

    @Test
    func testOversizedLengthRejectedBeforeThePayloadArrives() throws {
        // Only the header: the decoder must refuse without waiting for (or
        // reserving) the 4 GiB it announces.
        var buffer = ByteBuffer(bytes: [0xFF, 0xFF, 0xFF, 0xFF])
        #expect(throws: LocalSSHAgentFrameDecoder.FrameError.frameTooLarge(.max)) {
            _ = try LocalSSHAgentFrameDecoder.nextFrame(from: &buffer)
        }
    }

    @Test
    func testLengthAtTheCapIsAccepted() throws {
        let length = UInt32(LocalSSHAgentFrameDecoder.maxFrameLength)
        var buffer = ByteBuffer()
        buffer.writeInteger(length)
        #expect(try LocalSSHAgentFrameDecoder.nextFrame(from: &buffer) == nil)  // waits for data
        var over = ByteBuffer()
        over.writeInteger(length + 1)
        #expect(throws: (any Error).self) { _ = try LocalSSHAgentFrameDecoder.nextFrame(from: &over) }
    }

    // MARK: - Dispatch

    private func respond(_ payload: [UInt8], source: FakeAgentKeySource = FakeAgentKeySource(keys: [])) async -> [UInt8] {
        let responder = LocalSSHAgentResponder(delegate: ShellSSHAgentDelegate(source: source))
        let framed = await responder.respond(to: ByteBuffer(bytes: payload))
        var buffer = framed
        let length = buffer.readInteger(as: UInt32.self)
        #expect(length == UInt32(buffer.readableBytes))
        return Array(buffer.readableBytesView)
    }

    @Test
    func testEmptyIdentityList() async {
        #expect(await respond([11]) == [12, 0, 0, 0, 0])
    }

    @Test
    func testUnknownMessageTypeFails() async {
        #expect(await respond([200]) == [5])
    }

    @Test(arguments: [
        UInt8(17),  // add identity
        UInt8(25),  // add constrained identity
        UInt8(18),  // remove identity
        UInt8(19),  // remove all identities
        UInt8(20),  // add smartcard key
        UInt8(21),  // remove smartcard key
        UInt8(22),  // lock
        UInt8(23)   // unlock
    ])
    func testMutationAndLockRequestsFail(type: UInt8) async {
        #expect(await respond([type] + AgentWire.string("ignored")) == [5])
    }

    @Test
    func testExtensionRequestReturnsExtensionFailure() async {
        #expect(await respond([27] + AgentWire.string("session-bind@openssh.com")) == [28])
    }

    @Test
    func testMalformedSignRequestFails() async {
        // Declares a 100-byte key blob but ends after two bytes.
        #expect(await respond([13, 0, 0, 0, 100, 1, 2]) == [5])
    }

    @Test
    func testEmptyPayloadFails() async {
        #expect(await respond([]) == [5])
    }

    @Test
    func testAgentResponseTypesSentToTheAgentFail() async {
        #expect(await respond([6]) == [5])
        #expect(await respond([12, 0, 0, 0, 0]) == [5])
    }

    @Test
    func testSignRequestForUnknownBlobFails() async throws {
        let key = try AgentTestKey.make(.ed25519)
        let source = FakeAgentKeySource(keys: [key])
        let other = try AgentTestKey.make(.ed25519)
        let reply = await respond(AgentWire.signRequest(blob: other.blob, data: [1, 2, 3], flags: 0), source: source)
        #expect(reply == [5])
        #expect(source.loads.isEmpty)
    }

    @Test
    func testSignRequestReturnsSignResponse() async throws {
        let key = try AgentTestKey.make(.ed25519)
        let reply = await respond(
            AgentWire.signRequest(blob: key.blob, data: [1, 2, 3], flags: 0),
            source: FakeAgentKeySource(keys: [key])
        )
        #expect(reply.first == 14)
        var buffer = ByteBuffer(bytes: reply.dropFirst())
        let signature = try #require(AgentWire.readString(&buffer))
        #expect(buffer.readableBytes == 0)
        let result = try AgentSignatureVerifier.verify(signatureBlob: signature, publicKeyBlob: key.blob, data: Data([1, 2, 3]))
        #expect(result.valid)
    }
}
