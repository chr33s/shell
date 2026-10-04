import Foundation
import GhosttyKit
import os

/// `ghostty_app_t`: the host's runtime callbacks plus the shared config.
///
/// Actions are delivered from whichever thread produced them, as in
/// libghostty: surface events are produced on a serial action queue (never
/// the terminal queue, so a handler may call back into its surface), and
/// events that answer a host call on the main thread (cell size, link hover)
/// are delivered inline before that call returns.
final class App: @unchecked Sendable {
    let runtime: ghostty_runtime_config_s
    private let lock = OSAllocatedUnfairLock()
    private var _config: Config
    private var surfaces = NSHashTable<Surface>.weakObjects()
    private var _contentEventsEnabled = false

    /// Serial queue for actions raised by terminal activity.
    let actionQueue = DispatchQueue(label: "ghostty.runtime.actions", qos: .userInitiated)

    init(runtime: ghostty_runtime_config_s, config: Config) {
        self.runtime = runtime
        _config = config
    }

    var opaque: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    static func from(_ p: UnsafeMutableRawPointer?) -> App? {
        p.map { Unmanaged<App>.fromOpaque($0).takeUnretainedValue() }
    }

    var config: Config {
        lock.withLockUnchecked { _config }
    }

    var contentEventsEnabled: Bool {
        get { lock.withLockUnchecked { _contentEventsEnabled } }
        set { lock.withLockUnchecked { _contentEventsEnabled = newValue } }
    }

    func register(_ surface: Surface) {
        lock.withLockUnchecked { surfaces.add(surface) }
    }

    func unregister(_ surface: Surface) {
        lock.withLockUnchecked { surfaces.remove(surface) }
    }

    /// Stores the config new surfaces inherit and pushes it to every surface.
    func update(config: Config) {
        let live = lock.withLockUnchecked {
            _config = config
            return surfaces.allObjects
        }
        for surface in live {
            surface.update(config: config)
        }
    }

    // MARK: Actions

    /// Delivers `action` for `surface` (nil: the app) synchronously.
    @discardableResult
    func perform(_ action: ghostty_action_s, surface: Surface?) -> Bool {
        guard let cb = runtime.action_cb else { return false }
        var target = ghostty_target_s()
        if let surface {
            target.tag = GHOSTTY_TARGET_SURFACE
            target.target.surface = surface.opaque
        } else {
            target.tag = GHOSTTY_TARGET_APP
        }
        return cb(opaque, target, action)
    }

    /// Delivers on the action queue, preserving order per app. `build`
    /// calls `send` with the action while any borrowed payload is valid.
    func post(_ surface: Surface, _ build: @escaping @Sendable (_ send: (ghostty_action_s) -> Void) -> Void) {
        actionQueue.async { [self] in
            guard !surface.isFreed else { return }
            build { self.perform($0, surface: surface) }
        }
    }

    /// Simple payload-free or POD actions.
    func post(_ surface: Surface, tag: ghostty_action_tag_e, _ fill: @escaping @Sendable (inout ghostty_action_u) -> Void = { _ in }) {
        post(surface) { send in
            var action = ghostty_action_s()
            action.tag = tag
            fill(&action.action)
            send(action)
        }
    }

    /// Posts an action carrying one C string (title, pwd, ...).
    func post(_ surface: Surface, tag: ghostty_action_tag_e, string: String, _ fill: @escaping @Sendable (inout ghostty_action_u, UnsafePointer<CChar>) -> Void) {
        post(surface) { send in
            string.withCString { ptr in
                var action = ghostty_action_s()
                action.tag = tag
                fill(&action.action, ptr)
                send(action)
            }
        }
    }

    // MARK: Clipboard

    func writeClipboard(_ surface: Surface, text: String, confirm: Bool = false) {
        guard let cb = runtime.write_clipboard_cb else { return }
        "text/plain".withCString { mime in
            text.withCString { data in
                var content = ghostty_clipboard_content_s(mime: mime, data: data)
                cb(surface.userdata, GHOSTTY_CLIPBOARD_STANDARD, &content, 1, confirm)
            }
        }
    }

    /// Asks the host for clipboard text; it answers through
    /// `ghostty_surface_complete_clipboard_request` with `state`.
    func readClipboard(_ surface: Surface, state: UnsafeMutableRawPointer) -> Bool {
        guard let cb = runtime.read_clipboard_cb else { return false }
        return cb(surface.userdata, GHOSTTY_CLIPBOARD_STANDARD, state)
    }
}

let logger = Logger(subsystem: "dev.chr33s.shell", category: "ghostty-runtime")
