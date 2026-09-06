//
//  IntegratedTabEdge.swift
//  shell
//
//  The Integrated style's border: a hairline running the window's full width
//  along the strip/terminal boundary and up around the active tab.
//
//  The ordinary keyline uses two pieces so no tab frame has to reach the strip.
//  They join because both are the same hairline and the shoulder curves are
//  tangent to horizontal exactly where the rule lives. OSC progress adds a
//  transient compound foreground path over those same segments.
//

import SwiftUI
import UIKit

// MARK: - Metrics

enum IntegratedTabEdgeMetrics {
    /// One physical pixel. Anything heavier reads as a drawn box, not an edge.
    static func lineWidth(for displayScale: CGFloat) -> CGFloat {
        1 / max(1, displayScale)
    }

    /// OSC progress needs extra visual weight on an iPhone's smaller display,
    /// while the ordinary integrated edge remains a one-pixel hairline.
    static func progressLineWidth(for displayScale: CGFloat, isPhone: Bool) -> CGFloat {
        (isPhone ? 2 : 1) / max(1, displayScale)
    }

    /// For layouts reserving room before a display scale is available (1x case).
    static let reservedThickness: CGFloat = 1
}

/// Theme-derived optical colors for the integrated edge.
///
/// The old white/black alpha stroke inherited some color from its backdrop,
/// but blending toward an achromatic endpoint washed chromatic themes toward
/// gray. These colors are resolved from the terminal surface itself, so a
/// blue-purple surface such as Blackboard Dark keeps that hue in its rim.
struct IntegratedTabEdgePalette: Equatable {
    let surfaceColor: Color?
    let isLightTheme: Bool

    static let fallback = IntegratedTabEdgePalette(
        surfaceColor: nil,
        isLightTheme: false
    )

    func keyline(increasedContrast: Bool) -> Color {
        guard let surfaceColor else {
            return Color(uiColor: .separator)
        }
        if isLightTheme {
            return surfaceColor.darkenedPreservingHue(increasedContrast ? 0.36 : 0.26)
        }
        return surfaceColor.lightenedPreservingHue(increasedContrast ? 0.42 : 0.32)
    }
}

// MARK: - Shared silhouette geometry

/// Silhouette metrics, shared by the opaque fill (`BrowserTabShape`) and the
/// hairline outline so the two can never drift.
struct IntegratedTabGeometry {
    /// Tab body below the narrow strip of frame left visible above the tab.
    let tabRect: CGRect
    /// Wider than tall: a 1:1 corner reads as a sharp hook at Retina scale.
    let shoulderWidth: CGFloat
    let shoulderHeight: CGFloat
    let cornerRadius: CGFloat

    static let bezierKappa: CGFloat = 0.552_284_8

    init(in rect: CGRect) {
        let topInset = min(5, rect.height * 0.12)
        tabRect = CGRect(
            x: rect.minX,
            y: rect.minY + topInset,
            width: rect.width,
            height: max(0, rect.height - topInset)
        )
        shoulderWidth = min(16, tabRect.width * 0.12)
        shoulderHeight = min(10, tabRect.height * 0.28)
        cornerRadius = min(10, tabRect.height * 0.28)
    }

    /// Left shoulder → top → right shoulder, open at the bottom. `bottomInset`
    /// lifts the ends so a stroked copy lands on the rule's band, inside the row.
    func outlinePath(bottomInset: CGFloat = 0) -> Path {
        let bottom = tabRect.maxY - bottomInset
        var path = Path()
        path.move(to: CGPoint(x: tabRect.minX, y: bottom))
        appendOutline(to: &path, bottomInset: bottomInset)
        return path
    }

    /// Appends the outline after its starting point. Keeping the segment writer
    /// separate lets the OSC progress renderer splice the same tab curve into a
    /// single window-wide path without duplicating or approximating geometry.
    private func appendOutline(to path: inout Path, bottomInset: CGFloat) {
        let bottom = tabRect.maxY - bottomInset
        let kappa = Self.bezierKappa
        path.addCurve(
            to: CGPoint(
                x: tabRect.minX + shoulderWidth,
                y: bottom - shoulderHeight
            ),
            control1: CGPoint(
                x: tabRect.minX + shoulderWidth * kappa,
                y: bottom
            ),
            control2: CGPoint(
                x: tabRect.minX + shoulderWidth,
                y: bottom - shoulderHeight * (1 - kappa)
            )
        )
        path.addLine(to: CGPoint(
            x: tabRect.minX + shoulderWidth,
            y: tabRect.minY + cornerRadius
        ))
        path.addQuadCurve(
            to: CGPoint(x: tabRect.minX + shoulderWidth + cornerRadius, y: tabRect.minY),
            control: CGPoint(x: tabRect.minX + shoulderWidth, y: tabRect.minY)
        )
        path.addLine(to: CGPoint(
            x: tabRect.maxX - shoulderWidth - cornerRadius,
            y: tabRect.minY
        ))
        path.addQuadCurve(
            to: CGPoint(x: tabRect.maxX - shoulderWidth, y: tabRect.minY + cornerRadius),
            control: CGPoint(x: tabRect.maxX - shoulderWidth, y: tabRect.minY)
        )
        path.addLine(to: CGPoint(
            x: tabRect.maxX - shoulderWidth,
            y: bottom - shoulderHeight
        ))
        path.addCurve(
            to: CGPoint(x: tabRect.maxX, y: bottom),
            control1: CGPoint(
                x: tabRect.maxX - shoulderWidth,
                y: bottom - shoulderHeight * (1 - kappa)
            ),
            control2: CGPoint(
                x: tabRect.maxX - shoulderWidth * kappa,
                y: bottom
            )
        )
    }

    /// Continuous strip edge used by OSC progress: horizontal rule, active-tab
    /// outline, then horizontal rule. The ordinary edge remains split into its
    /// existing rule/outline views; this path is only the colored foreground.
    static func progressEdgePath(
        in rowRect: CGRect,
        activeTabRect: CGRect,
        bottomInset: CGFloat
    ) -> Path {
        let geometry = IntegratedTabGeometry(in: activeTabRect)
        let baseline = rowRect.maxY - bottomInset
        let tabBottom = geometry.tabRect.maxY - bottomInset
        var path = Path()
        path.move(to: CGPoint(x: rowRect.minX, y: baseline))
        path.addLine(to: CGPoint(x: geometry.tabRect.minX, y: tabBottom))
        geometry.appendOutline(to: &path, bottomInset: bottomInset)
        path.addLine(to: CGPoint(x: rowRect.maxX, y: baseline))
        return path
    }

    /// Closed silhouette for the opaque fill. Bottom stays flush so matching the
    /// terminal background reads as one connected surface.
    var silhouettePath: Path {
        var path = outlinePath()
        path.closeSubpath()
        return path
    }
}

// MARK: - Active-tab geometry

/// The selected integrated tab contributes its bounds to the row so the OSC
/// foreground can trace one continuous path without publishing frames into
/// `MainView` state on every scrolling-tab layout pass.
struct IntegratedActiveTabBoundsPreferenceKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

// MARK: - Shapes

/// Open path, to be stroked. Not pre-stroked via `strokedPath`: a ribbon's two
/// antialiased edges interfere at hairline width and speckle the shoulders.
struct IntegratedTabOutlineShape: Shape {
    var bottomInset: CGFloat

    func path(in rect: CGRect) -> Path {
        IntegratedTabGeometry(in: rect).outlinePath(bottomInset: bottomInset)
    }
}

/// The horizontal run along the strip/terminal boundary. Centered on the same
/// band as `IntegratedTabOutlineShape`'s open ends so the two abut without a step.
struct IntegratedTabEdgeRule: Shape {
    var lineWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(CGRect(
            x: rect.minX,
            y: rect.maxY - lineWidth,
            width: rect.width,
            height: lineWidth
        ))
    }
}

// MARK: - Views

/// The separator across the strip. Keeping this to exactly one physical pixel
/// prevents the shallow active-tab shoulders from appearing to dip below it.
struct IntegratedTabEdgeRuleView: View {
    let palette: IntegratedTabEdgePalette

    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        let lineWidth = IntegratedTabEdgeMetrics.lineWidth(for: displayScale)
        let increasedContrast = colorSchemeContrast == .increased
        IntegratedTabEdgeRule(lineWidth: lineWidth)
            .fill(palette.keyline(increasedContrast: increasedContrast))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Paints the rule's band out across the tab, in the tab's own color. At the
/// shoulder tips the silhouette has not yet climbed clear of that band, so rule
/// and outline would overlap there and composite to double density.
struct IntegratedTabEdgeOccluder: View {
    let color: Color

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: IntegratedTabEdgeMetrics.lineWidth(for: displayScale))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The tab's raised edge. A single physical-pixel chromatic stroke keeps its
/// shoulder endpoints flush with the rule without a simulated crest artifact.
struct IntegratedTabOutlineView: View {
    let palette: IntegratedTabEdgePalette

    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        let lineWidth = IntegratedTabEdgeMetrics.lineWidth(for: displayScale)
        let increasedContrast = colorSchemeContrast == .increased
        let keyline = palette.keyline(increasedContrast: increasedContrast)
        IntegratedTabOutlineShape(bottomInset: lineWidth / 2)
            .stroke(
                keyline,
                style: StrokeStyle(
                    lineWidth: lineWidth,
                    lineCap: .butt,
                    lineJoin: .round
                )
            )
            // The path already ends one half-line-width above the boundary;
            // clipping makes that containment explicit to the renderer.
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - OSC progress foreground

/// Isolates observation of the focused terminal's high-rate OSC progress state
/// from `MainView`. Core Animation owns the bouncing segment, so no display-link
/// updates enter SwiftUI's view graph.
struct IntegratedOSCProgressEdgeHost: View {
    @ObservedObject var terminalView: Ghostty.TerminalView
    let activeTabRect: CGRect
    let rowSize: CGSize
    let selectedTabID: UUID
    let animateSelectionChanges: Bool

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        if let report = terminalView.progressReport, report.state != .remove {
            let lineWidth = IntegratedTabEdgeMetrics.progressLineWidth(
                for: displayScale,
                isPhone: UIDevice.current.userInterfaceIdiom == .phone
            )
            let path = IntegratedTabGeometry.progressEdgePath(
                in: CGRect(origin: .zero, size: rowSize),
                activeTabRect: activeTabRect,
                bottomInset: lineWidth / 2
            )
            IntegratedOSCProgressLayerView(
                path: path.cgPath,
                lineWidth: lineWidth,
                report: report,
                selectedTabID: selectedTabID,
                animateSelectionChanges: animateSelectionChanges
            )
        }
    }
}

private struct IntegratedOSCProgressLayerView: UIViewRepresentable {
    let path: CGPath
    let lineWidth: CGFloat
    let report: Ghostty.Action.ProgressReport
    let selectedTabID: UUID
    let animateSelectionChanges: Bool

    func makeUIView(context: Context) -> IntegratedOSCProgressLayerUIView {
        IntegratedOSCProgressLayerUIView()
    }

    func updateUIView(_ view: IntegratedOSCProgressLayerUIView, context: Context) {
        view.configure(
            path: path,
            lineWidth: lineWidth,
            report: report,
            selectedTabID: selectedTabID,
            animateSelectionChanges: animateSelectionChanges
        )
    }

    static func dismantleUIView(_ view: IntegratedOSCProgressLayerUIView, coordinator: ()) {
        view.stopAnimation()
    }
}

/// A single stroked layer means `strokeStart` / `strokeEnd` naturally measure
/// progress across the rule and the longer curved detour around the active tab.
private final class IntegratedOSCProgressLayerUIView: UIView {
    private static let bounceAnimationKey = "osc-progress-bounce"

    private let progressLayer = CAShapeLayer()
    private var selectedTabID: UUID?
    private var lastPath: CGPath?
    /// Records only whether the current report *wants* the bounce. It never gates
    /// re-adding the animation - `startAnimationIfNeeded()` asks the layer for
    /// that - so it cannot desync from Core Animation the way the old
    /// `isBouncing` latch did.
    private var wantsBounce = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        clipsToBounds = true

        progressLayer.fillColor = nil
        progressLayer.lineCap = .butt
        progressLayer.lineJoin = .round
        layer.addSublayer(progressLayer)

        // UIKit strips CAAnimations off layers when the app is backgrounded and
        // does not restore them on the way back in, and an unchanged report can
        // skip the next `configure` pass entirely. Without this the bounce would
        // stay gone for the rest of the report, frozen as a static stub.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleWillEnterForeground() {
        guard wantsBounce else { return }
        startAnimationIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        progressLayer.frame = bounds
    }

    func configure(
        path: CGPath,
        lineWidth: CGFloat,
        report: Ghostty.Action.ProgressReport,
        selectedTabID newSelectedTabID: UUID,
        animateSelectionChanges: Bool
    ) {
        let selectionChanged = selectedTabID != nil && selectedTabID != newSelectedTabID
        selectedTabID = newSelectedTabID

        let oldPath = progressLayer.presentation()?.path
            ?? progressLayer.path
            ?? lastPath

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressLayer.lineWidth = lineWidth
        progressLayer.strokeColor = Self.color(for: report.state).cgColor
        progressLayer.path = path
        lastPath = path

        switch report.state {
        case .set:
            stopAnimation()
            progressLayer.strokeStart = 0
            progressLayer.strokeEnd = CGFloat(report.progress ?? 0) / 100
        case .indeterminate, .error, .pause:
            progressLayer.strokeStart = 0
            progressLayer.strokeEnd = 0.25
            startAnimationIfNeeded()
        case .remove:
            stopAnimation()
            progressLayer.strokeStart = 0
            progressLayer.strokeEnd = 0
        }
        CATransaction.commit()

        if selectionChanged, animateSelectionChanges, let oldPath {
            let animation = CABasicAnimation(keyPath: "path")
            animation.fromValue = oldPath
            animation.toValue = path
            animation.duration = 0.3
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            progressLayer.add(animation, forKey: "integrated-tab-selection-path")
        }
    }

    private static func color(for state: Ghostty.Action.ProgressReport.State) -> UIColor {
        switch state {
        case .error:
            return .appDanger
        case .pause:
            return .appHighlight
        default:
            return .appAccent
        }
    }

    private func startAnimationIfNeeded() {
        wantsBounce = true
        // Ask the layer whether the animation is still attached instead of
        // trusting a stored flag: Core Animation can drop it (backgrounding)
        // with no callback here, and a bool latch then blocks the restart
        // forever. Re-adding under the same key replaces any live copy.
        guard progressLayer.animation(forKey: Self.bounceAnimationKey) == nil else { return }

        let starts = CAKeyframeAnimation(keyPath: "strokeStart")
        starts.values = [0, 0.75, 0]
        starts.keyTimes = [0, 0.5, 1]
        starts.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut)
        ]

        let ends = CAKeyframeAnimation(keyPath: "strokeEnd")
        ends.values = [0.25, 1, 0.25]
        ends.keyTimes = [0, 0.5, 1]
        ends.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut)
        ]

        let group = CAAnimationGroup()
        group.animations = [starts, ends]
        group.duration = 2.4
        group.repeatCount = .infinity
        progressLayer.add(group, forKey: Self.bounceAnimationKey)
    }

    fileprivate func stopAnimation() {
        wantsBounce = false
        progressLayer.removeAnimation(forKey: Self.bounceAnimationKey)
    }
}
