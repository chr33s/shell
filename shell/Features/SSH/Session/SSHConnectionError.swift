//
//  SSHConnectionError.swift
//  shell
//
//  User-facing errors translated from opaque NIO/NIOSSH error types
//

import Foundation
import NIOPosix
import NIOSSH

/// Errors translated from opaque NIO error types into user-facing messages.
/// NIOSSHError and NIOConnectionError conform to Error but not LocalizedError,
/// so when bridged to NSError all instances get code 1 and the actual error type is lost.
enum SSHConnectionError: LocalizedError {
    /// No common algorithms found during key exchange negotiation
    case algorithmNegotiationFailed(host: String)

    /// SSH protocol violation
    case protocolError(host: String, detail: String)

    /// Remote peer's SSH version is unsupported
    case unsupportedVersion(host: String, detail: String)

    /// TCP connection was lost unexpectedly
    case connectionLost(host: String)

    /// TCP connection failed (Happy Eyeballs / DNS / connection refused)
    case connectionFailed(host: String, port: Int, detail: String)

    /// Catch-all for other NIOSSHError types
    case sshError(host: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .algorithmNegotiationFailed(let host):
            return "Algorithm negotiation failed with \(host). The server may require a cipher or key exchange method not supported by this app."
        case .protocolError(let host, let detail):
            return "SSH protocol error with \(host): \(detail)"
        case .unsupportedVersion(let host, _):
            return "Unsupported SSH version on \(host)"
        case .connectionLost(let host):
            return "Connection to \(host) was lost"
        case .connectionFailed(let host, let port, let detail):
            return "Could not connect to \(host):\(port) — \(detail)"
        case .sshError(let host, let detail):
            return "SSH error with \(host): \(detail)"
        }
    }

    /// Creates an SSHConnectionError from an NIOSSHError
    init(nioSSHError: NIOSSHError, host: String) {
        let detail = String(describing: nioSSHError)

        if nioSSHError.type == .keyExchangeNegotiationFailure {
            self = .algorithmNegotiationFailed(host: host)
        } else if nioSSHError.type == .protocolViolation {
            self = .protocolError(host: host, detail: detail)
        } else if nioSSHError.type == .unsupportedVersion {
            self = .unsupportedVersion(host: host, detail: detail)
        } else if nioSSHError.type == .tcpShutdown {
            self = .connectionLost(host: host)
        } else {
            self = .sshError(host: host, detail: detail)
        }
    }

    /// Creates an SSHConnectionError from an NIOConnectionError
    init(nioConnectionError: NIOConnectionError, host: String) {
        let port = nioConnectionError.port

        // Build a human-readable detail from the underlying failures
        if let dnsError = nioConnectionError.dnsAError ?? nioConnectionError.dnsAAAAError {
            self = .connectionFailed(host: host, port: port, detail: "DNS resolution failed: \(dnsError)")
        } else if let firstFailure = nioConnectionError.connectionErrors.first {
            // Use the first connection error's underlying reason
            let reason = String(describing: firstFailure.error)
            self = .connectionFailed(host: host, port: port, detail: reason)
        } else {
            self = .connectionFailed(host: host, port: port, detail: String(describing: nioConnectionError))
        }
    }
}
