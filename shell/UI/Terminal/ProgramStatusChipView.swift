//
//  ProgramStatusChipView.swift
//  shell
//
//  The compact OSC 7501 indicator in a pane's top-trailing corner: a state
//  symbol plus, for a working record, its percentage. Tapping it opens the
//  details (every record, as plain text) and counts as having seen the
//  results. It never acts for the program: `permission` is informational.
//

import SwifttyKit
import UIKit

@MainActor
final class ProgramStatusChipView: UIButton {
    /// Records for the details menu, read when it opens.
    var detailsProvider: (() -> ProgramStatusSnapshot)?
    /// The details were opened.
    var onOpenDetails: (() -> Void)?

    private var presentation: ProgramStatusPresentation?

    override init(frame: CGRect) {
        super.init(frame: frame)
        var config = UIButton.Configuration.plain()
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6)
        config.imagePadding = 3
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
            return attributes
        }
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.85)
        background.strokeColor = UIColor.separator
        background.strokeWidth = 0.5
        config.background = background
        configuration = config
        showsMenuAsPrimaryAction = true
        menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                MainActor.assumeIsolated {
                    completion(self?.detailsMenuElements() ?? [])
                }
            }
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = String(localized: "Shows program status details")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(with presentation: ProgramStatusPresentation) {
        guard presentation != self.presentation else { return }
        self.presentation = presentation
        var config = configuration ?? .plain()
        config.image = UIImage(systemName: presentation.symbolName)
        config.title = presentation.severity == .working ? presentation.progress.map { "\($0)%" } : nil
        config.baseForegroundColor = Self.tint(for: presentation.severity)
        configuration = config
        accessibilityLabel = presentation.accessibilityLabel
    }

    private static func tint(for severity: ProgramStatusPresentation.Severity) -> UIColor {
        switch severity {
        case .idle: .secondaryLabel
        case .working: .systemBlue
        case .done: .systemGreen
        case .error: .systemRed
        case .blocked: .systemOrange
        }
    }

    /// One disabled row per record, newest first: plain text only.
    private func detailsMenuElements() -> [UIMenuElement] {
        onOpenDetails?()
        let snapshot = detailsProvider?() ?? .empty
        let rows: [UIMenuElement] = snapshot.records.reversed().compactMap { record in
            guard let row = ProgramStatusPresentation.reduce(
                ProgramStatusSnapshot(records: [record], revision: snapshot.revision),
                acknowledgedRevision: 0
            ) else { return nil }
            let app = snapshot.app(for: record.id).map(ProgramStatusText.sanitized)
            let action = UIAction(
                title: row.label,
                subtitle: [app, row.title != nil ? row.message : nil].compactMap { $0 }.joined(separator: " — ").nilIfEmpty,
                image: UIImage(systemName: row.symbolName),
                attributes: .disabled
            ) { _ in }
            action.accessibilityLabel = row.accessibilityLabel
            return action
        }
        guard !rows.isEmpty else {
            return [UIAction(title: String(localized: "No program status"), attributes: .disabled) { _ in }]
        }
        return [UIMenu(title: String(localized: "Program Status"), options: .displayInline, children: rows)]
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
