//
//  SessionApprovedHostKeys.swift
//  shell
//
//  In-memory host keys the user approved with "Connect Once" during this app
//  run. Nothing is persisted. Lets ancillary connections in the same
//  user-visible flow (tmux/zellij session discovery, hole punching) reuse the
//  exact key the user already approved, instead of strict-rejecting a host
//  whose key was deliberately not saved.
//

import Foundation

@MainActor
final class SessionApprovedHostKeys {
    static let shared = SessionApprovedHostKeys()

    /// "hostname:port" -> base64 public key blob approved once this run.
    private var approved: [String: String] = [:]

    private init() {}

    func remember(hostname: String, port: Int, publicKeyData: String) {
        approved["\(hostname):\(port)"] = publicKeyData
    }

    /// True only when the presented key is byte-identical to the one the user
    /// approved for this exact host:port earlier in this app run.
    func matches(hostname: String, port: Int, publicKeyData: String) -> Bool {
        approved["\(hostname):\(port)"] == publicKeyData
    }
}
