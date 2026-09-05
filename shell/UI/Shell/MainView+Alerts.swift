//
//  MainView+Alerts.swift
//  shell
//
//  Alert UI for the unified main-alert queue: title, buttons, and messages
//  for the single `.alert` attachment. The queue/state machine itself lives
//  in MainAlertController (owned per-window as `alerts`).
//

import SwiftUI

extension MainView {

    // MARK: - Main Alert UI

    private var mainAlertTitle: String {
        switch alerts.presentedKind {
        case .newHost:
            return alerts.validationData?.alertTitle ?? String(localized: "New SSH Host", comment: "Host key alert title")
        case .keyChanged:
            return alerts.validationData?.alertTitle ?? String(localized: "⚠️ WARNING: Host Key Changed", comment: "Host key alert title")
        case .fileOpenFailed:
            return String(localized: "Couldn't Open File", comment: "Alert title when a shared file fails to import")
        case nil:
            return ""
        }
    }

    private var mainAlertPresented: Binding<Bool> {
        Binding(
            get: { alerts.presentedKind != nil },
            set: { isPresented in
                guard !isPresented else { return }
                // Dismissing a host-key prompt must answer the waiting
                // continuation, never just drop it — a dropped answer leaves
                // the connection hanging.
                switch alerts.presentedKind {
                case .newHost, .keyChanged:
                    alerts.respondToHostKeyValidation(with: .reject)
                case .fileOpenFailed, nil:
                    alerts.completePresented(clearBackingState: true)
                }
            }
        )
    }

    // MARK: - Alert Modifiers

    @ViewBuilder
    func applyAlertModifiers<V: View>(_ view: V) -> some View {
        view
            .alert(mainAlertTitle, isPresented: mainAlertPresented) {
                switch alerts.presentedKind {
                case .newHost:
                    Button("Cancel", role: .cancel) {
                        alerts.respondToHostKeyValidation(with: .reject)
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Connect Once") {
                        alerts.respondToHostKeyValidation(with: .acceptOnce)
                    }
                    Button("Trust & Save") {
                        alerts.respondToHostKeyValidation(with: .accept)
                    }
                    .keyboardShortcut(.defaultAction)
                case .keyChanged:
                    Button("Cancel Connection", role: .cancel) {
                        alerts.respondToHostKeyValidation(with: .reject)
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Replace & Connect", role: .destructive) {
                        alerts.respondToHostKeyValidation(with: .accept)
                    }
                    .keyboardShortcut(.defaultAction)
                case .fileOpenFailed:
                    Button("OK", role: .cancel) {
                        alerts.dismissActive()
                    }
                case nil:
                    EmptyView()
                }
            } message: {
                switch alerts.presentedKind {
                case .newHost, .keyChanged:
                    if let message = alerts.validationData?.message {
                        Text(message)
                    }
                case .fileOpenFailed:
                    if let message = alerts.fileOpenErrorMessage {
                        Text(message)
                    }
                case nil:
                    EmptyView()
                }
            }
    }
}
