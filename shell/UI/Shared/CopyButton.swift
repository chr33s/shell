//
//  CopyButton.swift
//  shell
//
//  Reusable clipboard button with transient visual feedback.
//

import SwiftUI
import UIKit

struct CopyButton: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    let text: String
    let label: String?
    let isBordered: Bool

    @State private var copied = false

    init(text: String, label: String? = nil, isBordered: Bool = false) {
        self.text = text
        self.label = label
        self.isBordered = isBordered
    }

    var body: some View {
        Group {
            if isBordered {
                button
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(accentColor)
            } else {
                button
                    .buttonStyle(.borderless)
                    .foregroundColor(copied ? accentColor : .secondary)
            }
        }
        .accessibilityLabel(label ?? String(localized: "Copy", comment: "Copy button"))
        .accessibilityValue(copied ? String(localized: "Copied", comment: "Copy button state: copied") : "")
    }

    private var accentColor: Color {
        sheetThemeColors?.accentColor ?? .accentColor
    }

    private var copiedTitle: String {
        String(localized: "Copied", comment: "Copy button state: copied")
    }

    private var button: some View {
        Button(action: copyToClipboard) {
            if let label {
                // Both states stay in layout so the pill keeps the wider width.
                ZStack {
                    labelContent(copiedTitle, systemImage: "checkmark")
                        .opacity(copied ? 1 : 0)
                    labelContent(label, systemImage: "doc.on.doc")
                        .opacity(copied ? 0 : 1)
                }
                .fixedSize()
                .animation(.easeInOut(duration: 0.15), value: copied)
            } else {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .frame(width: 16, height: 16)
                    .font(.caption)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: copied)
            }
        }
    }

    private func labelContent(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .imageScale(.small)
            Text(title)
                .lineLimit(1)
        }
        .font(.caption.weight(.medium))
    }

    private func copyToClipboard() {
        UIPasteboard.general.string = text
        copied = true

        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

/// A labeled, read-only value (fingerprint, public key, shell command) with a
/// copy button in the header and a full-width, wrapping, selectable body.
/// Long-press the body for a copy context menu as well.
struct CopyableValueBlock<Accessory: View>: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    let title: String
    let value: String
    /// Text placed on the clipboard; defaults to `value`.
    var copyText: String?
    var isCopyDisabled = false
    var font: Font = .system(.caption, design: .monospaced)
    @ViewBuilder var accessory: () -> Accessory

    init(
        title: String,
        value: String,
        copyText: String? = nil,
        isCopyDisabled: Bool = false,
        font: Font = .system(.caption, design: .monospaced),
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }
    ) {
        self.title = title
        self.value = value
        self.copyText = copyText
        self.isCopyDisabled = isCopyDisabled
        self.font = font
        self.accessory = accessory
    }

    private var clipboardText: String { copyText ?? value }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                CopyButton(
                    text: clipboardText,
                    label: String(localized: "Copy", comment: "Copy button"),
                    isBordered: true
                )
                .disabled(isCopyDisabled)
            }

            Text(value)
                .font(font)
                .lineLimit(nil)
                .lineSpacing(3)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(sheetThemeColors?.rowBackground ?? Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contextMenu {
                    if !isCopyDisabled {
                        Button {
                            UIPasteboard.general.string = clipboardText
                        } label: {
                            Label(String(localized: "Copy", comment: "Copy button"), systemImage: "doc.on.doc")
                        }
                    }
                }

            accessory()
        }
        .padding(.vertical, 4)
    }
}
