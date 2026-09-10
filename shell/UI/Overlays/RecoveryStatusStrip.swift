//
//  RecoveryStatusStrip.swift
//  shell
//
//  Native recovery status strip (spec.connectivity.md §12).
//
//  Recovery status lives here, not in the terminal stream. Writing a spinner,
//  a countdown, a "✓ Reconnected!" line, or an error into Ghostty corrupts
//  whatever the remote program is drawing — catastrophically so for a
//  full-screen alternate-screen application, whose bytes must come back
//  byte-identical after a recovery (AC-18).
//
//  The strip sits above the surface, is announced once per major state
//  change rather than per countdown tick, and never takes focus.
//

import SwiftUI

struct RecoveryStatusStrip: View {
    let presentation: RecoveryStatusPresentation
    let onAction: (RecoveryStatusAction) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Last title announced to VoiceOver. Major state changes announce once;
    /// a countdown that repaints every second must not (§12), which is what
    /// `presentation.announces` is for.
    @State private var lastAnnouncedTitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                icon
                    .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let detail = presentation.detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                if presentation.isStale {
                    Text("Stale", comment: "Recovery strip badge: retained screen is not current")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }

            if !presentation.actions.isEmpty {
                actionRow
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlayCardBackground()
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(accentColor)
                .frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(presentation.title))
        .accessibilityValue(Text(presentation.detail ?? ""))
        .onAppear { announceIfNeeded(presentation) }
        .onChange(of: presentation) { _, new in announceIfNeeded(new) }
    }

    private func announceIfNeeded(_ presentation: RecoveryStatusPresentation) {
        guard presentation.announces else { return }
        guard presentation.title != lastAnnouncedTitle else { return }
        lastAnnouncedTitle = presentation.title
        var announcement = AttributedString(presentation.title)
        announcement.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(announcement).post()
    }

    @ViewBuilder
    private var actionRow: some View {
        // Stack vertically at large text sizes so the labels are never
        // truncated to unreadable stubs.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 8))

        layout {
            ForEach(presentation.actions, id: \.self) { action in
                Button(action.title) { onAction(action) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if presentation.showsActivity {
            ProgressView()
                .controlSize(.mini)
        } else {
            Image(systemName: symbolName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(accentColor)
        }
    }

    private var symbolName: String {
        switch presentation.severity {
        case .informational: return "antenna.radiowaves.left.and.right"
        case .warning: return "wifi.exclamationmark"
        case .attention: return "exclamationmark.triangle.fill"
        }
    }

    private var accentColor: Color {
        switch presentation.severity {
        case .informational: return .appAccent
        case .warning: return .appHighlight
        case .attention: return .appDanger
        }
    }
}

/// Attaches the strip above a terminal surface and announces major changes
/// exactly once.
struct RecoveryStatusStripModifier: ViewModifier {
    let presentation: RecoveryStatusPresentation?
    let onAction: (RecoveryStatusAction) -> Void

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let presentation {
                    RecoveryStatusStrip(presentation: presentation, onAction: onAction)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.18), value: presentation)
    }
}

extension View {
    /// Present recovery status natively, outside the terminal byte stream.
    func recoveryStatusStrip(
        _ presentation: RecoveryStatusPresentation?,
        onAction: @escaping (RecoveryStatusAction) -> Void
    ) -> some View {
        modifier(RecoveryStatusStripModifier(presentation: presentation, onAction: onAction))
    }
}

#Preview("Waiting for network") {
    RecoveryStatusStrip(
        presentation: RecoveryStatusPresentation.make(
            for: .waitingForConnectivity,
            intent: .attachExistingTmux,
            isStale: true,
            lastVerifiedActivityAge: 92)!,
        onAction: { _ in })
    .padding()
}

#Preview("Reattaching") {
    RecoveryStatusStrip(
        presentation: RecoveryStatusPresentation.make(
            for: .recovering(stage: .attaching),
            intent: .attachExistingTmux,
            sessionName: "main")!,
        onAction: { _ in })
    .padding()
}

#Preview("Command outcome unknown") {
    RecoveryStatusStrip(
        presentation: RecoveryStatusPresentation.make(
            for: .awaitingUser(reason: .commandOutcomeUnknown),
            intent: .oneShotCommand)!,
        onAction: { _ in })
    .padding()
}
