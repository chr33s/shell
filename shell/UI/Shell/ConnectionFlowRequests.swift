//
//  ConnectionFlowRequests.swift
//  shell
//
//  Presentation payloads for the connection flows MainView drives. Each
//  request carries everything its sheet needs and is presented with
//  `.sheet(item:)`, so a visible prompt without its profile, config, or
//  placement is not representable, and dismissing the sheet drops the whole
//  request at once rather than leaving individual fields armed.
//

import SwiftUI

/// What the connection sheet was opened to do. One-shot: it belongs to a
/// single presentation of the sheet.
struct ConnectionSheetPrefill {
    /// Prefilled editor contents.
    let config: SSHConfig
    /// Set only when the sheet was opened because an existing pane's session
    /// needs new credentials. Nil for a deep-link prefill, which opens a new
    /// session wherever the user asks.
    let reconnectTarget: ReconnectTarget?
}

/// A saved profile needs a password before it can connect.
struct PasswordPromptRequest: Identifiable {
    let id = UUID()
    let profile: ConnectionProfile
    let splitOption: SSHConnectionView.SplitOption
}

/// A connection references identities this device cannot resolve yet.
struct KeyResolutionRequest: Identifiable {
    let id = UUID()
    /// The config with every resolvable identity already substituted.
    let config: SSHConfig
    let unresolvedKeys: [UnresolvedKeyInfo]
    /// The profile the connection came from, if any; resolved identities are
    /// written back to it and the new session is attributed to it.
    let profileID: UUID?
    let splitOption: SSHConnectionView.SplitOption
}
