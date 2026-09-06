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
    }

    /// The alert currently on screen (nil = none). Writes go through
    /// enqueue/completePresented so queue mechanics stay consistent.
    private(set) var presentedKind: Kind?
    private var pendingKinds: [Kind] = []

    // MARK: - Backing state (one flag per kind)

    // Host key validation state
    //
    // One pending request per concurrent validation, NOT one slot. A window
    // funnels every terminal's `onHostKeyValidationRequired` into this one
    // controller, so restoring two tabs on unknown hosts (or opening a second
    // SSH split while a prompt is up) raises two validations at once. A single
    // slot overwrote the first continuation — leaving that SSH session
    // suspended forever — and showed the second host's fingerprint under the
    // first host's prompt. Each request carries its own continuation and its
    // own data, and they are answered strictly one at a time.
    @ObservationIgnored private var pendingHostKeyRequests: [PendingHostKeyRequest] = []
    var showNewHostAlert = false
    var showKeyChangedAlert = false
    var validationData: MainView.ValidationData?

    struct PendingHostKeyRequest {
        let data: MainView.ValidationData
        let isKeyChanged: Bool
        let continuation: CheckedContinuation<HostKeyValidationResult, Never>
    }

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
        }
    }

    // MARK: - SSH Host Key Validation

    func handleHostKeyValidation(
        request: HostKeyValidationRequest,
        terminalView: Ghostty.TerminalView
    ) async -> HostKeyValidationResult {
        await withCheckedContinuation { continuation in
            let sessionLabel = terminalView.connectionConfig.displayName
            let alertContext = "(\(sessionLabel))"

            let data = MainView.ValidationData(
                alertTitle: request.isKeyChanged
                    ? "⚠️ WARNING: Host Key Changed \(alertContext)"
                    : "New SSH Host \(alertContext)",
                message: request.message,
                isKeyChanged: request.isKeyChanged
            )

            pendingHostKeyRequests.append(
                PendingHostKeyRequest(
                    data: data, isKeyChanged: request.isKeyChanged, continuation: continuation))

            // Only drive the UI for the head of the queue; the rest are shown
            // as each one is answered.
            if pendingHostKeyRequests.count == 1 {
                presentHeadHostKeyRequest()
            }
        }
    }

    /// Puts the queue head on screen. Every prompt shows the fingerprint of the
    /// host whose continuation it will resume.
    private func presentHeadHostKeyRequest() {
        guard let head = pendingHostKeyRequests.first else { return }
        validationData = head.data
        if head.isKeyChanged {
            showKeyChangedAlert = true
            enqueue(.keyChanged)
        } else {
            showNewHostAlert = true
            enqueue(.newHost)
        }
    }

    func respondToHostKeyValidation(with result: HostKeyValidationResult) {
        guard !pendingHostKeyRequests.isEmpty else { return }
        // Resume the HEAD only — the answer belongs to the host on screen.
        let answered = pendingHostKeyRequests.removeFirst()
        answered.continuation.resume(returning: result)

        showNewHostAlert = false
        showKeyChangedAlert = false
        validationData = nil
        completePresented(clearBackingState: true)

        // Next host, if any, gets its own prompt rather than being dropped.
        if !pendingHostKeyRequests.isEmpty {
            DispatchQueue.main.async { [self] in
                presentHeadHostKeyRequest()
            }
        }
    }

    // NOTE: no deinit — the continuations in `pendingHostKeyRequests` are
    // non-Sendable and must not be touched from a nonisolated deinit. Any
    // still-queued when a window dies mid-prompt are dropped un-resumed, which
    // matches the previous @State behavior.
}
