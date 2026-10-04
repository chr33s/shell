// The C entry points declared in ghostty.h. Each is a thin shim over App,
// Config, Surface and TmuxViewer; Swift names are prefixed so they never
// shadow the imported C declarations.

import Foundation
import GhosttyKit
import SwifttyCore

// MARK: Global

@_cdecl("ghostty_init")
public func rt_init(_ argc: UInt, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    GHOSTTY_SUCCESS
}

@_cdecl("ghostty_simd_codepoint_width")
public func rt_codepointWidth(_ cp: UInt32) -> Int8 {
    if cp == 0 || cp < 0x20 || (0x7F ..< 0xA0).contains(cp) {
        return -1
    }
    return Int8(UnicodeWidth.width(cp))
}

@_cdecl("ghostty_set_window_background_blur")
public func rt_setWindowBackgroundBlur(_ app: ghostty_app_t?, _ window: UnsafeMutableRawPointer?) {
    // Window blur is applied by the host (NSVisualEffectView); nothing to do.
}

// MARK: Config

private func cfg(_ p: ghostty_config_t?) -> Config? {
    p.map { Unmanaged<Config>.fromOpaque($0).takeUnretainedValue() }
}

@_cdecl("ghostty_config_new")
public func rt_configNew() -> ghostty_config_t? {
    Unmanaged.passRetained(Config()).toOpaque()
}

@_cdecl("ghostty_config_free")
public func rt_configFree(_ c: ghostty_config_t?) {
    c.map { Unmanaged<Config>.fromOpaque($0).release() }
}

@_cdecl("ghostty_config_clone")
public func rt_configClone(_ c: ghostty_config_t?) -> ghostty_config_t? {
    guard let config = cfg(c) else { return nil }
    return Unmanaged.passRetained(config.clone()).toOpaque()
}

@_cdecl("ghostty_config_load_default_files")
public func rt_configLoadDefaultFiles(_ c: ghostty_config_t?) {
    cfg(c)?.loadDefaultFiles()
}

@_cdecl("ghostty_config_finalize")
public func rt_configFinalize(_ c: ghostty_config_t?) {
    cfg(c)?.finalize()
}

@_cdecl("ghostty_config_diagnostics_count")
public func rt_configDiagnosticsCount(_ c: ghostty_config_t?) -> UInt32 {
    UInt32(cfg(c)?.diagnosticCount ?? 0)
}

/// Diagnostic messages, interned for the life of the process (there are few).
private nonisolated(unsafe) var diagnosticStrings: [String: UnsafeMutablePointer<CChar>] = [:]
private let diagnosticLock = NSLock()

@_cdecl("ghostty_config_get_diagnostic")
public func rt_configGetDiagnostic(_ c: ghostty_config_t?, _ i: UInt32) -> ghostty_diagnostic_s {
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

@_cdecl("ghostty_app_new")
public func rt_appNew(_ runtime: UnsafePointer<ghostty_runtime_config_s>?, _ c: ghostty_config_t?) -> ghostty_app_t? {
    guard let runtime, let config = cfg(c) else { return nil }
    return Unmanaged.passRetained(App(runtime: runtime.pointee, config: config)).toOpaque()
}

@_cdecl("ghostty_app_free")
public func rt_appFree(_ a: ghostty_app_t?) {
    a.map { Unmanaged<App>.fromOpaque($0).release() }
}

@_cdecl("ghostty_app_tick")
public func rt_appTick(_ a: ghostty_app_t?) {
    // Actions are delivered as they happen; there is no mailbox to drain.
}

@_cdecl("ghostty_app_update_config")
public func rt_appUpdateConfig(_ a: ghostty_app_t?, _ c: ghostty_config_t?) {
    guard let app = App.from(a), let config = cfg(c) else { return }
    app.update(config: config)
}

@_cdecl("ghostty_app_set_surface_content_events_enabled")
public func rt_appSetContentEvents(_ a: ghostty_app_t?, _ enabled: Bool) {
    App.from(a)?.contentEventsEnabled = enabled
}

// MARK: Surface lifecycle

private func sfc(_ p: ghostty_surface_t?) -> Surface? {
    Surface.from(p)
}

@_cdecl("ghostty_surface_config_new")
public func rt_surfaceConfigNew() -> ghostty_surface_config_s {
    var c = ghostty_surface_config_s()
    c.platform_tag = GHOSTTY_PLATFORM_IOS
    c.scale_factor = 2
    c.initially_visible = true
    return c
}

@_cdecl("ghostty_surface_new")
public func rt_surfaceNew(_ a: ghostty_app_t?, _ c: UnsafePointer<ghostty_surface_config_s>?) -> ghostty_surface_t? {
    guard let app = App.from(a), let c else { return nil }
    let surface = Surface(app: app, config: c.pointee)
    return Unmanaged.passRetained(surface).toOpaque()
}

@_cdecl("ghostty_surface_free")
public func rt_surfaceFree(_ s: ghostty_surface_t?) {
    guard let s else { return }
    let surface = Unmanaged<Surface>.fromOpaque(s)
    surface.takeUnretainedValue().free()
    surface.release()
}

@_cdecl("ghostty_surface_userdata")
public func rt_surfaceUserdata(_ s: ghostty_surface_t?) -> UnsafeMutableRawPointer? {
    sfc(s)?.userdata
}

@_cdecl("ghostty_surface_update_config")
public func rt_surfaceUpdateConfig(_ s: ghostty_surface_t?, _ c: ghostty_config_t?) {
    guard let surface = sfc(s), let config = cfg(c) else { return }
    surface.update(config: config)
}

@_cdecl("ghostty_surface_get_slave_fd")
public func rt_surfaceSlaveFD(_ s: ghostty_surface_t?) -> Int32 {
    sfc(s)?.io?.inputFD ?? -1
}

@_cdecl("ghostty_surface_response_read_fd")
public func rt_surfaceResponseFD(_ s: ghostty_surface_t?) -> Int32 {
    sfc(s)?.io?.responseFD ?? -1
}

@_cdecl("ghostty_surface_request_close")
public func rt_surfaceRequestClose(_ s: ghostty_surface_t?) {
    guard let surface = sfc(s) else { return }
    surface.app.runtime.close_surface_cb?(surface.userdata, false)
}

// MARK: Rendering

@_cdecl("ghostty_surface_refresh")
public func rt_surfaceRefresh(_ s: ghostty_surface_t?) {
    sfc(s)?.renderer.setNeedsDisplay(force: true)
}

@_cdecl("ghostty_surface_draw")
public func rt_surfaceDraw(_ s: ghostty_surface_t?) {
    guard let surface = sfc(s) else { return }
    if Thread.isMainThread {
        surface.renderer.draw()
    } else {
        surface.renderer.setNeedsDisplay(force: true)
    }
}

@_cdecl("ghostty_surface_set_smooth_scroll_offset")
public func rt_surfaceSetSmoothScrollOffset(_ s: ghostty_surface_t?, _ px: Double) {
    sfc(s)?.renderer.setSmoothOffset(px)
}

@_cdecl("ghostty_surface_scroll_to_row_smooth")
public func rt_surfaceScrollToRowSmooth(_ s: ghostty_surface_t?, _ row: UInt, _ px: Double) {
    guard let surface = sfc(s) else { return }
    surface.session.mutate { $0.scrollViewport(toTopRow: Int(row)) }
    surface.renderer.setSmoothOffset(px)
}

@_cdecl("ghostty_surface_set_rubber_band_offset")
public func rt_surfaceSetRubberBand(_ s: ghostty_surface_t?, _ points: Double) {
    sfc(s)?.renderer.setRubberBand(points)
}

@_cdecl("ghostty_surface_set_frame_rate_range")
public func rt_surfaceSetFrameRateRange(_ s: ghostty_surface_t?, _ min: UInt16, _ max: UInt16, _ preferred: UInt16) {
    sfc(s)?.renderer.setFrameRateRange(min: Float(min), max: Float(max), preferred: Float(preferred))
}

@_cdecl("ghostty_surface_set_bottom_inset")
public func rt_surfaceSetBottomInset(_ s: ghostty_surface_t?, _ px: Double) {
    guard let surface = sfc(s), let grid = surface.renderer.setBottomInset(px) else { return }
    surface.resizeGrid(grid)
}

@_cdecl("ghostty_surface_set_content_scale")
public func rt_surfaceSetContentScale(_ s: ghostty_surface_t?, _ x: Double, _ y: Double) {
    sfc(s)?.renderer.setContentScale(x)
}

@_cdecl("ghostty_surface_set_focus")
public func rt_surfaceSetFocus(_ s: ghostty_surface_t?, _ focused: Bool) {
    guard let surface = sfc(s), surface.renderer.isFocused != focused else { return }
    surface.renderer.setFocused(focused)
    surface.sendInput(.focus(focused))
}

@_cdecl("ghostty_surface_set_occlusion")
public func rt_surfaceSetOcclusion(_ s: ghostty_surface_t?, _ visible: Bool) {
    sfc(s)?.renderer.setVisible(visible)
}

@_cdecl("ghostty_surface_drain_renderer_to_idle")
public func rt_surfaceDrainRenderer(_ s: ghostty_surface_t?, _ timeout: UInt64) -> Bool {
    sfc(s)?.renderer.drainToIdle(timeout: timeout) ?? true
}

@_cdecl("ghostty_surface_set_size")
public func rt_surfaceSetSize(_ s: ghostty_surface_t?, _ width: UInt32, _ height: UInt32) {
    sfc(s)?.setSize(width: width, height: height)
}

@_cdecl("ghostty_surface_size")
public func rt_surfaceSize(_ s: ghostty_surface_t?) -> ghostty_surface_size_s {
    sfc(s)?.size ?? ghostty_surface_size_s()
}

// MARK: Input

@_cdecl("ghostty_surface_key")
public func rt_surfaceKey(_ s: ghostty_surface_t?, _ event: ghostty_input_key_s) -> Bool {
    sfc(s)?.key(event) ?? false
}

@_cdecl("ghostty_surface_text")
public func rt_surfaceText(_ s: ghostty_surface_t?, _ ptr: UnsafePointer<CChar>?, _ len: UInt) {
    guard let surface = sfc(s), let ptr else { return }
    let text = String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(len)), as: UTF8.self)
    surface.sendText(text)
}

@_cdecl("ghostty_surface_send_input")
public func rt_surfaceSendInput(_ s: ghostty_surface_t?, _ ptr: UnsafePointer<CChar>?, _ len: UInt) {
    guard let surface = sfc(s), let ptr else { return }
    surface.sendRaw(Array(UnsafeRawBufferPointer(start: ptr, count: Int(len))))
}

@_cdecl("ghostty_surface_preedit")
public func rt_surfacePreedit(_ s: ghostty_surface_t?, _ ptr: UnsafePointer<CChar>?, _ len: UInt) {
    guard let surface = sfc(s) else { return }
    surface.renderer.preedit = ptr.flatMap { len > 0 ? String(decoding: UnsafeRawBufferPointer(start: $0, count: Int(len)), as: UTF8.self) : nil }
}

@_cdecl("ghostty_surface_ime_point")
public func rt_surfaceIMEPoint(
    _ s: ghostty_surface_t?, _ x: UnsafeMutablePointer<Double>?, _ y: UnsafeMutablePointer<Double>?,
    _ w: UnsafeMutablePointer<Double>?, _ h: UnsafeMutablePointer<Double>?,
) {
    guard let p = sfc(s)?.imePoint() else { return }
    x?.pointee = p.x
    y?.pointee = p.y
    w?.pointee = p.width
    h?.pointee = p.height
}

@_cdecl("ghostty_surface_mouse_captured")
public func rt_surfaceMouseCaptured(_ s: ghostty_surface_t?) -> Bool {
    sfc(s)?.mouseCaptured ?? false
}

@_cdecl("ghostty_surface_mouse_button")
public func rt_surfaceMouseButton(
    _ s: ghostty_surface_t?, _ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e,
    _ mods: ghostty_input_mods_e,
) -> Bool {
    sfc(s)?.mouseButton(state: state, button: button, mods: mods.rawValue) ?? false
}

@_cdecl("ghostty_surface_mouse_pos")
public func rt_surfaceMousePos(_ s: ghostty_surface_t?, _ x: Double, _ y: Double, _ mods: ghostty_input_mods_e) {
    sfc(s)?.mousePos(x: x, y: y, mods: mods.rawValue)
}

@_cdecl("ghostty_surface_mouse_scroll")
public func rt_surfaceMouseScroll(_ s: ghostty_surface_t?, _ dx: Double, _ dy: Double, _ mods: ghostty_input_scroll_mods_t) {
    sfc(s)?.mouseScroll(dx: dx, dy: dy, scrollMods: mods)
}

@_cdecl("ghostty_surface_binding_action")
public func rt_surfaceBindingAction(_ s: ghostty_surface_t?, _ ptr: UnsafePointer<CChar>?, _ len: UInt) -> Bool {
    guard let surface = sfc(s), let ptr else { return false }
    let action = String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(len)), as: UTF8.self)
    return surface.performBinding(action)
}

@_cdecl("ghostty_surface_complete_clipboard_request")
public func rt_surfaceCompleteClipboard(_ s: ghostty_surface_t?, _ text: UnsafePointer<CChar>?, _ state: UnsafeMutableRawPointer?, _ confirmed: Bool) {
    guard let surface = sfc(s) else { return }
    surface.completeClipboard(text.map { String(cString: $0) } ?? "", state: state, confirmed: confirmed)
}

@_cdecl("ghostty_surface_cursor_key_mode")
public func rt_surfaceCursorKeyMode(_ s: ghostty_surface_t?) -> Bool {
    sfc(s)?.mirror.modes.contains(.cursorKeys) ?? false
}

// MARK: Selection and text

@_cdecl("ghostty_surface_has_selection")
public func rt_surfaceHasSelection(_ s: ghostty_surface_t?) -> Bool {
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

@_cdecl("ghostty_surface_read_selection")
public func rt_surfaceReadSelection(_ s: ghostty_surface_t?, _ out: UnsafeMutablePointer<ghostty_text_s>?) -> Bool {
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

@_cdecl("ghostty_surface_read_text")
public func rt_surfaceReadText(_ s: ghostty_surface_t?, _ selection: ghostty_selection_s, _ out: UnsafeMutablePointer<ghostty_text_s>?) -> Bool {
    guard let surface = sfc(s), let out, let text = surface.readText(selection) else { return false }
    out.pointee = ghostty_text_s()
    fill(out, text: text)
    return true
}

@_cdecl("ghostty_surface_free_text")
public func rt_surfaceFreeText(_ s: ghostty_surface_t?, _ text: UnsafeMutablePointer<ghostty_text_s>?) {
    guard let text, let p = text.pointee.text else { return }
    UnsafeMutablePointer(mutating: p).deallocate()
    text.pointee.text = nil
    text.pointee.text_len = 0
}

@_cdecl("ghostty_surface_selection_handle_drag_begin")
public func rt_surfaceHandleDragBegin(_ s: ghostty_surface_t?, _ draggingStart: Bool) -> Bool {
    sfc(s)?.beginHandleDrag(draggingStart: draggingStart) ?? false
}

@_cdecl("ghostty_surface_selection_viewport_visibility")
public func rt_surfaceSelectionVisibility(_ s: ghostty_surface_t?, _ start: UnsafeMutablePointer<Bool>?, _ end: UnsafeMutablePointer<Bool>?) -> Bool {
    guard let mirror = sfc(s)?.mirror, mirror.hasSelection else { return false }
    start?.pointee = mirror.selectionVisible.start
    end?.pointee = mirror.selectionVisible.end
    return true
}

@_cdecl("ghostty_surface_display_scrollbar")
public func rt_surfaceDisplayScrollbar(_ s: ghostty_surface_t?, _ out: UnsafeMutablePointer<ghostty_action_scrollbar_s>?) -> Bool {
    guard let bar = sfc(s)?.mirror.scrollbar, bar.total > bar.len else { return false }
    out?.pointee = ghostty_action_scrollbar_s(total: UInt64(bar.total), offset: UInt64(bar.offset), len: UInt64(bar.len))
    return true
}

@_cdecl("ghostty_surface_is_alternate_active")
public func rt_surfaceIsAlternateActive(_ s: ghostty_surface_t?) -> Bool {
    sfc(s)?.mirror.isAlternate ?? false
}

@_cdecl("ghostty_surface_dump_primary_screen")
public func rt_surfaceDumpPrimary(_ s: ghostty_surface_t?, _ len: UnsafeMutablePointer<UInt>?) -> UnsafePointer<CChar>? {
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

@_cdecl("ghostty_surface_free_dump")
public func rt_surfaceFreeDump(_ ptr: UnsafePointer<CChar>?, _ len: UInt) {
    ptr.map { UnsafeMutablePointer(mutating: $0).deallocate() }
}

// MARK: tmux

private func viewer(_ s: ghostty_surface_t?) -> TmuxViewer? {
    sfc(s)?.tmux
}

@_cdecl("ghostty_surface_new_tmux_pane")
public func rt_surfaceNewTmuxPane(
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

@_cdecl("ghostty_surface_tmux_active")
public func rt_tmuxActive(_ s: ghostty_surface_t?) -> Bool {
    viewer(s)?.isActive ?? false
}

@_cdecl("ghostty_surface_tmux_command")
public func rt_tmuxCommand(_ s: ghostty_surface_t?, _ ptr: UnsafePointer<CChar>?, _ len: UInt) {
    guard let ptr else { return }
    viewer(s)?.command(String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(len)), as: UTF8.self), tag: nil)
}

@_cdecl("ghostty_surface_tmux_command_with_reply")
public func rt_tmuxCommandWithReply(_ s: ghostty_surface_t?, _ ptr: UnsafePointer<CChar>?, _ len: UInt, _ tag: UInt32) {
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

@_cdecl("ghostty_surface_tmux_set_client_size")
public func rt_tmuxSetClientSize(_ s: ghostty_surface_t?, _ columns: UInt16, _ rows: UInt16) {
    viewer(s)?.setClientSize(columns: Int(columns), rows: Int(rows))
}

@_cdecl("ghostty_surface_tmux_detach")
public func rt_tmuxDetach(_ s: ghostty_surface_t?) {
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

@_cdecl("ghostty_surface_tmux_resume")
public func rt_tmuxResume(_ s: ghostty_surface_t?) {
    resume(s, priority: nil)
}

@_cdecl("ghostty_surface_tmux_resume_prioritized")
public func rt_tmuxResumePrioritized(_ s: ghostty_surface_t?, _ window: UInt) {
    resume(s, priority: Int(window))
}

@_cdecl("ghostty_surface_tmux_resume_abort")
public func rt_tmuxResumeAbort(_ s: ghostty_surface_t?) {
    viewer(s)?.forceExit()
}

@_cdecl("ghostty_surface_tmux_force_exit")
public func rt_tmuxForceExit(_ s: ghostty_surface_t?) {
    viewer(s)?.forceExit()
}

@_cdecl("ghostty_surface_tmux_recover")
public func rt_tmuxRecover(_ s: ghostty_surface_t?) {
    viewer(s)?.recover()
}

@_cdecl("ghostty_surface_tmux_reset")
public func rt_tmuxReset(_ s: ghostty_surface_t?) {
    viewer(s)?.resetPanes(priority: nil)
}

@_cdecl("ghostty_surface_tmux_reset_prioritized")
public func rt_tmuxResetPrioritized(_ s: ghostty_surface_t?, _ window: UInt) {
    viewer(s)?.resetPanes(priority: Int(window))
}

@_cdecl("ghostty_surface_tmux_reprobe")
public func rt_tmuxReprobe(_ s: ghostty_surface_t?) {
    viewer(s)?.reprobe()
}

@_cdecl("ghostty_surface_tmux_flush_deferred")
public func rt_tmuxFlushDeferred(_ s: ghostty_surface_t?) {
    viewer(s)?.flushDeferred()
}

@_cdecl("ghostty_surface_tmux_debug_snapshot")
public func rt_tmuxDebugSnapshot(_ s: ghostty_surface_t?, _ out: UnsafeMutablePointer<ghostty_tmux_debug_snapshot_s>?) -> Bool {
    guard let viewer = viewer(s), let out else { return false }
    viewer.debugSnapshot(&out.pointee)
    return true
}
