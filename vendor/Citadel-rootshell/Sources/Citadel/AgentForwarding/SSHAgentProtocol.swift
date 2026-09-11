//===----------------------------------------------------------------------===//
//
// This source file is part of the Citadel open source project
//
// Copyright (c) 2025 Citadel contributors
// Licensed under Apache License v2.0
//
//===----------------------------------------------------------------------===//

import NIOCore

// MARK: - Message Types

/// SSH agent protocol message types.
///
/// Based on the SSH agent protocol specification (draft-miller-ssh-agent).
public enum SSHAgentMessageType: UInt8 {
    // Request types (client -> agent)
    case requestIdentities = 11        // SSH_AGENTC_REQUEST_IDENTITIES
    case signRequest = 13              // SSH_AGENTC_SIGN_REQUEST
    case addIdentity = 17              // SSH_AGENTC_ADD_IDENTITY
    case removeIdentity = 18           // SSH_AGENTC_REMOVE_IDENTITY
    case removeAllIdentities = 19      // SSH_AGENTC_REMOVE_ALL_IDENTITIES
    case addSmartcardKey = 20          // SSH_AGENTC_ADD_SMARTCARD_KEY
    case removeSmartcardKey = 21       // SSH_AGENTC_REMOVE_SMARTCARD_KEY
    case lock = 22                     // SSH_AGENTC_LOCK
    case unlock = 23                   // SSH_AGENTC_UNLOCK
    case addIdConstrained = 25         // SSH_AGENTC_ADD_ID_CONSTRAINED
    case extensionRequest = 27         // SSH_AGENTC_EXTENSION

    // Response types (agent -> client)
    case failure = 5                   // SSH_AGENT_FAILURE
    case success = 6                   // SSH_AGENT_SUCCESS
    case identitiesAnswer = 12         // SSH_AGENT_IDENTITIES_ANSWER
    case signResponse = 14             // SSH_AGENT_SIGN_RESPONSE
    case extensionFailure = 28         // SSH_AGENT_EXTENSION_FAILURE
}

// MARK: - Parsed Messages

/// Parsed SSH agent protocol message.
public enum SSHAgentMessage: Sendable {
    /// Request to list all identities.
    case requestIdentities

    /// Request to sign data with a specific key.
    case signRequest(SSHAgentSignRequest)

    /// Extension request (e.g., session-bind@openssh.com).
    case extensionRequest(SSHAgentExtensionRequest)

    /// Response containing the list of identities.
    case identitiesAnswer([SSHAgentIdentity])

    /// Response containing a signature.
    case signResponse(ByteBuffer)

    /// Failure response.
    case failure

    /// Success response.
    case success

    /// Extension failure response.
    case extensionFailure

    /// Unknown or unsupported message type.
    case unknown(UInt8)
}

/// A sign request from the remote server.
public struct SSHAgentSignRequest: Sendable {
    /// The public key blob identifying which key to use.
    public let publicKeyBlob: ByteBuffer

    /// The data to be signed.
    public let data: ByteBuffer

    /// Signature flags.
    public let flags: UInt32

    public init(publicKeyBlob: ByteBuffer, data: ByteBuffer, flags: UInt32) {
        self.publicKeyBlob = publicKeyBlob
        self.data = data
        self.flags = flags
    }
}

/// An extension request from the remote server.
public struct SSHAgentExtensionRequest: Sendable {
    /// The extension name (e.g., "session-bind@openssh.com").
    public let extensionName: String

    /// The extension-specific data.
    public let contents: ByteBuffer

    public init(extensionName: String, contents: ByteBuffer) {
        self.extensionName = extensionName
        self.contents = contents
    }
}

// MARK: - Parser

/// Parser for SSH agent protocol messages.
public struct SSHAgentMessageParser {
    private init() {}

    /// Parses an SSH agent message from a buffer.
    ///
    /// The buffer should contain only the message payload (without length prefix).
    ///
    /// - Parameter buffer: The buffer containing the message.
    /// - Returns: The parsed message.
    /// - Throws: If the message is malformed.
    public static func parse(_ buffer: inout ByteBuffer) throws -> SSHAgentMessage {
        guard let typeRaw = buffer.readInteger(as: UInt8.self) else {
            throw SSHAgentError.malformedMessage
        }

        guard let type = SSHAgentMessageType(rawValue: typeRaw) else {
            return .unknown(typeRaw)
        }

        switch type {
        case .requestIdentities:
            return .requestIdentities

        case .signRequest:
            guard let publicKeyBlob = buffer.readSSHBuffer(),
                  let data = buffer.readSSHBuffer(),
                  let flags = buffer.readInteger(as: UInt32.self) else {
                throw SSHAgentError.malformedMessage
            }
            return .signRequest(SSHAgentSignRequest(
                publicKeyBlob: publicKeyBlob,
                data: data,
                flags: flags
            ))

        case .identitiesAnswer:
            guard let count = buffer.readInteger(as: UInt32.self) else {
                throw SSHAgentError.malformedMessage
            }
            var identities: [SSHAgentIdentity] = []
            for _ in 0..<count {
                guard let blob = buffer.readSSHBuffer(),
                      let comment = buffer.readSSHString() else {
                    throw SSHAgentError.malformedMessage
                }
                identities.append(SSHAgentIdentity(publicKeyBlob: blob, comment: comment))
            }
            return .identitiesAnswer(identities)

        case .signResponse:
            guard let signature = buffer.readSSHBuffer() else {
                throw SSHAgentError.malformedMessage
            }
            return .signResponse(signature)

        case .failure:
            return .failure

        case .success:
            return .success

        case .extensionRequest:
            guard let extensionName = buffer.readSSHString() else {
                throw SSHAgentError.malformedMessage
            }
            // The rest of the buffer is extension-specific contents
            let contents = buffer.readSlice(length: buffer.readableBytes) ?? ByteBuffer()
            return .extensionRequest(SSHAgentExtensionRequest(
                extensionName: extensionName,
                contents: contents
            ))

        case .extensionFailure:
            return .extensionFailure

        default:
            return .unknown(typeRaw)
        }
    }
}

// MARK: - Serializer

/// Serializer for SSH agent protocol messages.
public struct SSHAgentMessageSerializer {
    private init() {}

    /// Serializes an SSH agent message to a buffer.
    ///
    /// The returned buffer includes the 4-byte length prefix.
    ///
    /// - Parameter message: The message to serialize.
    /// - Returns: A buffer containing the serialized message with length prefix.
    public static func serialize(_ message: SSHAgentMessage, allocator: ByteBufferAllocator = ByteBufferAllocator()) -> ByteBuffer {
        var payload = allocator.buffer(capacity: 256)

        switch message {
        case .requestIdentities:
            payload.writeInteger(SSHAgentMessageType.requestIdentities.rawValue)

        case .signRequest(let request):
            payload.writeInteger(SSHAgentMessageType.signRequest.rawValue)
            var blob = request.publicKeyBlob
            payload.writeSSHString(&blob)
            var data = request.data
            payload.writeSSHString(&data)
            payload.writeInteger(request.flags)

        case .identitiesAnswer(let identities):
            payload.writeInteger(SSHAgentMessageType.identitiesAnswer.rawValue)
            payload.writeInteger(UInt32(identities.count))
            for identity in identities {
                var blob = identity.publicKeyBlob
                payload.writeSSHString(&blob)
                payload.writeSSHString(identity.comment)
            }

        case .signResponse(var signature):
            payload.writeInteger(SSHAgentMessageType.signResponse.rawValue)
            payload.writeSSHString(&signature)

        case .failure:
            payload.writeInteger(SSHAgentMessageType.failure.rawValue)

        case .success:
            payload.writeInteger(SSHAgentMessageType.success.rawValue)

        case .extensionFailure:
            payload.writeInteger(SSHAgentMessageType.extensionFailure.rawValue)

        case .extensionRequest(let request):
            payload.writeInteger(SSHAgentMessageType.extensionRequest.rawValue)
            payload.writeSSHString(request.extensionName)
            var contents = request.contents
            payload.writeBuffer(&contents)

        case .unknown(let typeRaw):
            payload.writeInteger(typeRaw)
        }

        // Create final buffer with length prefix
        var result = allocator.buffer(capacity: 4 + payload.readableBytes)
        result.writeInteger(UInt32(payload.readableBytes))
        result.writeBuffer(&payload)
        return result
    }
}

// MARK: - Errors

/// Errors that can occur during SSH agent protocol handling.
public enum SSHAgentError: Error {
    /// The message is malformed or incomplete.
    case malformedMessage

    /// The requested key was not found.
    case keyNotFound

    /// The signing request was denied.
    case signingDenied

    /// An internal error occurred.
    case internalError(String)
}

