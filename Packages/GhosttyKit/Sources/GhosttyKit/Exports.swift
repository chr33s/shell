// The embedder API functions, named as in Ghostty's ghostty.h. Each is a thin
// shim over App, Config, Surface and TmuxViewer.

import Foundation
import SwifttyCore

// MARK: Global

public func ghostty_init(_ argc: UInt, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    GHOSTTY_SUCCESS
}

public func ghostty_simd_codepoint_width(_ cp: UInt32) -> Int8 {
    if cp == 0 || cp < 0x20 || (0x7F ..< 0xA0).contains(cp) {
        return -1
    }
    return Int8(UnicodeWidth.width(cp))
}

public func ghostty_set_window_background_blur(_ app: ghostty_app_t?, _ window: UnsafeMutableRawPointer?) {
    // Window blur is applied by the host (NSVisualEffectView); nothing to do.
}

// MARK: Config

private func cfg(_ p: ghostty_config_t?) -> Config? {
    p.map { Unmanaged<Config>.fromOpaque($0).takeUnretainedValue() }
}

public func ghostty_config_new() -> ghostty_config_t? {
    Unmanaged.passRetained(Config()).toOpaque()
}

public func ghostty_config_free(_ c: ghostty_config_t?) {
    c.map { Unmanaged<Config>.fromOpaque($0).release() }
}

public func ghostty_config_clone(_ c: ghostty_config_t?) -> ghostty_config_t? {
    guard let config = cfg(c) else { return nil }
    return Unmanaged.passRetained(config.clone()).toOpaque()
}

public func ghostty_config_load_default_files(_ c: ghostty_config_t?) {
    cfg(c)?.loadDefaultFiles()
}

public func ghostty_config_finalize(_ c: ghostty_config_t?) {
    cfg(c)?.finalize()
}

public func ghostty_config_diagnostics_count(_ c: ghostty_config_t?) -> UInt32 {
    UInt32(cfg(c)?.diagnosticCount ?? 0)
}

/// Diagnostic messages, interned for the life of the process (there are few).
private nonisolated(unsafe) var diagnosticStrings: [String: UnsafeMutablePointer<CChar>] = [:]
private let diagnosticLock = NSLock()

public func ghostty_config_get_diagnostic(_ c: ghostty_config_t?, _ i: UInt32) -> ghostty_diagnostic_s {
    guard let message = cfg(c)?.diagnostic(Int(i)) else { return ghostty_diagnostic_s(message: nil) }
    diagnosticLock.lock()
    defer { diagnosticLock.unlock() }
    if let p = diagnosticStrings[message] {
        return ghostty_diagnostic_s(message: p)
    }
    let p = strdup(message)!
    diagnosticStrings[message] = p
    return ghostty_diagnostic_s(message: p)
}

// MARK: App

public func ghostty_app_new(_ runtime: UnsafePointer<ghostty_runtime_config_s>?, _ c: ghostty_config_t?) -> ghostty_app_t? {
    guard let runtime, let config = cfg(c) else { return nil }
    return Unmanaged.passRetained(App(runtime: runtime.pointee, config: config)).toOpaque()
}

public func ghostty_app_free(_ a: ghostty_app_t?) {
    a.map { Unmanaged<App>.fromOpaque($0).release() }
}

public func ghostty_app_tick(_ a: ghostty_app_t?) {
    // Actions are delivered as they happen; there is no mailbox to drain.
}

public func ghostty_app_update_config(_ a: ghostty_app_t?, _ c: ghostty_config_t?) {
    guard let app = App.from(a), let config = cfg(c) else { return }
    app.update(config: config)
}

public func ghostty_app_set_surface_content_events_enabled(_ a: ghostty_app_t?, _ enabled: Bool) {
    App.from(a)?.contentEventsEnabled = enabled
}

// MARK: Surface lifecycle

private func sfc(_ p: ghostty_surface_t?) -> Surface? {
    Surface.from(p)
}

public func ghostty_surface_config_new() -> ghostty_surface_config_s {
    var c = ghostty_surface_config_s()
    c.platform_tag = GHOSTTY_PLATFORM_IOS
    c.scale_factor = 2
    c.initially_visible = true
    return c
}

public func ghostty_surface_new(_ a: ghostty_app_t?, _ c: UnsafePointer<ghostty_surface_config_s>?) -> ghostty_surface_t? {
    guard let app = App.from(a), let c else { return nil }
    let surface = Surface(app: app, config: c.pointee)
    return Unmanaged.passRetained(surface).toOpaque()
}

public func ghostty_surface_free(_ s: ghostty_surface_t?) {
    guard let s else { return }
    let surface = Unmanaged<Surface>.fromOpaque(s)
    surface.takeUnretainedValue().free()
    surface.release()
}

public func ghostty_surface_userdata(_ s: ghostty_surface_t?) -> UnsafeMutableRawPointer? {
    sfc(s)?.userdata
}

public func ghostty_surface_update_config(_ s: ghostty_surface_t?, _ c: ghostty_config_t?) {
    guard let surface = sfc(s), let config = cfg(c) else { return }
    surface.update(config: config)
}

public func ghostty_surface_get_slave_fd(_ s: ghostty_surface_t?) -> Int32 {
    sfc(s)?.io?.inputFD ?? -1
}

public func ghostty_surface_response_read_fd(_ s: ghostty_surface_t?) -> Int32 {
    sfc(s)?.io?.responseFD ?? -1
}

public func ghostty_surface_request_close(_ s: ghostty_surface_t?) {
    guard let surface = sfc(s) else { return }
    surface.app.runtime.close_surface_cb?(surface.userdata, false)
}

// MARK: Rendering

public func ghostty_surface_refresh(_ s: ghostty_surface_t?) {
    sfc(s)?.renderer.setNeedsDisplay(force: true)
}

public func ghostty_surface_draw(_ s: ghostty_surface_t?) {
    sfc(s)?.renderer.setNeedsDisplay(force: true)
}

public func ghostty_surface_set_smooth_scroll_offset(_ s: ghostty_surface_t?, _ px: Double) {
    sfc(s)?.renderer.setSmoothOffset(px)
}

public func ghostty_surface_scroll_to_row_smooth(_ s: ghostty_surface_t?, _ row: UInt, _ px: Double) {
    guard let surface = sfc(s) else { return }
    surface.session.mutate { $0.scrollViewport(toTopRow: Int(row)) }
    surface.renderer.setSmoothOffset(px)
}

public func ghostty_surface_set_rubber_band_offset(_ s: ghostty_surface_t?, _ points: Double) {
    sfc(s)?.renderer.setRubberBand(points)
}

public func ghostty_surface_set_frame_rate_range(_ s: ghostty_surface_t?, _ min: UInt16, _ max: UInt16, _ preferred: UInt16) {
    sfc(s)?.renderer.setFrameRateRange(min: Float(min), max: Float(max), preferred: Float(preferred))
}

public func ghostty_surface_set_bottom_inset(_ s: ghostty_surface_t?, _ px: Double) {
    guard let surface = sfc(s), let grid = surface.renderer.setBottomInset(px) else { return }
    surface.resizeGrid(grid)
}

public func ghostty_surface_set_content_scale(_ s: ghostty_surface_t?, _ x: Double, _ y: Double) {
    sfc(s)?.renderer.setContentScale(x)
}

public func ghostty_surface_set_focus(_ s: ghostty_surface_t?, _ focused: Bool) {
    guard let surface = sfc(s), surface.renderer.isFocused != focused else { return }
    surface.renderer.setFocused(focused)
    surface.sendInput(.focus(focused))
}

public func ghostty_surface_set_occlusion(_ s: ghostty_surface_t?, _ visible: Bool) {
    sfc(s)?.renderer.setVisible(visible)
}

public func ghostty_surface_drain_renderer_to_idle(_ s: ghostty_surface_t?, _ timeout: UInt64) -> Bool {
    sfc(s)?.renderer.drainToIdle(timeout: timeout) ?? true
}

public func ghostty_surface_set_size(_ s: ghostty_surface_t?, _ width: UInt32, _ height: UInt32) {
    sfc(s)?.setSize(width: width, height: height)
}

public func ghostty_surface_size(_ s: ghostty_surface_t?) -> ghostty_surface_size_s {
    sfc(s)?.size ?? ghostty_surface_size_s()
}

// MARK: Input

public func ghostty_surface_key(_ s: ghostty_surface_t?, _ event: ghostty_input_key_s) -> Bool {
    sfc(s)?.key(event) ?? false
}

public func ghostty_surface_text(_ s: ghostty_surface_t?, _ ptr: UnsafePointer<CChar>?, _ len: UInt) {
    guard let surface = sfc(s), let ptr else { return }
    let text = String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(len)), as: UTF8.self)
    surface.sendText(text)
}

public func ghostty_surface_send_input(_ s: ghostty_surface_t?, _ ptr: UnsafePointer<CChar>?, _ len: UInt) {
    guard let surface = sfc(s), let ptr else { return }
    surface.sendRaw(Array(UnsafeRawBufferPointer(start: ptr, count: Int(len))))
}

public func ghostty_surface_preedit(_ s: ghostty_surface_t?, _ ptr: UnsafePointer<CChar>?, _ len: UInt) {
    guard let surface = sfc(s) else { return }
    surface.renderer.preedit = ptr.flatMap { len > 0 ? String(decoding: UnsafeRawBufferPointer(start: $0, count: Int(len)), as: UTF8.self) : nil }
}

public func ghostty_surface_ime_point(
    _ s: ghostty_surface_t?, _ x: UnsafeMutablePointer<Double>?, _ y: UnsafeMutablePointer<Double>?,
    _ w: UnsafeMutablePointer<Double>?, _ h: UnsafeMutablePointer<Double>?,
) {
    guard let p = sfc(s)?.imePoint() else { return }
    x?.pointee = p.x
    y?.pointee = p.y
    w?.pointee = p.width
    h?.pointee = p.height
}

public func ghostty_surface_mouse_captured(_ s: ghostty_surface_t?) -> Bool {
    sfc(s)?.mouseCaptured ?? false
}

public func ghostty_surface_mouse_button(
    _ s: ghostty_surface_t?, _ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e,
    _ mods: ghostty_input_mods_e,
) -> Bool {
    sfc(s)?.mouseButton(state: state, button: button, mods: mods.rawValue) ?? false
}

public func ghostty_surface_mouse_pos(_ s: ghostty_surface_t?, _ x: Double, _ y: Double, _ mods: ghostty_input_mods_e) {
    sfc(s)?.mousePos(x: x, y: y, mods: mods.rawValue)
}

public func ghostty_surface_mouse_scroll(_ s: ghostty_surface_t?, _ dx: Double, _ dy: Double, _ mods: ghostty_input_scroll_mods_t) {
    sfc(s)?.mouseScroll(dx: dx, dy: dy, scrollMods: mods)
}

public func ghostty_surface_binding_action(_ s: ghostty_surface_t?, _ ptr: UnsafePointer<CChar>?, _ len: UInt) -> Bool {
    guard let surface = sfc(s), let ptr else { return false }
    let action = String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(len)), as: UTF8.self)
    return surface.performBinding(action)
}

public func ghostty_surface_complete_clipboard_request(_ s: ghostty_surface_t?, _ text: UnsafePointer<CChar>?, _ state: UnsafeMutableRawPointer?, _ confirmed: Bool) {
    guard let surface = sfc(s) else { return }
    surface.completeClipboard(text.map { String(cString: $0) } ?? "", state: state, confirmed: confirmed)
}

public func ghostty_surface_cursor_key_mode(_ s: ghostty_surface_t?) -> Bool {
    sfc(s)?.mirror.modes.contains(.cursorKeys) ?? false
}

// MARK: Selection and text

public func ghostty_surface_has_selection(_ s: ghostty_surface_t?) -> Bool {
    sfc(s)?.mirror.hasSelection ?? false
}

private func fill(_ out: UnsafeMutablePointer<ghostty_text_s>, text: String) {
    let bytes = Array(text.utf8)
    let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count + 1)
    bytes.withUnsafeBufferPointer { src in
        UnsafeMutableRawPointer(buffer).copyMemory(from: src.baseAddress!, byteCount: bytes.count)
    }
    buffer[bytes.count] = 0
    out.pointee.text = UnsafePointer(buffer)
    out.pointee.text_len = UInt(bytes.count)
}

public func ghostty_surface_read_selection(_ s: ghostty_surface_t?, _ out: UnsafeMutablePointer<ghostty_text_s>?) -> Bool {
    guard let surface = sfc(s), let out, let sel = surface.readSelection() else { return false }
    let m = surface.renderer.metrics
    out.pointee = ghostty_text_s()
    out.pointee.tl_px_x = (m.paddingX + Double(sel.startColumn) * m.cellWidth) / m.scale
    out.pointee.tl_px_y = (m.paddingY + Double(sel.startRow) * m.cellHeight) / m.scale
    out.pointee.offset_start = UInt32(sel.startOffset)
    out.pointee.offset_len = UInt32(sel.length)
    fill(out, text: sel.text)
    return true
}

public func ghostty_surface_read_text(_ s: ghostty_surface_t?, _ selection: ghostty_selection_s, _ out: UnsafeMutablePointer<ghostty_text_s>?) -> Bool {
    guard let surface = sfc(s), let out, let text = surface.readText(selection) else { return false }
    out.pointee = ghostty_text_s()
    fill(out, text: text)
    return true
}

public func ghostty_surface_free_text(_ s: ghostty_surface_t?, _ text: UnsafeMutablePointer<ghostty_text_s>?) {
    guard let text, let p = text.pointee.text else { return }
    UnsafeMutablePointer(mutating: p).deallocate()
    text.pointee.text = nil
    text.pointee.text_len = 0
}

public func ghostty_surface_selection_handle_drag_begin(_ s: ghostty_surface_t?, _ draggingStart: Bool) -> Bool {
    sfc(s)?.beginHandleDrag(draggingStart: draggingStart) ?? false
}

public func ghostty_surface_selection_viewport_visibility(_ s: ghostty_surface_t?, _ start: UnsafeMutablePointer<Bool>?, _ end: UnsafeMutablePointer<Bool>?) -> Bool {
    guard let mirror = sfc(s)?.mirror, mirror.hasSelection else { return false }
    start?.pointee = mirror.selectionVisible.start
    end?.pointee = mirror.selectionVisible.end
    return true
}

public func ghostty_surface_display_scrollbar(_ s: ghostty_surface_t?, _ out: UnsafeMutablePointer<ghostty_action_scrollbar_s>?) -> Bool {
    guard let bar = sfc(s)?.mirror.scrollbar, bar.total > bar.len else { return false }
    out?.pointee = ghostty_action_scrollbar_s(total: UInt64(bar.total), offset: UInt64(bar.offset), len: UInt64(bar.len))
    return true
}

public func ghostty_surface_is_alternate_active(_ s: ghostty_surface_t?) -> Bool {
    sfc(s)?.mirror.isAlternate ?? false
}

public func ghostty_surface_dump_primary_screen(_ s: ghostty_surface_t?, _ len: UnsafeMutablePointer<UInt>?) -> UnsafePointer<CChar>? {
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

public func ghostty_surface_free_dump(_ ptr: UnsafePointer<CChar>?, _ len: UInt) {
    ptr.map { UnsafeMutablePointer(mutating: $0).deallocate() }
}

// MARK: tmux

private func viewer(_ s: ghostty_surface_t?) -> TmuxViewer? {
    sfc(s)?.tmux
}

public func ghostty_surface_new_tmux_pane(
    _ a: ghostty_app_t?, _ parent: ghostty_surface_t?, _ window: UInt, _ pane: UInt,
    _ terminal: UnsafeMutableRawPointer?, _ viewerPane: UnsafeMutableRawPointer?,
    _ c: UnsafePointer<ghostty_surface_config_s>?,
) -> ghostty_surface_t? {
    // Resolve the pane by id through the live viewer rather than trusting
    // the (possibly stale) pointers from an earlier reconcile batch.
    guard let app = App.from(a), let c, let viewer = viewer(parent), let tmuxPane = viewer.pane(id: Int(pane)) else { return nil }
    let surface = Surface(app: app, config: c.pointee, pane: (tmuxPane, viewer))
    return Unmanaged.passRetained(surface).toOpaque()
}

public func ghostty_surface_tmux_active(_ s: ghostty_surface_t?) -> Bool {
    viewer(s)?.isActive ?? false
}

public func ghostty_surface_tmux_command(_ s: ghostty_surface_t?, _ ptr: UnsafePointer<CChar>?, _ len: UInt) {
    guard let ptr else { return }
    viewer(s)?.command(String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(len)), as: UTF8.self), tag: nil)
}

public func ghostty_surface_tmux_command_with_reply(_ s: ghostty_surface_t?, _ ptr: UnsafePointer<CChar>?, _ len: UInt, _ tag: UInt32) {
    guard let ptr else { return }
    let text = String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(len)), as: UTF8.self)
    if let viewer = viewer(s) {
        viewer.command(text, tag: tag)
    } else if let surface = sfc(s) {
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_TMUX_COMMAND_RESPONSE
        action.action.tmux_command_response = ghostty_action_tmux_command_response_s(tag: tag, is_err: true, body: nil, body_len: 0)
        let a = action
        surface.app.post(surface) { send in send(a) }
    }
}

public func ghostty_surface_tmux_set_client_size(_ s: ghostty_surface_t?, _ columns: UInt16, _ rows: UInt16) {
    viewer(s)?.setClientSize(columns: Int(columns), rows: Int(rows))
}

public func ghostty_surface_tmux_detach(_ s: ghostty_surface_t?) {
    viewer(s)?.detach()
}

/// Starts control mode on a gateway that never saw `DCS 1000 p`.
private func resume(_ s: ghostty_surface_t?, priority: Int?) {
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

public func ghostty_surface_tmux_resume(_ s: ghostty_surface_t?) {
    resume(s, priority: nil)
}

public func ghostty_surface_tmux_resume_prioritized(_ s: ghostty_surface_t?, _ window: UInt) {
    resume(s, priority: Int(window))
}

public func ghostty_surface_tmux_resume_abort(_ s: ghostty_surface_t?) {
    viewer(s)?.forceExit()
}

public func ghostty_surface_tmux_force_exit(_ s: ghostty_surface_t?) {
    viewer(s)?.forceExit()
}

public func ghostty_surface_tmux_recover(_ s: ghostty_surface_t?) {
    viewer(s)?.recover()
}

public func ghostty_surface_tmux_reset(_ s: ghostty_surface_t?) {
    viewer(s)?.resetPanes(priority: nil)
}

public func ghostty_surface_tmux_reset_prioritized(_ s: ghostty_surface_t?, _ window: UInt) {
    viewer(s)?.resetPanes(priority: Int(window))
}

public func ghostty_surface_tmux_reprobe(_ s: ghostty_surface_t?) {
    viewer(s)?.reprobe()
}

public func ghostty_surface_tmux_flush_deferred(_ s: ghostty_surface_t?) {
    viewer(s)?.flushDeferred()
}

public func ghostty_surface_tmux_debug_snapshot(_ s: ghostty_surface_t?, _ out: UnsafeMutablePointer<ghostty_tmux_debug_snapshot_s>?) -> Bool {
    guard let viewer = viewer(s), let out else { return false }
    viewer.debugSnapshot(&out.pointee)
    return true
}
