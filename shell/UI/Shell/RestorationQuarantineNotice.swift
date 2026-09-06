//
//  RestorationQuarantineNotice.swift
//  shell
//
//  Tells the user their saved session was set aside after repeated failed
//  restores. Without this the crash-loop protection in
//  RestorationHealthTracker is silent: the app opens to an empty window and
//  every tab from last session is simply gone with no explanation.
//
//  Same shape as TmuxShortcutFailureAlert: a zero-size host for one alert,
//  because the failure happens in a manager with no view attached. Kept out
//  of MainView.body on purpose — reading the tracker from there would register
//  that dependency on the whole window.
//

import SwiftUI

@MainActor
struct RestorationQuarantineNotice: View {
    @State private var message: String?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .alert("Tabs Could Not Be Restored", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("OK", role: .cancel) { message = nil }
            } message: {
                // Text(String) picks the non-localizing overload; the message
                // arrives already localized from the tracker.
                Text(message ?? "")
            }
            // Two claim points, because the ordering is not guaranteed:
            // evaluateRestoration() runs inside MainView.handleOnAppear, which
            // may fire before or after this child appears. `.task` covers "flag
            // was already set"; `.onChange` covers "set just after we appeared".
            // claim() clears the flag, so the re-entrant onChange it causes
            // returns nil and does nothing.
            .task { claim() }
            .onChange(of: RestorationHealthTracker.shared.restorationSkipped) { _, _ in claim() }
    }

    private func claim() {
        if let text = RestorationHealthTracker.shared.claimRestorationSkippedNotice() {
            message = text
        }
    }
}
