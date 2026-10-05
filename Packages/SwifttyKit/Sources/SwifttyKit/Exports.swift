// The embedder API functions. Each is a thin shim over App, Config, Surface and
// TmuxViewer.

import Foundation
import SwifttyCore

// MARK: Global

public func swiftty_simd_codepoint_width(_ cp: UInt32) -> Int8 {
    if cp == 0 || cp < 0x20 || (0x7F ..< 0xA0).contains(cp) {
        return -1
    }
    return Int8(UnicodeWidth.width(cp))
}

// MARK: Config

private func cfg(_ p: swiftty_config_t?) -> Config? {
    p.map { Unmanaged<Config>.fromOpaque($0).takeUnretainedValue() }
}

public func swiftty_config_new() -> swiftty_config_t? {
    Unmanaged.passRetained(Config()).toOpaque()
}

public func swiftty_config_free(_ c: swiftty_config_t?) {
    c.map { Unmanaged<Config>.fromOpaque($0).release() }
}

public func swiftty_config_clone(_ c: swiftty_config_t?) -> swiftty_config_t? {
    guard let config = cfg(c) else { return nil }
    return Unmanaged.passRetained(config.clone()).toOpaque()
}

public func swiftty_config_load_default_files(_ c: swiftty_config_t?) {
    cfg(c)?.loadDefaultFiles()
}

public func swiftty_config_finalize(_ c: swiftty_config_t?) {
    cfg(c)?.finalize()
}

public func swiftty_config_diagnostics_count(_ c: swiftty_config_t?) -> UInt32 {
    UInt32(cfg(c)?.diagnosticCount ?? 0)
}

/// Diagnostic messages, interned for the life of the process (there are few).
private nonisolated(unsafe) var diagnosticStrings: [String: UnsafeMutablePointer<CChar>] = [:]
private let diagnosticLock = NSLock()

public func swiftty_config_get_diagnostic(_ c: swiftty_config_t?, _ i: UInt32) -> swiftty_diagnostic_s {
    guard let message = cfg(c)?.diagnostic(Int(i)) else { return swiftty_diagnostic_s(message: nil) }
    diagnosticLock.lock()
    defer { diagnosticLock.unlock() }
    if let p = diagnosticStrings[message] {
        return swiftty_diagnostic_s(message: p)
    }
    let p = strdup(message)!
    diagnosticStrings[message] = p
    return swiftty_diagnostic_s(message: p)
}

// MARK: App

public func swiftty_app_new(_ runtime: UnsafePointer<swiftty_runtime_config_s>?, _ c: swiftty_config_t?) -> swiftty_app_t? {
    guard let runtime, let config = cfg(c) else { return nil }
    return Unmanaged.passRetained(App(runtime: runtime.pointee, config: config)).toOpaque()
}

public func swiftty_app_free(_ a: swiftty_app_t?) {
    a.map { Unmanaged<App>.fromOpaque($0).release() }
}

public func swiftty_app_update_config(_ a: swiftty_app_t?, _ c: swiftty_config_t?) {
    guard let app = App.from(a), let config = cfg(c) else { return }
    app.update(config: config)
}

public func swiftty_app_set_surface_content_events_enabled(_ a: swiftty_app_t?, _ enabled: Bool) {
    App.from(a)?.contentEventsEnabled = enabled
}

// MARK: Surface lifecycle

private func sfc(_ p: swiftty_surface_t?) -> Surface? {
    Surface.from(p)
}

public func swiftty_surface_config_new() -> swiftty_surface_config_s {
    var c = swiftty_surface_config_s()
    c.platform_tag = SWIFTTY_PLATFORM_IOS
    c.scale_factor = 2
    c.initially_visible = true
    return c
}

public func swiftty_surface_new(_ a: swiftty_app_t?, _ c: UnsafePointer<swiftty_surface_config_s>?) -> swiftty_surface_t? {
    guard let app = App.from(a), let c else { return nil }
    let surface = Surface(app: app, config: c.pointee)
    return Unmanaged.passRetained(surface).toOpaque()
}

public func swiftty_surface_free(_ s: swiftty_surface_t?) {
    guard let s else { return }
    let surface = Unmanaged<Surface>.fromOpaque(s)
    surface.takeUnretainedValue().free()
    surface.release()
}

public func swiftty_surface_userdata(_ s: swiftty_surface_t?) -> UnsafeMutableRawPointer? {
    sfc(s)?.userdata
}

public func swiftty_surface_update_config(_ s: swiftty_surface_t?, _ c: swiftty_config_t?) {
    guard let surface = sfc(s), let config = cfg(c) else { return }
    surface.update(config: config)
}

public func swiftty_surface_get_slave_fd(_ s: swiftty_surface_t?) -> Int32 {
    sfc(s)?.io?.inputFD ?? -1
}

public func swiftty_surface_response_read_fd(_ s: swiftty_surface_t?) -> Int32 {
    sfc(s)?.io?.responseFD ?? -1
}

public func swiftty_surface_request_close(_ s: swiftty_surface_t?) {
    guard let surface = sfc(s) else { return }
    surface.app.runtime.close_surface_cb?(surface.userdata, false)
}

// MARK: Rendering

public func swiftty_surface_refresh(_ s: swiftty_surface_t?) {
    sfc(s)?.renderer.setNeedsDisplay(force: true)
}

public func swiftty_surface_draw(_ s: swiftty_surface_t?) {
    sfc(s)?.renderer.setNeedsDisplay(force: true)
}

public func swiftty_surface_set_smooth_scroll_offset(_ s: swiftty_surface_t?, _ px: Double) {
    sfc(s)?.renderer.setSmoothOffset(px)
}

public func swiftty_surface_scroll_to_row_smooth(_ s: swiftty_surface_t?, _ row: UInt, _ px: Double) {
    guard let surface = sfc(s) else { return }
    surface.session.mutate { $0.scrollViewport(toTopRow: Int(row)) }
    surface.renderer.setSmoothOffset(px)
}

public func swiftty_surface_set_rubber_band_offset(_ s: swiftty_surface_t?, _ points: Double) {
    sfc(s)?.renderer.setRubberBand(points)
}

public func swiftty_surface_set_frame_rate_range(_ s: swiftty_surface_t?, _ min: UInt16, _ max: UInt16, _ preferred: UInt16) {
    sfc(s)?.renderer.setFrameRateRange(min: Float(min), max: Float(max), preferred: Float(preferred))
}

public func swiftty_surface_set_bottom_inset(_ s: swiftty_surface_t?, _ px: Double) {
    guard let surface = sfc(s), let grid = surface.renderer.setBottomInset(px) else { return }
    surface.resizeGrid(grid)
}

public func swiftty_surface_set_content_scale(_ s: swiftty_surface_t?, _ x: Double, _ y: Double) {
    sfc(s)?.renderer.setContentScale(x)
}

public func swiftty_surface_set_focus(_ s: swiftty_surface_t?, _ focused: Bool) {
    guard let surface = sfc(s), surface.renderer.isFocused != focused else { return }
    surface.renderer.setFocused(focused)
    surface.sendInput(.focus(focused))
}

public func swiftty_surface_set_occlusion(_ s: swiftty_surface_t?, _ visible: Bool) {
    sfc(s)?.renderer.setVisible(visible)
}

public func swiftty_surface_drain_renderer_to_idle(_ s: swiftty_surface_t?, _ timeout: UInt64) -> Bool {
    sfc(s)?.renderer.drainToIdle(timeout: timeout) ?? true
}

public func swiftty_surface_set_size(_ s: swiftty_surface_t?, _ width: UInt32, _ height: UInt32) {
    sfc(s)?.setSize(width: width, height: height)
}

public func swiftty_surface_size(_ s: swiftty_surface_t?) -> swiftty_surface_size_s {
    sfc(s)?.size ?? swiftty_surface_size_s()
}

// MARK: Input

public func swiftty_surface_key(_ s: swiftty_surface_t?, _ event: swiftty_input_key_s) -> Bool {
    sfc(s)?.key(event) ?? false
}

public func swiftty_surface_text(_ s: swiftty_surface_t?, _ ptr: UnsafePointer<CChar>?, _ len: UInt) {
    guard let surface = sfc(s), let ptr else { return }
    let text = String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(len)), as: UTF8.self)
    surface.sendText(text)
}

public func swiftty_surface_send_input(_ s: swiftty_surface_t?, _ ptr: UnsafePointer<CChar>?, _ len: UInt) {
    guard let surface = sfc(s), let ptr else { return }
    surface.sendRaw(Array(UnsafeRawBufferPointer(start: ptr, count: Int(len))))
}

public func swiftty_surface_preedit(_ s: swiftty_surface_t?, _ ptr: UnsafePointer<CChar>?, _ len: UInt) {
    guard let surface = sfc(s) else { return }
    surface.renderer.preedit = ptr.flatMap { len > 0 ? String(decoding: UnsafeRawBufferPointer(start: $0, count: Int(len)), as: UTF8.self) : nil }
}

public func swiftty_surface_ime_point(
    _ s: swiftty_surface_t?, _ x: UnsafeMutablePointer<Double>?, _ y: UnsafeMutablePointer<Double>?,
    _ w: UnsafeMutablePointer<Double>?, _ h: UnsafeMutablePointer<Double>?,
) {
    guard let p = sfc(s)?.imePoint() else { return }
    x?.pointee = p.x
    y?.pointee = p.y
    w?.pointee = p.width
    h?.pointee = p.height
}

public func swiftty_surface_mouse_captured(_ s: swiftty_surface_t?) -> Bool {
    sfc(s)?.mouseCaptured ?? false
}

public func swiftty_surface_mouse_button(
    _ s: swiftty_surface_t?, _ state: swiftty_input_mouse_state_e, _ button: swiftty_input_mouse_button_e,
    _ mods: swiftty_input_mods_e,
) -> Bool {
    sfc(s)?.mouseButton(state: state, button: button, mods: mods.rawValue) ?? false
}

public func swiftty_surface_mouse_pos(_ s: swiftty_surface_t?, _ x: Double, _ y: Double, _ mods: swiftty_input_mods_e) {
    sfc(s)?.mousePos(x: x, y: y, mods: mods.rawValue)
}

public func swiftty_surface_mouse_scroll(_ s: swiftty_surface_t?, _ dx: Double, _ dy: Double, _ mods: swiftty_input_scroll_mods_t) {
    sfc(s)?.mouseScroll(dx: dx, dy: dy, scrollMods: mods)
}

public func swiftty_surface_binding_action(_ s: swiftty_surface_t?, _ ptr: UnsafePointer<CChar>?, _ len: UInt) -> Bool {
    guard let surface = sfc(s), let ptr else { return false }
    let action = String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(len)), as: UTF8.self)
    return surface.performBinding(action)
}

public func swiftty_surface_complete_clipboard_request(_ s: swiftty_surface_t?, _ text: UnsafePointer<CChar>?, _ state: UnsafeMutableRawPointer?, _ confirmed: Bool) {
    guard let surface = sfc(s) else { return }
    surface.completeClipboard(text.map { String(cString: $0) } ?? "", state: state, confirmed: confirmed)
}

public func swiftty_surface_cursor_key_mode(_ s: swiftty_surface_t?) -> Bool {
    sfc(s)?.mirror.modes.contains(.cursorKeys) ?? false
}

// MARK: Selection and text

public func swiftty_surface_has_selection(_ s: swiftty_surface_t?) -> Bool {
    sfc(s)?.mirror.hasSelection ?? false
}

/// Whether the point (as for `swiftty_surface_mouse_pos`) lies in a
/// command whose output OSC 133 marked.
public func swiftty_surface_has_command_output(_ s: swiftty_surface_t?, _ x: Double, _ y: Double) -> Bool {
    sfc(s)?.hasCommandOutput(atPoints: x, y) ?? false
}

/// Selects the output of the command at the point; false when there is none.
@discardableResult
public func swiftty_surface_select_command_output(_ s: swiftty_surface_t?, _ x: Double, _ y: Double) -> Bool {
    guard let surface = sfc(s) else { return false }
    return surface.selectCommandOutput(at: surface.cell(atPoints: x, y))
}

private func fill(_ out: UnsafeMutablePointer<swiftty_text_s>, text: String) {
    let bytes = Array(text.utf8)
    let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count + 1)
    bytes.withUnsafeBufferPointer { src in
        UnsafeMutableRawPointer(buffer).copyMemory(from: src.baseAddress!, byteCount: bytes.count)
    }
    buffer[bytes.count] = 0
    out.pointee.text = UnsafePointer(buffer)
    out.pointee.text_len = UInt(bytes.count)
}

public func swiftty_surface_read_selection(_ s: swiftty_surface_t?, _ out: UnsafeMutablePointer<swiftty_text_s>?) -> Bool {
    guard let surface = sfc(s), let out, let sel = surface.readSelection() else { return false }
    let m = surface.renderer.metrics
    out.pointee = swiftty_text_s()
    out.pointee.tl_px_x = (m.paddingX + Double(sel.startColumn) * m.cellWidth) / m.scale
    out.pointee.tl_px_y = (m.paddingY + Double(sel.startRow) * m.cellHeight) / m.scale
    out.pointee.offset_start = UInt32(sel.startOffset)
    out.pointee.offset_len = UInt32(sel.length)
    fill(out, text: sel.text)
    return true
}

public func swiftty_surface_read_text(_ s: swiftty_surface_t?, _ selection: swiftty_selection_s, _ out: UnsafeMutablePointer<swiftty_text_s>?) -> Bool {
    guard let surface = sfc(s), let out, let text = surface.readText(selection) else { return false }
    out.pointee = swiftty_text_s()
    fill(out, text: text)
    return true
}

public func swiftty_surface_free_text(_ s: swiftty_surface_t?, _ text: UnsafeMutablePointer<swiftty_text_s>?) {
    guard let text, let p = text.pointee.text else { return }
    UnsafeMutablePointer(mutating: p).deallocate()
    text.pointee.text = nil
    text.pointee.text_len = 0
}

public func swiftty_surface_selection_handle_drag_begin(_ s: swiftty_surface_t?, _ draggingStart: Bool) -> Bool {
    sfc(s)?.beginHandleDrag(draggingStart: draggingStart) ?? false
}

public func swiftty_surface_selection_viewport_visibility(_ s: swiftty_surface_t?, _ start: UnsafeMutablePointer<Bool>?, _ end: UnsafeMutablePointer<Bool>?) -> Bool {
    guard let mirror = sfc(s)?.mirror, mirror.hasSelection else { return false }
    start?.pointee = mirror.selectionVisible.start
    end?.pointee = mirror.selectionVisible.end
    return true
}

public func swiftty_surface_display_scrollbar(_ s: swiftty_surface_t?, _ out: UnsafeMutablePointer<swiftty_action_scrollbar_s>?) -> Bool {
    guard let bar = sfc(s)?.mirror.scrollbar, bar.total > bar.len else { return false }
    out?.pointee = swiftty_action_scrollbar_s(total: UInt64(bar.total), offset: UInt64(bar.offset), len: UInt64(bar.len))
    return true
}

public func swiftty_surface_is_alternate_active(_ s: swiftty_surface_t?) -> Bool {
    sfc(s)?.mirror.isAlternate ?? false
}

public func swiftty_surface_dump_primary_screen(_ s: swiftty_surface_t?, _ len: UnsafeMutablePointer<UInt>?) -> UnsafePointer<CChar>? {
    guard let surface = sfc(s) else { return nil }
    let bytes = surface.session.withState { $0.dumpPrimaryANSI() }
    guard !bytes.isEmpty else {
        len?.pointee = 0
        return nil
    }
    let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count + 1)
    bytes.withUnsafeBytes { UnsafeMutableRawPointer(buffer).copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
    buffer[bytes.count] = 0
    len?.pointee = UInt(bytes.count)
    return UnsafePointer(buffer)
}

public func swiftty_surface_free_dump(_ ptr: UnsafePointer<CChar>?, _ len: UInt) {
    ptr.map { UnsafeMutablePointer(mutating: $0).deallocate() }
}

// MARK: tmux

private func viewer(_ s: swiftty_surface_t?) -> TmuxViewer? {
    sfc(s)?.tmux
}

public func swiftty_surface_new_tmux_pane(
    _ a: swiftty_app_t?, _ parent: swiftty_surface_t?, _ window: UInt, _ pane: UInt,
    _ terminal: UnsafeMutableRawPointer?, _ viewerPane: UnsafeMutableRawPointer?,
    _ c: UnsafePointer<swiftty_surface_config_s>?,
) -> swiftty_surface_t? {
    // Resolve the pane by id through the live viewer rather than trusting
    // the (possibly stale) pointers from an earlier reconcile batch.
    guard let app = App.from(a), let c, let viewer = viewer(parent), let tmuxPane = viewer.pane(id: Int(pane)) else { return nil }
    let surface = Surface(app: app, config: c.pointee, pane: (tmuxPane, viewer))
    return Unmanaged.passRetained(surface).toOpaque()
}

public func swiftty_surface_tmux_active(_ s: swiftty_surface_t?) -> Bool {
    viewer(s)?.isActive ?? false
}

public func swiftty_surface_tmux_command(_ s: swiftty_surface_t?, _ ptr: UnsafePointer<CChar>?, _ len: UInt) {
    guard let ptr else { return }
    viewer(s)?.command(String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(len)), as: UTF8.self), tag: nil)
}

public func swiftty_surface_tmux_command_with_reply(_ s: swiftty_surface_t?, _ ptr: UnsafePointer<CChar>?, _ len: UInt, _ tag: UInt32) {
    guard let ptr else { return }
    let text = String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(len)), as: UTF8.self)
    if let viewer = viewer(s) {
        viewer.command(text, tag: tag)
    } else if let surface = sfc(s) {
        var action = swiftty_action_s()
        action.tag = SWIFTTY_ACTION_TMUX_COMMAND_RESPONSE
        action.action.tmux_command_response = swiftty_action_tmux_command_response_s(tag: tag, is_err: true, body: nil, body_len: 0)
        let a = action
        surface.app.post(surface) { send in send(a) }
    }
}

public func swiftty_surface_tmux_set_client_size(_ s: swiftty_surface_t?, _ columns: UInt16, _ rows: UInt16) {
    viewer(s)?.setClientSize(columns: Int(columns), rows: Int(rows))
}

public func swiftty_surface_tmux_detach(_ s: swiftty_surface_t?) {
    viewer(s)?.detach()
}

/// Starts control mode on a gateway that never saw `DCS 1000 p`.
private func resume(_ s: swiftty_surface_t?, priority: Int?) {
    guard let surface = sfc(s) else { return }
    if let viewer = surface.tmux, viewer.isActive {
        viewer.resume(priority: priority)
        return
    }
    let viewer = TmuxViewer(gateway: surface)
    surface.tmux = viewer
    viewer.resume(priority: priority)
    // Put the gateway's parser into the control-mode DCS so the stream
    // that follows is routed to the viewer.
    surface.session.receive(Array("\u{1B}P1000p".utf8))
}

public func swiftty_surface_tmux_resume(_ s: swiftty_surface_t?) {
    resume(s, priority: nil)
}

public func swiftty_surface_tmux_resume_prioritized(_ s: swiftty_surface_t?, _ window: UInt) {
    resume(s, priority: Int(window))
}

public func swiftty_surface_tmux_resume_abort(_ s: swiftty_surface_t?) {
    viewer(s)?.forceExit()
}

public func swiftty_surface_tmux_force_exit(_ s: swiftty_surface_t?) {
    viewer(s)?.forceExit()
}

public func swiftty_surface_tmux_recover(_ s: swiftty_surface_t?) {
    viewer(s)?.recover()
}

public func swiftty_surface_tmux_reset(_ s: swiftty_surface_t?) {
    viewer(s)?.resetPanes(priority: nil)
}

public func swiftty_surface_tmux_reset_prioritized(_ s: swiftty_surface_t?, _ window: UInt) {
    viewer(s)?.resetPanes(priority: Int(window))
}

public func swiftty_surface_tmux_reprobe(_ s: swiftty_surface_t?) {
    viewer(s)?.reprobe()
}

public func swiftty_surface_tmux_flush_deferred(_ s: swiftty_surface_t?) {
    viewer(s)?.flushDeferred()
}

public func swiftty_surface_tmux_debug_snapshot(_ s: swiftty_surface_t?, _ out: UnsafeMutablePointer<swiftty_tmux_debug_snapshot_s>?) -> Bool {
    guard let viewer = viewer(s), let out else { return false }
    viewer.debugSnapshot(&out.pointee)
    return true
}
