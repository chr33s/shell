import Metal
import os
import QuartzCore
import SwifttyCore
#if canImport(UIKit)
import UIKit

typealias PlatformView = UIView
#else
import AppKit

/// macOS builds exist for headless tests; they never render.
typealias PlatformView = NSView
#endif

/// The surface's Metal layer. Named `IOSurfaceLayer` like libghostty's, which
/// the host finds among its view's sublayers to detect the first frame.
@objc(IOSurfaceLayer)
final class SurfaceLayer: CAMetalLayer, @unchecked Sendable {
    /// Set (on the render thread) once a frame has been presented; read on
    /// main through `contents`.
    private let presented = OSAllocatedUnfairLock(initialState: false)

    func markPresented() {
        presented.withLock { $0 = true }
    }

    override var contents: Any? {
        get { super.contents ?? (presented.withLock { $0 } ? NSNull() : nil) }
        set { super.contents = newValue }
    }
}

/// Draws a surface: owns its layer, the Metal renderer, the display link,
/// and the presentation state (focus, smooth scroll, insets, blink).
final class SurfaceRenderer: NSObject, @unchecked Sendable {
    struct Metrics {
        var width = 0.0 // framebuffer pixels
        var height = 0.0
        var scale = 2.0
        var cellWidth = 8.0
        var cellHeight = 16.0
        var paddingX = 4.0 // pixels
        var paddingY = 4.0
        var bottomInset = 0.0
    }

    weak var surface: Surface?
    private weak var view: PlatformView?
    private let layer: SurfaceLayer?
    private let device: MTLDevice?
    private var renderer: MetalRenderer?
    private let fontManager = CoreTextFontManager()

    private let lock = OSAllocatedUnfairLock()
    private let renderLock = NSLock()
    private var _metrics = Metrics()
    private var _grid = (columns: 80, rows: 24)
    private var _options = RenderOptions()
    private var config: Config
    private var fontSizeDelta = 0.0
    private var smoothOffset = 0.0 // pixels
    private var rubberBand = 0.0 // points
    private var _visible: Bool
    private var dirty = true
    #if canImport(UIKit)
    private var displayLink: CADisplayLink?
    #else
    private var displayLink: DisplayLinkStub?
    #endif
    private var frameRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
    private var blinkTimer: Timer?
    private var blinkOn = true
    /// Opacity from an animated blink style (1 for `normal`).
    private var blinkAlpha = 1.0
    private var lastInputTime = CACurrentMediaTime()
    var preedit: String? {
        get { lock.withLockUnchecked { _preedit } }
        set {
            lock.withLockUnchecked { _preedit = newValue }
            setNeedsDisplay()
        }
    }

    private var _preedit: String?

    init(view: PlatformView?, scale: Double, config: Config, visible: Bool) {
        self.view = view
        self.config = config
        _visible = visible
        device = MTLCreateSystemDefaultDevice()
        if view != nil, let device {
            let layer = SurfaceLayer()
            layer.device = device
            layer.pixelFormat = .bgra8Unorm
            layer.framebufferOnly = true
            layer.contentsScale = scale
            layer.isOpaque = config.backgroundOpacity >= 1
            self.layer = layer
        } else {
            layer = nil
        }
        super.init()
        _metrics.scale = scale
        if let device {
            renderer = try? MetalRenderer(device: device, fontManager: fontManager, font: fontDescriptor())
        }
        applyConfigLocked()
        if let layer, let view {
            onMain {
                layer.frame = view.bounds
                view.platformLayer?.addSublayer(layer)
            }
        }
        onRender { self.startDisplayLink() }
        refreshBlink()
    }

    func teardown() {
        onRender {
            self.displayLink?.invalidate()
            self.displayLink = nil
        }
        onMain {
            self.blinkTimer?.invalidate()
            self.blinkTimer = nil
            self.layer?.removeFromSuperlayer()
        }
    }

    /// Display-link work: the link lives on the shared render thread.
    private func onRender(_ body: @escaping @Sendable () -> Void) {
        RenderThread.shared.perform(body)
    }

    private var visible: Bool {
        lock.withLockUnchecked { _visible }
    }

    private func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async(execute: body)
        }
    }

    // MARK: Metrics

    var metrics: Metrics {
        lock.withLockUnchecked { _metrics }
    }

    var grid: (columns: Int, rows: Int) {
        lock.withLockUnchecked { _grid }
    }

    private func fontDescriptor() -> FontDescriptor {
        // Ghostty sizes fonts at 96 DPI outside macOS: points * 4/3.
        let points = max(4, config.fontSize + fontSizeDelta) * 4 / 3
        var d = FontDescriptor(family: config.effectiveFontFamily, size: points, scale: _metrics.scale)
        d.cellWidthAdjust = config.adjustCellWidth / 100
        d.cellHeightAdjust = config.adjustCellHeight / 100
        d.fallbackFamilies = ["Symbols Nerd Font Mono", "Symbols Nerd Font"]
        d.features = config.fontFeatures
        return d
    }

    /// Re-resolves the font and padding; returns whether the cell size changed.
    @discardableResult
    private func applyConfigLocked() -> Bool {
        let descriptor = lock.withLockUnchecked { () -> FontDescriptor in
            _metrics.paddingX = config.paddingX * _metrics.scale
            _metrics.paddingY = config.paddingY * _metrics.scale
            return fontDescriptor()
        }
        renderLock.lock()
        renderer?.setFont(descriptor)
        let cell = renderer.map { ($0.cellSize.width, $0.cellSize.height) }
        renderLock.unlock()
        guard let cell else { return false }
        return lock.withLockUnchecked {
            let changed = _metrics.cellWidth != cell.0 || _metrics.cellHeight != cell.1
            _metrics.cellWidth = cell.0
            _metrics.cellHeight = cell.1
            return changed
        }
    }

    func update(config: Config) {
        lock.withLockUnchecked { self.config = config }
        let changed = applyConfigLocked()
        onMain { self.layer?.isOpaque = config.backgroundOpacity >= 1 }
        refreshBlink()
        setNeedsDisplay(force: true)
        if changed {
            surface?.cellSizeChanged()
        }
    }

    func setContentScale(_ scale: Double) {
        let changed = lock.withLockUnchecked { () -> Bool in
            guard scale > 0, scale != _metrics.scale else { return false }
            _metrics.scale = scale
            return true
        }
        guard changed else { return }
        onMain { self.layer?.contentsScale = scale }
        if applyConfigLocked() {
            surface?.cellSizeChanged()
        }
    }

    /// Font size change in points; nil resets to the configured size.
    func adjustFontSize(by delta: Double?) {
        lock.withLockUnchecked { fontSizeDelta = delta.map { fontSizeDelta + $0 } ?? 0 }
        if applyConfigLocked() {
            surface?.cellSizeChanged()
        }
    }

    /// New framebuffer size; returns the grid that fits.
    func resize(width: Double, height: Double) -> (columns: Int, rows: Int) {
        let grid = lock.withLockUnchecked { () -> (columns: Int, rows: Int) in
            _metrics.width = width
            _metrics.height = height
            _grid = Self.grid(for: _metrics)
            return _grid
        }
        onMain {
            self.layer?.drawableSize = CGSize(width: max(1, width), height: max(1, height))
            self.setNeedsDisplay(force: true)
        }
        return grid
    }

    /// Bottom inset in pixels; returns the new grid when it changed.
    func setBottomInset(_ px: Double) -> (columns: Int, rows: Int)? {
        lock.withLockUnchecked {
            guard abs(_metrics.bottomInset - px) >= 0.5 else { return nil }
            _metrics.bottomInset = max(0, px)
            let grid = Self.grid(for: _metrics)
            guard grid != _grid else { return nil }
            _grid = grid
            return grid
        }
    }

    private static func grid(for m: Metrics) -> (columns: Int, rows: Int) {
        (
            max(1, Int((m.width - 2 * m.paddingX) / m.cellWidth)),
            max(1, Int((m.height - 2 * m.paddingY - m.bottomInset) / m.cellHeight)),
        )
    }

    // MARK: Presentation state

    func setFocused(_ focused: Bool) {
        lock.withLockUnchecked { _options.isFocused = focused }
        refreshBlink()
        setNeedsDisplay(force: true)
    }

    var isFocused: Bool {
        lock.withLockUnchecked { _options.isFocused }
    }

    func setSmoothOffset(_ px: Double) {
        lock.withLockUnchecked { smoothOffset = max(0, px) }
        setNeedsDisplay(force: true)
    }

    func setHoveredLink(_ id: UInt8) {
        let changed = lock.withLockUnchecked { () -> Bool in
            guard _options.hoveredLink != id else { return false }
            _options.hoveredLink = id
            return true
        }
        if changed {
            setNeedsDisplay(force: true)
        }
    }

    func setRubberBand(_ points: Double) {
        lock.withLockUnchecked { rubberBand = points }
        setNeedsDisplay(force: true)
    }

    var smoothScrollOffset: Double {
        lock.withLockUnchecked { smoothOffset }
    }

    func setVisible(_ visible: Bool) {
        lock.withLockUnchecked { _visible = visible }
        onRender { self.displayLink?.isPaused = !visible }
        if visible {
            setNeedsDisplay(force: true)
        }
    }

    func setFrameRateRange(min: Float, max: Float, preferred: Float) {
        onRender {
            self.frameRange = max == 0
                ? CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
                : CAFrameRateRange(minimum: Swift.min(min, max), maximum: max, preferred: Swift.min(Swift.max(preferred, min), max))
            self.displayLink?.preferredFrameRateRange = self.frameRange
        }
    }

    /// Input arrived: show the cursor solid for a blink period.
    func noteInput() {
        let wasOff = lock.withLockUnchecked { () -> Bool in
            lastInputTime = CACurrentMediaTime()
            let off = !blinkOn || blinkAlpha != 1
            blinkOn = true
            blinkAlpha = 1
            return off
        }
        if wasOff {
            setNeedsDisplay(force: true)
        }
    }

    private func refreshBlink() {
        onMain {
            let (focused, blink, mode) = self.lock.withLockUnchecked {
                (self._options.isFocused, self.config.cursorBlink, self.config.cursorBlinkMode)
            }
            let wantsTimer = focused && blink != false
            // Animated styles redraw the cursor row at 30 fps, only when the
            // config turns blinking on; otherwise a cheap on/off timer serves
            // applications that request a blinking cursor.
            let interval = mode != .normal && blink == true ? 1.0 / 30 : 0.6
            if wantsTimer, self.blinkTimer?.timeInterval != interval {
                self.blinkTimer?.invalidate()
                let timer = Timer(timeInterval: interval, repeats: true) { [weak renderer = self] _ in renderer?.blinkTick() }
                RunLoop.main.add(timer, forMode: .common)
                self.blinkTimer = timer
            } else if !wantsTimer {
                self.blinkTimer?.invalidate()
                self.blinkTimer = nil
                self.lock.withLockUnchecked {
                    self.blinkOn = true
                    self.blinkAlpha = 1
                }
            }
        }
    }

    private func blinkTick() {
        let (recent, blinkMode, mode, start) = lock.withLockUnchecked {
            (CACurrentMediaTime() - lastInputTime < 0.6, config.cursorBlink, config.cursorBlinkMode, lastInputTime)
        }
        let terminalBlinks = surface?.mirror.modes.contains(.cursorBlink) ?? false
        let animate = visible && (blinkMode == true || terminalBlinks)
        let changed = lock.withLockUnchecked { () -> Bool in
            let before = (blinkOn, blinkAlpha)
            if !animate {
                blinkOn = true
                blinkAlpha = 1
            } else if mode == .normal || blinkMode != true {
                blinkOn = recent ? true : !blinkOn
                blinkAlpha = 1
            } else {
                // Typing holds the cursor solid; the curve restarts afterwards.
                blinkOn = true
                blinkAlpha = recent ? 1 : CursorBlink.alpha(mode, at: CACurrentMediaTime() - start)
            }
            return before != (blinkOn, blinkAlpha)
        }
        if changed {
            setNeedsDisplay(force: true)
        }
    }

    // MARK: Drawing

    func setNeedsDisplay(force: Bool = false) {
        let wasDirty = lock.withLockUnchecked { () -> Bool in
            let was = dirty
            dirty = true
            return was && !force
        }
        guard !wasDirty, visible else { return }
        onRender { self.displayLink?.isPaused = false }
    }

    private func startDisplayLink() {
        #if canImport(UIKit)
        guard layer != nil, displayLink == nil else { return }
        let link = CADisplayLink(target: DisplayLinkTarget(self), selector: #selector(DisplayLinkTarget.tick))
        link.preferredFrameRateRange = frameRange
        link.add(to: RunLoop.current, forMode: .common)
        link.isPaused = !visible
        displayLink = link
        #endif
    }

    fileprivate func tick() {
        let needs = lock.withLockUnchecked { () -> Bool in
            let d = dirty
            dirty = false
            return d
        }
        guard needs, visible else {
            displayLink?.isPaused = true
            return
        }
        draw()
    }

    /// Draws one frame (render thread).
    private func draw() {
        guard let layer, let surface, visible else { return }
        let (options, overscan) = lock.withLockUnchecked { () -> (RenderOptions, Int) in
            var o = _options
            o.paddingX = _metrics.paddingX
            o.paddingY = _metrics.paddingY
            o.scrollOffset = smoothOffset - rubberBand * _metrics.scale
            o.backgroundOpacity = config.backgroundOpacity
            o.cursorVisible = blinkOn
            o.preedit = _preedit.map { Array($0.unicodeScalars) } ?? []
            switch config.cursorStyle {
            case .block: o.cursorStyle = nil
            case .blockHollow: o.cursorStyle = .block; o.hollowCursor = true
            case .bar: o.cursorStyle = .bar
            case .underline: o.cursorStyle = .underline
            }
            o.cursorColor = config.cursorColor
            o.cursorTextColor = config.cursorText ?? config.themeCursorText
            o.cursorOpacity = config.cursorOpacity * blinkAlpha
            let sel = config.effectiveSelection
            o.selectionForeground = sel.invert ? nil : sel.fg
            o.selectionBackground = sel.invert ? nil : sel.bg
            let extra = Int(ceil((smoothOffset + _metrics.bottomInset) / max(1, _metrics.cellHeight))) + 1
            return (o, extra)
        }
        let snapshot = surface.session.snapshot(overscan: overscan)
        renderLock.lock()
        defer { renderLock.unlock() }
        // drainToIdle may have run since the check above; it must win.
        guard visible else { return }
        if renderer?.draw(snapshot, options: options, layer: layer) == true {
            layer.markPresented()
        }
    }

    /// Stops drawing and waits for frames in flight (scene snapshot safety).
    func drainToIdle(timeout: UInt64) -> Bool {
        let deadline = DispatchTime.now() + .nanoseconds(Int(min(timeout, UInt64(Int.max))))
        lock.withLockUnchecked { _visible = false }
        onRender { self.displayLink?.isPaused = true }
        // Waits out a frame being encoded right now (bounded by the same
        // deadline), then the GPU.
        let seconds = Double(min(timeout, 60_000_000_000)) / 1_000_000_000
        guard renderLock.lock(before: Date(timeIntervalSinceNow: seconds)) else { return false }
        defer { renderLock.unlock() }
        return renderer?.waitUntilIdle(timeout: deadline) ?? true
    }
}

/// One thread with a run loop for every surface's display link, so frame
/// encoding never waits on (or blocks) the main thread.
final class RenderThread: Thread, @unchecked Sendable {
    static let shared: RenderThread = {
        let thread = RenderThread()
        thread.name = "ghostty.runtime.render"
        thread.qualityOfService = .userInteractive
        thread.start()
        thread.ready.wait()
        return thread
    }()

    private let ready = DispatchSemaphore(value: 0)
    private var runLoop: CFRunLoop?

    override func main() {
        runLoop = CFRunLoopGetCurrent()
        // A port keeps the run loop alive with no display links attached.
        RunLoop.current.add(NSMachPort(), forMode: .default)
        ready.signal()
        while true {
            autoreleasepool { _ = RunLoop.current.run(mode: .default, before: .distantFuture) }
        }
    }

    func perform(_ body: @escaping @Sendable () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, body)
        CFRunLoopWakeUp(runLoop)
    }
}

/// Breaks the display link's strong reference to its target.
private final class DisplayLinkTarget: NSObject {
    weak var renderer: SurfaceRenderer?

    init(_ renderer: SurfaceRenderer) {
        self.renderer = renderer
    }

    @objc func tick() {
        renderer?.tick()
    }
}

#if !canImport(UIKit)
/// Stand-in so headless macOS builds share the renderer's bookkeeping.
private final class DisplayLinkStub {
    var isPaused = true
    var preferredFrameRateRange = CAFrameRateRange.default
    func invalidate() {}
}
#endif

extension PlatformView {
    var platformLayer: CALayer? {
        layer as CALayer?
    }
}
