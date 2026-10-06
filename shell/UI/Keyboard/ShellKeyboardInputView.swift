//
//  ShellKeyboardInputView.swift
//  shell
//
//  The Shell terminal keyboard: an app-owned primary input view presented
//  below the existing keyboard toolbar accessory. Hosts the three pages,
//  tracks multi-touch input, owns Backspace repeat, and cancels everything
//  on lifecycle changes. Holds no text buffer.
//

import UIKit

@MainActor
protocol ShellKeyboardInputViewDelegate: AnyObject {
    /// Snapshot the destination when a touch begins.
    func shellKeyboardBeginInteraction() -> TerminalKeyboardTargetIdentity?
    func shellKeyboard(perform action: TerminalKeyboardAction, on target: TerminalKeyboardTargetIdentity?) -> TerminalKeyboardDispatchResult
    func shellKeyboardCanContinue(_ target: TerminalKeyboardTargetIdentity?) -> Bool
    /// The System key: switch this terminal (and the preference) to Apple's keyboard.
    func shellKeyboardDidRequestSystemKeyboard()
}

final class ShellKeyboardInputView: UIInputView {
    static let repeatDelay: TimeInterval = 0.4
    static let repeatInterval: TimeInterval = 0.08

    weak var delegate: ShellKeyboardInputViewDelegate?

    private let state: SoftwareKeyboardState
    private var modifierObservation: SoftwareModifierObservation?

    /// Cached key views per page; only the current page is in the hierarchy.
    private var pageViews: [ShellKeyboardPage: [[ShellKeyboardKeyView]]] = [:]
    private var displayedPage: ShellKeyboardPage?

    /// Bumped by every page change and cancellation, so a touch that began
    /// on an old page can never land on a newly displayed key.
    private var interactionGeneration = 0

    private final class Track {
        var row: Int
        var index: Int
        var key: ShellKeyboardKey
        let generation: Int
        let target: TerminalKeyboardTargetIdentity?
        var repeatTimer: Timer?
        var sentOnTouchDown = false

        init(row: Int, index: Int, key: ShellKeyboardKey, generation: Int, target: TerminalKeyboardTargetIdentity?) {
            self.row = row
            self.index = index
            self.key = key
            self.generation = generation
            self.target = target
        }
    }

    private var tracks: [ObjectIdentifier: Track] = [:]

    /// Bottom inset used before the view joins the keyboard window.
    var fallbackBottomSafeArea: CGFloat = 0 {
        didSet {
            guard abs(oldValue - fallbackBottomSafeArea) > 0.5 else { return }
            invalidateIntrinsicContentSize()
        }
    }

    private var lastReportedHeight: CGFloat = 0

    var hasActiveTouches: Bool { !tracks.isEmpty }

    // MARK: - Initialization

    init(state: SoftwareKeyboardState) {
        self.state = state
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 0), inputViewStyle: .keyboard)
        translatesAutoresizingMaskIntoConstraints = false
        allowsSelfSizing = true
        isMultipleTouchEnabled = true
        accessibilityIdentifier = "shellKeyboard"

        modifierObservation = state.modifiers.observe { [weak self] _ in
            self?.refreshModifierAppearance()
        }
        state.onPageChanged = { [weak self] _ in
            self?.showCurrentPage()
        }
        // Scene deactivation is handled once, by the accessory controller,
        // which also clears the shared modifiers.
        showCurrentPage()
        registerForTraitChanges([UITraitVerticalSizeClass.self]) { (self: ShellKeyboardInputView, _: UITraitCollection) in
            self.cancelAllInteractions()
            self.invalidateIntrinsicContentSize()
            self.setNeedsLayout()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        for track in tracks.values { track.repeatTimer?.invalidate() }
    }

    // MARK: - Sizing

    private var bottomSafeArea: CGFloat {
        max(window?.safeAreaInsets.bottom ?? 0, fallbackBottomSafeArea)
    }

    override var intrinsicContentSize: CGSize {
        CGSize(
            width: UIView.noIntrinsicMetric,
            height: ShellKeyboardLayout.contentHeight(for: traitCollection) + bottomSafeArea
        )
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            cancelAllInteractions()
        }
        invalidateIntrinsicContentSize()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        // Only a real height change re-invalidates, so a geometry update can
        // never feed back into a resize loop.
        let height = intrinsicContentSize.height
        if abs(height - lastReportedHeight) > 0.5 {
            lastReportedHeight = height
            invalidateIntrinsicContentSize()
        }
        setNeedsLayout()
    }

    private var contentRect: CGRect {
        let left = max(safeAreaInsets.left, window?.safeAreaInsets.left ?? 0)
        let right = max(safeAreaInsets.right, window?.safeAreaInsets.right ?? 0)
        let padding = ShellKeyboardLayout.verticalPadding
        let rowsHeight = CGFloat(ShellKeyboardLayout.rowCount) * ShellKeyboardLayout.rowHeight(for: traitCollection)
        return CGRect(x: left, y: padding, width: max(0, bounds.width - left - right), height: rowsHeight)
    }

    private func rowRect(_ row: Int) -> CGRect {
        let content = contentRect
        let height = ShellKeyboardLayout.rowHeight(for: traitCollection)
        return CGRect(x: content.minX, y: content.minY + CGFloat(row) * height, width: content.width, height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let page = displayedPage, let views = pageViews[page] else { return }
        let rows = ShellKeyboardLayout.rows(for: page)
        for (rowIndex, row) in rows.enumerated() where rowIndex < views.count {
            let rect = rowRect(rowIndex)
            let cells = ShellKeyboardLayout.cellFrames(for: row, in: rect)
            for (index, view) in views[rowIndex].enumerated() where index < cells.count {
                view.frame = cells[index]
                let visual = ShellKeyboardLayout.visualFrame(for: row.keys[index], index: index, in: row, cells: cells, rowRect: rect)
                view.capFrame = visual.offsetBy(dx: -cells[index].minX, dy: -cells[index].minY)
            }
        }
    }

    // MARK: - Pages

    private func showCurrentPage() {
        let page = state.page
        guard page != displayedPage else { return }
        cancelAllInteractions()
        if let old = displayedPage {
            pageViews[old]?.joined().forEach { $0.removeFromSuperview() }
        }
        let views = pageViews[page] ?? makeViews(for: page)
        pageViews[page] = views
        views.joined().forEach { addSubview($0) }
        displayedPage = page
        refreshModifierAppearance()
        setNeedsLayout()
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }

    private func makeViews(for page: ShellKeyboardPage) -> [[ShellKeyboardKeyView]] {
        ShellKeyboardLayout.rows(for: page).map { row in
            row.keys.map { key in
                let view = ShellKeyboardKeyView(key: key)
                view.onAccessibilityActivate = { [weak self] in
                    self?.activateForAccessibility(key) ?? false
                }
                if key.kind == .local(.shift) {
                    view.onAccessibilitySetModifierState = { [weak self] newState in
                        self?.state.modifiers.set(newState, for: .shift)
                    }
                }
                return view
            }
        }
    }

    private func refreshModifierAppearance() {
        guard let page = displayedPage, let views = pageViews[page] else { return }
        let shiftState = state.modifiers.state(for: .shift)
        let shifted = shiftState != .inactive
        for view in views.joined() {
            view.update(shifted: shifted, shiftState: shiftState)
        }
    }

    // MARK: - Hit testing

    /// Key under a point. Vertical padding belongs to the nearest row; the
    /// home-indicator strip below the rows hits nothing.
    private func locate(_ point: CGPoint) -> (row: Int, index: Int)? {
        guard let page = displayedPage else { return nil }
        let content = contentRect
        let padding = ShellKeyboardLayout.verticalPadding
        guard point.y >= content.minY - padding, point.y <= content.maxY + padding,
              point.x >= content.minX, point.x <= content.maxX else { return nil }
        let height = ShellKeyboardLayout.rowHeight(for: traitCollection)
        let row = min(max(Int((point.y - content.minY) / height), 0), ShellKeyboardLayout.rowCount - 1)
        guard let index = keyIndex(atX: point.x, row: row, page: page) else { return nil }
        return (row, index)
    }

    private func keyIndex(atX x: CGFloat, row: Int, page: ShellKeyboardPage) -> Int? {
        let rows = ShellKeyboardLayout.rows(for: page)
        guard rows.indices.contains(row) else { return nil }
        let cells = ShellKeyboardLayout.cellFrames(for: rows[row], in: rowRect(row))
        return cells.firstIndex { x >= $0.minX && x < $0.maxX } ?? (x >= (cells.last?.maxX ?? 0) ? cells.indices.last : nil)
    }

    private func keyView(row: Int, index: Int) -> ShellKeyboardKeyView? {
        guard let page = displayedPage, let views = pageViews[page],
              views.indices.contains(row), views[row].indices.contains(index) else { return nil }
        return views[row][index]
    }

    // MARK: - Touches

    private var canDispatchTouchAction: Bool {
        guard let window else { return false }
        return window.windowScene?.activationState == .foregroundActive
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard canDispatchTouchAction else {
            cancelAllInteractions()
            return
        }
        for touch in touches {
            guard let (row, index) = locate(touch.location(in: self)),
                  let page = displayedPage else { continue }
            let key = ShellKeyboardLayout.rows(for: page)[row].keys[index]
            let track = Track(
                row: row, index: index, key: key,
                generation: interactionGeneration,
                target: delegate?.shellKeyboardBeginInteraction()
            )
            tracks[ObjectIdentifier(touch)] = track
            keyView(row: row, index: index)?.isPressed = true
            #if !os(visionOS)
            UIDevice.current.playInputClick()
            #endif

            if case .named(let named) = key.kind, named.repeats {
                track.sentOnTouchDown = true
                let result = delegate?.shellKeyboard(perform: .named(named), on: track.target) ?? .targetUnavailable
                if result == .delivered {
                    armRepeat(for: track, key: named)
                }
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let track = tracks[ObjectIdentifier(touch)] else { continue }
            let location = touch.location(in: self)
            guard bounds.contains(location), track.generation == interactionGeneration,
                  let page = displayedPage else {
                cancel(touch)
                continue
            }
            if track.key.kind.isPrintable {
                // Retarget within the same typing row.
                guard let index = keyIndex(atX: location.x, row: track.row, page: page),
                      index != track.index else { continue }
                let candidate = ShellKeyboardLayout.rows(for: page)[track.row].keys[index]
                guard candidate.kind.isPrintable else { continue }
                keyView(row: track.row, index: track.index)?.isPressed = false
                track.index = index
                track.key = candidate
                keyView(row: track.row, index: index)?.isPressed = true
            } else {
                let cell = keyView(row: track.row, index: track.index)?.frame ?? .zero
                if !cell.insetBy(dx: -8, dy: -8).contains(location) {
                    cancel(touch)
                }
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let track = tracks.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            track.repeatTimer?.invalidate()
            keyView(row: track.row, index: track.index)?.isPressed = false
            guard track.generation == interactionGeneration, !track.sentOnTouchDown,
                  canDispatchTouchAction else { continue }
            commit(track.key, target: track.target)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { cancel(touch) }
    }

    private func cancel(_ touch: UITouch) {
        guard let track = tracks.removeValue(forKey: ObjectIdentifier(touch)) else { return }
        track.repeatTimer?.invalidate()
        keyView(row: track.row, index: track.index)?.isPressed = false
    }

    /// Stop every touch and timer. Used for page/mode changes, responder and
    /// window changes, scene deactivation, and target retirement.
    func cancelAllInteractions() {
        interactionGeneration &+= 1
        for track in tracks.values {
            track.repeatTimer?.invalidate()
            keyView(row: track.row, index: track.index)?.isPressed = false
        }
        tracks.removeAll()
    }

    // MARK: - Repeat

    private func armRepeat(for track: Track, key: ShellKeyboardNamedKey) {
        track.repeatTimer?.invalidate()
        let generation = track.generation
        track.repeatTimer = Timer.scheduledTimer(withTimeInterval: Self.repeatDelay, repeats: false) { [weak self, weak track] _ in
            MainActor.assumeIsolated {
                guard let self, let track else { return }
                track.repeatTimer = Timer.scheduledTimer(withTimeInterval: Self.repeatInterval, repeats: true) { [weak self, weak track] _ in
                    MainActor.assumeIsolated {
                        guard let self, let track else { return }
                        self.fireRepeat(track: track, key: key, generation: generation)
                    }
                }
                self.fireRepeat(track: track, key: key, generation: generation)
            }
        }
    }

    private func fireRepeat(track: Track, key: ShellKeyboardNamedKey, generation: Int) {
        guard generation == interactionGeneration, canDispatchTouchAction,
              delegate?.shellKeyboardCanContinue(track.target) == true else {
            track.repeatTimer?.invalidate()
            track.repeatTimer = nil
            return
        }
        let result = delegate?.shellKeyboard(perform: .named(key), on: track.target) ?? .targetUnavailable
        if result != .delivered {
            track.repeatTimer?.invalidate()
            track.repeatTimer = nil
        }
    }

    // MARK: - Commit

    private func commit(_ key: ShellKeyboardKey, target: TerminalKeyboardTargetIdentity?) {
        switch key.kind {
        case .character, .literal:
            let shifted = state.modifiers.state(for: .shift) != .inactive
            guard let character = key.character(shifted: shifted) else { return }
            _ = delegate?.shellKeyboard(perform: .character(character), on: target)
        case .named(let named):
            _ = delegate?.shellKeyboard(perform: .named(named), on: target)
        case .paste:
            _ = delegate?.shellKeyboard(perform: .paste, on: target)
        case .local(let action):
            perform(action)
        }
    }

    private func perform(_ action: ShellKeyboardLocalAction) {
        switch action {
        case .shift:
            state.modifiers.tap(.shift)
        case .clearModifiers:
            state.modifiers.clearAll()
            UIAccessibility.post(notification: .announcement, argument: String(localized: "Modifiers cleared"))
        case .page(let page):
            // Switching pages sends nothing and leaves one-shots pending.
            state.page = page
        case .system:
            cancelAllInteractions()
            delegate?.shellKeyboardDidRequestSystemKeyboard()
        }
    }

    private func activateForAccessibility(_ key: ShellKeyboardKey) -> Bool {
        guard canDispatchTouchAction else { return false }
        commit(key, target: delegate?.shellKeyboardBeginInteraction())
        return true
    }
}

#if !os(visionOS)
extension ShellKeyboardInputView: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}
#endif
