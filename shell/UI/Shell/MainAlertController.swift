//
//  MainAlertController.swift
//  shell
//
//  Unified main-alert state machine for MainView. One instance per window
//  (owned via @State), so each window queues and presents its own alerts.
//
//  Owns: the presented/pending alert-kind queue, the per-kind backing flags,
//  and the SSH host-key validation continuation. The alert UI itself (title,
//  buttons, messages, applyAlertModifiers) stays on MainView in
//  MainView+Alerts.swift and reads this controller.
//

import SwiftUI
import os

@MainActor @Observable final class MainAlertController {

    /// The kinds of alert routed through the single unified `.alert`
    /// attachment. Queued so concurrent triggers present one at a time.
    enum Kind: Equatable {
        case newHost
        case keyChanged
        case fileOpenFailed
    }

    /// The alert currently on screen (nil = none). Writes go through
    /// enqueue/completePresented so queue mechanics stay consistent.
    private(set) var presentedKind: Kind?
    private var pendingKinds: [Kind] = []

    // MARK: - Backing state (one flag per kind)

    // Host key validation state
    @ObservationIgnored var hostKeyValidationContinuation: CheckedContinuation<HostKeyValidationResult, Never>?
    var showNewHostAlert = false
    var showKeyChangedAlert = false
    var validationData: MainView.ValidationData?

    /// A shared file failed to import.
    var fileOpenErrorMessage: String?
    var showFileOpenFailedAlert = false

    // MARK: - Queue mechanics

    func enqueue(_ kind: Kind) {
        guard isAvailable(kind) else { return }
        if presentedKind == nil {
            presentedKind = kind
            return
        }
        guard presentedKind != kind,
              !pendingKinds.contains(kind) else { return }
        pendingKinds.append(kind)
    }

    private func isAvailable(_ kind: Kind) -> Bool {
        switch kind {
        case .newHost: return showNewHostAlert
        case .keyChanged: return showKeyChangedAlert
        case .fileOpenFailed: return showFileOpenFailedAlert
        }
    }

    private func presentNext() {
        guard presentedKind == nil else { return }
        while !pendingKinds.isEmpty {
            let next = pendingKinds.removeFirst()
            if isAvailable(next) {
                presentedKind = next
                return
            }
        }
    }

    func dismissActive() {
        completePresented(clearBackingState: true)
    }

    func completePresented(clearBackingState: Bool) {
        guard let kind = presentedKind else { return }
        presentedKind = nil

        if clearBackingState {
            self.clearBackingState(kind)
        }

        DispatchQueue.main.async {
            self.presentNext()
        }
    }

    private func clearBackingState(_ kind: Kind) {
        switch kind {
        case .newHost:
            showNewHostAlert = false
        case .keyChanged:
            showKeyChangedAlert = false
        case .fileOpenFailed:
            showFileOpenFailedAlert = false
            fileOpenErrorMessage = nil
        }
    }

    // MARK: - Shared-File Open Failure

    func handleFileOpenFailure(message: String) {
        fileOpenErrorMessage = message
        showFileOpenFailedAlert = true
        enqueue(.fileOpenFailed)
    }

    // MARK: - SSH Host Key Validation

    func handleHostKeyValidation(
        request: HostKeyValidationRequest,
        terminalView: Ghostty.TerminalView
    ) async -> HostKeyValidationResult {
        await withCheckedContinuation { continuation in
            let sessionLabel = terminalView.connectionConfig.displayName
            let alertContext = "(\(sessionLabel))"

            validationData = MainView.ValidationData(
                alertTitle: request.isKeyChanged
                    ? "⚠️ WARNING: Host Key Changed \(alertContext)"
                    : "New SSH Host \(alertContext)",
                message: request.message,
                isKeyChanged: request.isKeyChanged
            )

            hostKeyValidationContinuation = continuation

            if request.isKeyChanged {
                showKeyChangedAlert = true
                enqueue(.keyChanged)
            } else {
                showNewHostAlert = true
                enqueue(.newHost)
            }
        }
    }

    func respondToHostKeyValidation(with result: HostKeyValidationResult) {
        hostKeyValidationContinuation?.resume(returning: result)
        hostKeyValidationContinuation = nil
        showNewHostAlert = false
        showKeyChangedAlert = false
        validationData = nil
        completePresented(clearBackingState: true)
    }

    // NOTE: no deinit — `hostKeyValidationContinuation` is non-Sendable and
    // must not be touched from a nonisolated deinit. A continuation dropped
    // un-resumed when a window dies mid-prompt matches the previous @State
    // behavior.
}
