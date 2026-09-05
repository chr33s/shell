//
//  HostAddressCopyMenu.swift
//  shell
//
//  Shared long-press actions for copying host connection addresses.
//

import SwiftUI
import UIKit

/// Context-menu actions for the host addresses available on a row.
struct HostAddressCopyActions: View {
    let hostname: String?
    let ipAddress: String?

    init(hostname: String? = nil, ipAddress: String? = nil) {
        self.hostname = Self.nonEmpty(hostname)
        self.ipAddress = Self.nonEmpty(ipAddress)
    }

    var body: some View {
        if let hostname {
            Button {
                UIPasteboard.general.string = hostname
            } label: {
                Label("Copy Hostname", systemImage: "doc.on.doc")
            }
        }

        if let ipAddress, ipAddress != hostname {
            Button {
                UIPasteboard.general.string = ipAddress
            } label: {
                Label("Copy IP Address", systemImage: "doc.on.doc")
            }
        }
    }

    static func hasActions(hostname: String?, ipAddress: String?) -> Bool {
        nonEmpty(hostname) != nil || nonEmpty(ipAddress) != nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}

private struct HostAddressCopyMenuModifier: ViewModifier {
    let hostname: String?
    let ipAddress: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if HostAddressCopyActions.hasActions(hostname: hostname, ipAddress: ipAddress) {
            content.contextMenu {
                HostAddressCopyActions(hostname: hostname, ipAddress: ipAddress)
            }
        } else {
            content
        }
    }
}

extension View {
    /// Adds long-press/right-click copy actions when at least one address exists.
    func hostAddressCopyMenu(hostname: String? = nil, ipAddress: String? = nil) -> some View {
        modifier(HostAddressCopyMenuModifier(hostname: hostname, ipAddress: ipAddress))
    }
}
