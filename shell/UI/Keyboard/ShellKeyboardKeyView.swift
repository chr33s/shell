//
//  ShellKeyboardKeyView.swift
//  shell
//
//  One Shell keyboard keycap: rendering and accessibility. Touches are
//  tracked by `ShellKeyboardInputView`, which owns multi-touch ordering.
//

import UIKit

final class ShellKeyboardKeyView: UIView {
    let key: ShellKeyboardKey

    /// Accessibility activation (VoiceOver, Switch Control).
    var onAccessibilityActivate: (() -> Bool)?
    /// Shift only: explicit Lock/Unlock so double-tap timing is not required.
    var onAccessibilitySetModifierState: ((ModifierState) -> Void)?

    private let capView = UIView()
    private let titleLabel = UILabel()
    private let secondaryLabel = UILabel()
    private let iconView = UIImageView()
    private let lockBar = UIView()

    private var shifted = false
    private var modifierState: ModifierState = .inactive

    var isPressed = false {
        didSet {
            guard oldValue != isPressed else { return }
            updateColors()
        }
    }

    init(key: ShellKeyboardKey) {
        self.key = key
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityIdentifier = "shellKeyboard.\(key.id)"
        setupViews()
        applyContent()
        registerForTraitChanges([
            UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self,
            UITraitLegibilityWeight.self, UITraitVerticalSizeClass.self
        ]) { (self: ShellKeyboardKeyView, _: UITraitCollection) in
            self.applyFonts()
            self.updateColors()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        capView.isUserInteractionEnabled = false
        capView.layer.cornerRadius = 6
        capView.layer.cornerCurve = .continuous
        capView.layer.shadowColor = UIColor.black.cgColor
        capView.layer.shadowOpacity = 0.18
        capView.layer.shadowRadius = 0
        capView.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(capView)

        titleLabel.textAlignment = .center
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.6
        titleLabel.textColor = .label
        capView.addSubview(titleLabel)

        secondaryLabel.textAlignment = .right
        secondaryLabel.textColor = .secondaryLabel
        capView.addSubview(secondaryLabel)

        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = .label
        capView.addSubview(iconView)

        lockBar.backgroundColor = .label
        lockBar.layer.cornerRadius = 1
        lockBar.isHidden = true
        capView.addSubview(lockBar)

        applyFonts()
        updateColors()
    }

    /// Visual cap frame inside this view's hit cell.
    var capFrame: CGRect = .zero {
        didSet { setNeedsLayout() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        capView.frame = capFrame
        let bounds = capView.bounds
        titleLabel.frame = bounds.insetBy(dx: 2, dy: 0)
        iconView.frame = bounds.insetBy(dx: bounds.width * 0.22, dy: bounds.height * 0.24)
        secondaryLabel.frame = CGRect(x: 2, y: 1, width: bounds.width - 5, height: bounds.height * 0.38)
        lockBar.frame = CGRect(x: bounds.width * 0.25, y: bounds.height - 4, width: bounds.width * 0.5, height: 2)
        capView.layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 6).cgPath
    }

    // MARK: - State

    /// Shift (one-shot or locked) from the shared modifier model.
    func update(shifted: Bool, shiftState: ModifierState) {
        let contentChanged = self.shifted != shifted
        self.shifted = shifted
        if key.kind == .local(.shift), modifierState != shiftState {
            modifierState = shiftState
            applyContent()
            updateColors()
        } else if contentChanged {
            applyContent()
        }
    }

    private func applyContent() {
        titleLabel.isHidden = false
        iconView.isHidden = true
        secondaryLabel.text = nil
        lockBar.isHidden = true

        switch key.kind {
        case .character(let base):
            if base == " " {
                titleLabel.text = String(localized: "space", comment: "Shell keyboard space bar")
            } else {
                titleLabel.text = String(shifted ? ShellKeyboardLayout.shifted(base) : base)
                // The shifted alternative as a secondary label for non-letters.
                if !base.isLetter, !shifted {
                    let alternative = ShellKeyboardLayout.shifted(base)
                    secondaryLabel.text = alternative == base ? nil : String(alternative)
                }
            }
        case .literal(let symbol):
            titleLabel.text = String(symbol)
        case .named(let named):
            switch named {
            case .backspace: showIcon("delete.left")
            case .forwardDelete: showIcon("delete.right")
            case .enter: showIcon("return")
            case .tab: titleLabel.text = String(localized: "tab", comment: "Shell keyboard Tab key")
            case .backtab: titleLabel.text = String(localized: "⇧tab", comment: "Shell keyboard Shift+Tab key")
            case .escape: titleLabel.text = String(localized: "esc", comment: "Shell keyboard Escape key")
            case .home: titleLabel.text = String(localized: "home", comment: "Shell keyboard Home key")
            case .end: titleLabel.text = String(localized: "end", comment: "Shell keyboard End key")
            case .pageUp: titleLabel.text = String(localized: "pg up", comment: "Shell keyboard Page Up key")
            case .pageDown: titleLabel.text = String(localized: "pg dn", comment: "Shell keyboard Page Down key")
            }
        case .paste:
            titleLabel.text = String(localized: "paste", comment: "Shell keyboard Paste key")
        case .local(let action):
            switch action {
            case .shift:
                switch modifierState {
                case .inactive: showIcon("shift")
                case .oneShot: showIcon("shift.fill")
                case .locked:
                    showIcon("capslock.fill")
                    lockBar.isHidden = false
                }
            case .page(.letters): titleLabel.text = "ABC"
            case .page(.symbols): titleLabel.text = "#+="
            case .page(.navigation): titleLabel.text = String(localized: "nav", comment: "Shell keyboard navigation page key")
            case .system: titleLabel.text = String(localized: "System", comment: "Shell keyboard key that switches to Apple's keyboard")
            case .clearModifiers: titleLabel.text = String(localized: "clear mods", comment: "Shell keyboard key that clears modifiers")
            }
        }
        updateAccessibility()
    }

    private func showIcon(_ name: String) {
        titleLabel.isHidden = true
        iconView.isHidden = false
        iconView.image = UIImage(systemName: name)
    }

    private var usesSmallTitle: Bool {
        switch key.kind {
        case .character(let base): base == " "
        case .literal: false
        default: true
        }
    }

    private func applyFonts() {
        let bold = traitCollection.legibilityWeight == .bold
        let compact = traitCollection.verticalSizeClass == .compact
        let size: CGFloat = usesSmallTitle ? (compact ? 14 : 15) : (compact ? 19 : 22)
        titleLabel.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        secondaryLabel.font = .systemFont(ofSize: compact ? 9 : 10, weight: bold ? .semibold : .regular)
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: compact ? 16 : 18, weight: bold ? .semibold : .regular
        )
    }

    private var isFunctionKey: Bool { !key.kind.isPrintable }

    private func updateColors() {
        let highContrast = traitCollection.accessibilityContrast == .high
        let dark = traitCollection.userInterfaceStyle == .dark
        let base: UIColor
        if isFunctionKey {
            base = dark ? UIColor(white: 0.28, alpha: 1) : UIColor(white: 0.68, alpha: 1)
        } else {
            base = dark ? UIColor(white: 0.42, alpha: 1) : .white
        }
        var fill = base
        if key.kind == .local(.shift), modifierState != .inactive {
            fill = dark ? UIColor(white: 0.85, alpha: 1) : .white
            titleLabel.textColor = .black
            iconView.tintColor = .black
            lockBar.backgroundColor = .black
        } else {
            titleLabel.textColor = .label
            iconView.tintColor = .label
            lockBar.backgroundColor = .label
        }
        if isPressed {
            fill = dark ? UIColor(white: 0.55, alpha: 1) : UIColor(white: 0.82, alpha: 1)
        }
        capView.backgroundColor = fill
        capView.layer.borderWidth = highContrast ? 1 : 0
        capView.layer.borderColor = UIColor.label.withAlphaComponent(0.5).cgColor
    }

    // MARK: - Accessibility

    private func updateAccessibility() {
        accessibilityLabel = Self.accessibilityLabel(for: key, shifted: shifted)
        var traits: UIAccessibilityTraits = key.kind.isPrintable ? .keyboardKey : .button
        if key.kind == .local(.shift), modifierState != .inactive { traits.insert(.selected) }
        accessibilityTraits = traits
        if key.kind == .local(.shift) {
            accessibilityValue = switch modifierState {
            case .inactive: nil
            case .oneShot: String(localized: "One-shot")
            case .locked: String(localized: "Locked")
            }
            let lock = UIAccessibilityCustomAction(name: String(localized: "Lock")) { [weak self] _ in
                self?.onAccessibilitySetModifierState?(.locked)
                return true
            }
            let unlock = UIAccessibilityCustomAction(name: String(localized: "Unlock")) { [weak self] _ in
                self?.onAccessibilitySetModifierState?(.inactive)
                return true
            }
            accessibilityCustomActions = modifierState == .locked ? [unlock] : [lock]
        }
    }

    override func accessibilityActivate() -> Bool {
        onAccessibilityActivate?() ?? false
    }

    static func accessibilityLabel(for key: ShellKeyboardKey, shifted: Bool) -> String {
        switch key.kind {
        case .character(" "):
            return String(localized: "Space")
        case .character(let base):
            let text = shifted ? ShellKeyboardLayout.shifted(base) : base
            return symbolName(text)
        case .literal(let symbol):
            return symbolName(symbol)
        case .named(let named):
            switch named {
            case .escape: return String(localized: "Escape")
            case .tab: return String(localized: "Tab")
            case .backtab: return String(localized: "Shift Tab")
            case .enter: return String(localized: "Return")
            case .backspace: return String(localized: "Backspace")
            case .forwardDelete: return String(localized: "Forward Delete")
            case .home: return String(localized: "Home")
            case .end: return String(localized: "End")
            case .pageUp: return String(localized: "Page Up")
            case .pageDown: return String(localized: "Page Down")
            }
        case .paste:
            return String(localized: "Paste")
        case .local(let action):
            switch action {
            case .shift: return String(localized: "Shift")
            case .page(.letters): return String(localized: "Letters")
            case .page(.symbols): return String(localized: "Symbols")
            case .page(.navigation): return String(localized: "Navigation Keys")
            case .system: return String(localized: "Use System Keyboard")
            case .clearModifiers: return String(localized: "Clear Modifiers")
            }
        }
    }

    private static func symbolName(_ character: Character) -> String {
        switch character {
        case "`": String(localized: "Backtick")
        case "~": String(localized: "Tilde")
        case "|": String(localized: "Pipe")
        case "\\": String(localized: "Backslash")
        case "/": String(localized: "Slash")
        case "^": String(localized: "Caret")
        case "_": String(localized: "Underscore")
        case "\"": String(localized: "Double Quote")
        case "'": String(localized: "Single Quote")
        default: String(character)
        }
    }
}
