// Swift definitions of the SwifttyKit embedder API types Shell uses.
// Shapes and constant values derive from Ghostty's embedder header (MIT,
// Mitchell Hashimoto; see THIRD_PARTY_NOTICES.md); there is no C ABI.
// Generated once from that header; edit by hand from here on.

// swiftlint:disable identifier_name type_name file_length

public typealias swiftty_app_t = UnsafeMutableRawPointer
public typealias swiftty_config_t = UnsafeMutableRawPointer
public typealias swiftty_surface_t = UnsafeMutableRawPointer
public typealias swiftty_input_scroll_mods_t = Int32


public struct swiftty_action_mouse_shape_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public let SWIFTTY_MOUSE_SHAPE_DEFAULT = swiftty_action_mouse_shape_e(0)
public let SWIFTTY_MOUSE_SHAPE_CONTEXT_MENU = swiftty_action_mouse_shape_e(1)
public let SWIFTTY_MOUSE_SHAPE_POINTER = swiftty_action_mouse_shape_e(3)
public let SWIFTTY_MOUSE_SHAPE_CROSSHAIR = swiftty_action_mouse_shape_e(7)
public let SWIFTTY_MOUSE_SHAPE_TEXT = swiftty_action_mouse_shape_e(8)
public let SWIFTTY_MOUSE_SHAPE_VERTICAL_TEXT = swiftty_action_mouse_shape_e(9)
public let SWIFTTY_MOUSE_SHAPE_NOT_ALLOWED = swiftty_action_mouse_shape_e(14)
public let SWIFTTY_MOUSE_SHAPE_GRAB = swiftty_action_mouse_shape_e(15)
public let SWIFTTY_MOUSE_SHAPE_GRABBING = swiftty_action_mouse_shape_e(16)
public let SWIFTTY_MOUSE_SHAPE_N_RESIZE = swiftty_action_mouse_shape_e(20)
public let SWIFTTY_MOUSE_SHAPE_E_RESIZE = swiftty_action_mouse_shape_e(21)
public let SWIFTTY_MOUSE_SHAPE_S_RESIZE = swiftty_action_mouse_shape_e(22)
public let SWIFTTY_MOUSE_SHAPE_W_RESIZE = swiftty_action_mouse_shape_e(23)
public let SWIFTTY_MOUSE_SHAPE_EW_RESIZE = swiftty_action_mouse_shape_e(28)
public let SWIFTTY_MOUSE_SHAPE_NS_RESIZE = swiftty_action_mouse_shape_e(29)

public struct swiftty_action_mouse_visibility_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public let SWIFTTY_MOUSE_VISIBLE = swiftty_action_mouse_visibility_e(0)

public struct swiftty_action_open_url_kind_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public let SWIFTTY_ACTION_OPEN_URL_KIND_TEXT = swiftty_action_open_url_kind_e(1)

public struct swiftty_action_progress_report_state_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public let SWIFTTY_PROGRESS_STATE_REMOVE = swiftty_action_progress_report_state_e(0)
public let SWIFTTY_PROGRESS_STATE_SET = swiftty_action_progress_report_state_e(1)
public let SWIFTTY_PROGRESS_STATE_ERROR = swiftty_action_progress_report_state_e(2)
public let SWIFTTY_PROGRESS_STATE_INDETERMINATE = swiftty_action_progress_report_state_e(3)
public let SWIFTTY_PROGRESS_STATE_PAUSE = swiftty_action_progress_report_state_e(4)

public struct swiftty_action_tag_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public let SWIFTTY_ACTION_CELL_SIZE = swiftty_action_tag_e(25)
public let SWIFTTY_ACTION_SCROLLBAR = swiftty_action_tag_e(26)
public let SWIFTTY_ACTION_DESKTOP_NOTIFICATION = swiftty_action_tag_e(32)
public let SWIFTTY_ACTION_SET_TITLE = swiftty_action_tag_e(33)
public let SWIFTTY_ACTION_PWD = swiftty_action_tag_e(37)
public let SWIFTTY_ACTION_MOUSE_SHAPE = swiftty_action_tag_e(38)
public let SWIFTTY_ACTION_MOUSE_VISIBILITY = swiftty_action_tag_e(39)
public let SWIFTTY_ACTION_MOUSE_OVER_LINK = swiftty_action_tag_e(40)
public let SWIFTTY_ACTION_RING_BELL = swiftty_action_tag_e(52)
public let SWIFTTY_ACTION_OPEN_URL = swiftty_action_tag_e(57)
public let SWIFTTY_ACTION_PROGRESS_REPORT = swiftty_action_tag_e(59)
public let SWIFTTY_ACTION_START_SEARCH = swiftty_action_tag_e(62)
public let SWIFTTY_ACTION_END_SEARCH = swiftty_action_tag_e(63)
public let SWIFTTY_ACTION_SEARCH_TOTAL = swiftty_action_tag_e(64)
public let SWIFTTY_ACTION_SEARCH_SELECTED = swiftty_action_tag_e(65)
public let SWIFTTY_ACTION_TMUX_RECONCILE = swiftty_action_tag_e(69)
public let SWIFTTY_ACTION_TMUX_SESSIONS_CHANGED = swiftty_action_tag_e(70)
public let SWIFTTY_ACTION_TMUX_SESSION_CHANGED = swiftty_action_tag_e(71)
public let SWIFTTY_ACTION_TMUX_COMMAND_RESPONSE = swiftty_action_tag_e(72)
public let SWIFTTY_ACTION_SURFACE_CONTENT_CHANGED = swiftty_action_tag_e(73)
public let SWIFTTY_ACTION_PTY_RESIZE = swiftty_action_tag_e(74)
/// A tmux pane's captured content was applied (visible-pane sync).
public let SWIFTTY_ACTION_TMUX_PANE_SYNCED = swiftty_action_tag_e(75)

public struct swiftty_clipboard_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public let SWIFTTY_CLIPBOARD_STANDARD = swiftty_clipboard_e(0)
public let SWIFTTY_CLIPBOARD_SELECTION = swiftty_clipboard_e(1)

public struct swiftty_clipboard_request_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public struct swiftty_input_action_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public let SWIFTTY_ACTION_RELEASE = swiftty_input_action_e(0)
public let SWIFTTY_ACTION_PRESS = swiftty_input_action_e(1)
public let SWIFTTY_ACTION_REPEAT = swiftty_input_action_e(2)

public struct swiftty_input_key_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public struct swiftty_input_mods_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public let SWIFTTY_MODS_NONE = swiftty_input_mods_e(0)
public let SWIFTTY_MODS_SHIFT = swiftty_input_mods_e(1)
public let SWIFTTY_MODS_CTRL = swiftty_input_mods_e(2)
public let SWIFTTY_MODS_ALT = swiftty_input_mods_e(4)
public let SWIFTTY_MODS_SUPER = swiftty_input_mods_e(8)
public let SWIFTTY_MODS_CAPS = swiftty_input_mods_e(16)
public let SWIFTTY_MODS_SHIFT_RIGHT = swiftty_input_mods_e(64)
public let SWIFTTY_MODS_CTRL_RIGHT = swiftty_input_mods_e(128)
public let SWIFTTY_MODS_ALT_RIGHT = swiftty_input_mods_e(256)
public let SWIFTTY_MODS_SUPER_RIGHT = swiftty_input_mods_e(512)

public struct swiftty_input_mouse_button_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public let SWIFTTY_MOUSE_UNKNOWN = swiftty_input_mouse_button_e(0)
public let SWIFTTY_MOUSE_LEFT = swiftty_input_mouse_button_e(1)
public let SWIFTTY_MOUSE_RIGHT = swiftty_input_mouse_button_e(2)
public let SWIFTTY_MOUSE_MIDDLE = swiftty_input_mouse_button_e(3)

public struct swiftty_input_mouse_state_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public let SWIFTTY_MOUSE_RELEASE = swiftty_input_mouse_state_e(0)
public let SWIFTTY_MOUSE_PRESS = swiftty_input_mouse_state_e(1)

public struct swiftty_platform_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public let SWIFTTY_PLATFORM_IOS = swiftty_platform_e(2)

public struct swiftty_point_coord_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public let SWIFTTY_POINT_COORD_EXACT = swiftty_point_coord_e(0)

public struct swiftty_point_tag_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public let SWIFTTY_POINT_VIEWPORT = swiftty_point_tag_e(1)
public let SWIFTTY_POINT_SCREEN = swiftty_point_tag_e(2)

public struct swiftty_surface_context_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public struct swiftty_target_tag_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public let SWIFTTY_TARGET_APP = swiftty_target_tag_e(0)
public let SWIFTTY_TARGET_SURFACE = swiftty_target_tag_e(1)

public struct swiftty_tmux_layout_kind_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public let SWIFTTY_TMUX_LAYOUT_PANE = swiftty_tmux_layout_kind_e(0)
public let SWIFTTY_TMUX_LAYOUT_HORIZONTAL = swiftty_tmux_layout_kind_e(1)
public let SWIFTTY_TMUX_LAYOUT_VERTICAL = swiftty_tmux_layout_kind_e(2)

public struct swiftty_tmux_op_tag_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public let SWIFTTY_TMUX_OP_SYNC_BEGIN = swiftty_tmux_op_tag_e(0)
public let SWIFTTY_TMUX_OP_ENSURE_WINDOW = swiftty_tmux_op_tag_e(1)
public let SWIFTTY_TMUX_OP_ENSURE_PANE = swiftty_tmux_op_tag_e(2)
public let SWIFTTY_TMUX_OP_SET_LAYOUT = swiftty_tmux_op_tag_e(3)
public let SWIFTTY_TMUX_OP_SET_FOCUS = swiftty_tmux_op_tag_e(4)
public let SWIFTTY_TMUX_OP_PRUNE_ABSENT = swiftty_tmux_op_tag_e(5)
public let SWIFTTY_TMUX_OP_SYNC_END = swiftty_tmux_op_tag_e(6)
public let SWIFTTY_TMUX_OP_SET_TAB_TITLE = swiftty_tmux_op_tag_e(7)
public let SWIFTTY_TMUX_OP_SET_WINDOW_TITLE = swiftty_tmux_op_tag_e(8)

public struct swiftty_action_cell_size_s: @unchecked Sendable {
    public var width: UInt32 = 0
    public var height: UInt32 = 0

    public init(width: UInt32 = 0, height: UInt32 = 0) {
        self.width = width
        self.height = height
    }
}

public struct swiftty_action_desktop_notification_s: @unchecked Sendable {
    public var title: UnsafePointer<CChar>! = nil
    public var body: UnsafePointer<CChar>! = nil

    public init(title: UnsafePointer<CChar>! = nil, body: UnsafePointer<CChar>! = nil) {
        self.title = title
        self.body = body
    }
}

public struct swiftty_action_mouse_over_link_s: @unchecked Sendable {
    public var url: UnsafePointer<CChar>! = nil
    public var len: Int = 0

    public init(url: UnsafePointer<CChar>! = nil, len: Int = 0) {
        self.url = url
        self.len = len
    }
}

public struct swiftty_action_open_url_s: @unchecked Sendable {
    public var kind: swiftty_action_open_url_kind_e = swiftty_action_open_url_kind_e(0)
    public var url: UnsafePointer<CChar>! = nil
    public var len: UInt = 0

    public init(kind: swiftty_action_open_url_kind_e = swiftty_action_open_url_kind_e(0), url: UnsafePointer<CChar>! = nil, len: UInt = 0) {
        self.kind = kind
        self.url = url
        self.len = len
    }
}

public struct swiftty_action_progress_report_s: @unchecked Sendable {
    public var state: swiftty_action_progress_report_state_e = swiftty_action_progress_report_state_e(0)
    public var progress: Int8 = 0

    public init(state: swiftty_action_progress_report_state_e = swiftty_action_progress_report_state_e(0), progress: Int8 = 0) {
        self.state = state
        self.progress = progress
    }
}

public struct swiftty_action_pty_resize_s: @unchecked Sendable {
    public var rows: UInt32 = 0
    public var cols: UInt32 = 0
    public var width_px: UInt32 = 0
    public var height_px: UInt32 = 0

    public init(rows: UInt32 = 0, cols: UInt32 = 0, width_px: UInt32 = 0, height_px: UInt32 = 0) {
        self.rows = rows
        self.cols = cols
        self.width_px = width_px
        self.height_px = height_px
    }
}

public struct swiftty_action_pwd_s: @unchecked Sendable {
    public var pwd: UnsafePointer<CChar>! = nil

    public init(pwd: UnsafePointer<CChar>! = nil) {
        self.pwd = pwd
    }
}

public struct swiftty_action_s: @unchecked Sendable {
    public var tag: swiftty_action_tag_e = swiftty_action_tag_e(0)
    public var action: swiftty_action_u = swiftty_action_u()

    public init(tag: swiftty_action_tag_e = swiftty_action_tag_e(0), action: swiftty_action_u = swiftty_action_u()) {
        self.tag = tag
        self.action = action
    }
}

public struct swiftty_action_scrollbar_s: @unchecked Sendable {
    public var total: UInt64 = 0
    public var offset: UInt64 = 0
    public var len: UInt64 = 0

    public init(total: UInt64 = 0, offset: UInt64 = 0, len: UInt64 = 0) {
        self.total = total
        self.offset = offset
        self.len = len
    }
}

public struct swiftty_action_search_selected_s: @unchecked Sendable {
    public var selected: Int = 0

    public init(selected: Int = 0) {
        self.selected = selected
    }
}

public struct swiftty_action_search_total_s: @unchecked Sendable {
    public var total: Int = 0

    public init(total: Int = 0) {
        self.total = total
    }
}

public struct swiftty_action_set_title_s: @unchecked Sendable {
    public var title: UnsafePointer<CChar>! = nil

    public init(title: UnsafePointer<CChar>! = nil) {
        self.title = title
    }
}

public struct swiftty_action_start_search_s: @unchecked Sendable {
    public var needle: UnsafePointer<CChar>! = nil

    public init(needle: UnsafePointer<CChar>! = nil) {
        self.needle = needle
    }
}

public struct swiftty_action_tmux_command_response_s: @unchecked Sendable {
    public var tag: UInt32 = 0
    public var is_err: Bool = false
    public var body: UnsafePointer<UInt8>! = nil
    public var body_len: UInt = 0

    public init(tag: UInt32 = 0, is_err: Bool = false, body: UnsafePointer<UInt8>! = nil, body_len: UInt = 0) {
        self.tag = tag
        self.is_err = is_err
        self.body = body
        self.body_len = body_len
    }
}

public struct swiftty_action_tmux_session_changed_s: @unchecked Sendable {
    public var session_id: UInt64 = 0
    public var name: UnsafePointer<UInt8>! = nil
    public var name_len: UInt = 0
    /// The viewer generation (one per control-mode stream).
    public var generation: UInt64 = 0

    public init(session_id: UInt64 = 0, name: UnsafePointer<UInt8>! = nil, name_len: UInt = 0, generation: UInt64 = 0) {
        self.session_id = session_id
        self.name = name
        self.name_len = name_len
        self.generation = generation
    }
}

public struct swiftty_action_tmux_pane_synced_s: @unchecked Sendable {
    public var pane_id: UInt64 = 0
    /// The viewer generation the capture belongs to.
    public var generation: UInt64 = 0

    public init(pane_id: UInt64 = 0, generation: UInt64 = 0) {
        self.pane_id = pane_id
        self.generation = generation
    }
}

/// A C union in Swiftty; here each member has its own storage.
public struct swiftty_action_u: @unchecked Sendable {
    public var cell_size: swiftty_action_cell_size_s = swiftty_action_cell_size_s()
    public var pty_resize: swiftty_action_pty_resize_s = swiftty_action_pty_resize_s()
    public var scrollbar: swiftty_action_scrollbar_s = swiftty_action_scrollbar_s()
    public var desktop_notification: swiftty_action_desktop_notification_s = swiftty_action_desktop_notification_s()
    public var set_title: swiftty_action_set_title_s = swiftty_action_set_title_s()
    public var pwd: swiftty_action_pwd_s = swiftty_action_pwd_s()
    public var mouse_shape: swiftty_action_mouse_shape_e = swiftty_action_mouse_shape_e(0)
    public var mouse_visibility: swiftty_action_mouse_visibility_e = swiftty_action_mouse_visibility_e(0)
    public var mouse_over_link: swiftty_action_mouse_over_link_s = swiftty_action_mouse_over_link_s()
    public var open_url: swiftty_action_open_url_s = swiftty_action_open_url_s()
    public var progress_report: swiftty_action_progress_report_s = swiftty_action_progress_report_s()
    public var start_search: swiftty_action_start_search_s = swiftty_action_start_search_s()
    public var search_total: swiftty_action_search_total_s = swiftty_action_search_total_s()
    public var search_selected: swiftty_action_search_selected_s = swiftty_action_search_selected_s()
    public var tmux_reconcile: UnsafeMutableRawPointer! = nil
    public var tmux_session_changed: swiftty_action_tmux_session_changed_s = swiftty_action_tmux_session_changed_s()
    public var tmux_command_response: swiftty_action_tmux_command_response_s = swiftty_action_tmux_command_response_s()
    public var tmux_pane_synced: swiftty_action_tmux_pane_synced_s = swiftty_action_tmux_pane_synced_s()

    public init(cell_size: swiftty_action_cell_size_s = swiftty_action_cell_size_s(), pty_resize: swiftty_action_pty_resize_s = swiftty_action_pty_resize_s(), scrollbar: swiftty_action_scrollbar_s = swiftty_action_scrollbar_s(), desktop_notification: swiftty_action_desktop_notification_s = swiftty_action_desktop_notification_s(), set_title: swiftty_action_set_title_s = swiftty_action_set_title_s(), pwd: swiftty_action_pwd_s = swiftty_action_pwd_s(), mouse_shape: swiftty_action_mouse_shape_e = swiftty_action_mouse_shape_e(0), mouse_visibility: swiftty_action_mouse_visibility_e = swiftty_action_mouse_visibility_e(0), mouse_over_link: swiftty_action_mouse_over_link_s = swiftty_action_mouse_over_link_s(), open_url: swiftty_action_open_url_s = swiftty_action_open_url_s(), progress_report: swiftty_action_progress_report_s = swiftty_action_progress_report_s(), start_search: swiftty_action_start_search_s = swiftty_action_start_search_s(), search_total: swiftty_action_search_total_s = swiftty_action_search_total_s(), search_selected: swiftty_action_search_selected_s = swiftty_action_search_selected_s(), tmux_reconcile: UnsafeMutableRawPointer! = nil, tmux_session_changed: swiftty_action_tmux_session_changed_s = swiftty_action_tmux_session_changed_s(), tmux_command_response: swiftty_action_tmux_command_response_s = swiftty_action_tmux_command_response_s()) {
        self.cell_size = cell_size
        self.pty_resize = pty_resize
        self.scrollbar = scrollbar
        self.desktop_notification = desktop_notification
        self.set_title = set_title
        self.pwd = pwd
        self.mouse_shape = mouse_shape
        self.mouse_visibility = mouse_visibility
        self.mouse_over_link = mouse_over_link
        self.open_url = open_url
        self.progress_report = progress_report
        self.start_search = start_search
        self.search_total = search_total
        self.search_selected = search_selected
        self.tmux_reconcile = tmux_reconcile
        self.tmux_session_changed = tmux_session_changed
        self.tmux_command_response = tmux_command_response
    }
}

public struct swiftty_clipboard_content_s: @unchecked Sendable {
    public var mime: UnsafePointer<CChar>! = nil
    public var data: UnsafePointer<CChar>! = nil

    public init(mime: UnsafePointer<CChar>! = nil, data: UnsafePointer<CChar>! = nil) {
        self.mime = mime
        self.data = data
    }
}

public struct swiftty_diagnostic_s: @unchecked Sendable {
    public var message: UnsafePointer<CChar>! = nil

    public init(message: UnsafePointer<CChar>! = nil) {
        self.message = message
    }
}

public struct swiftty_env_var_s: @unchecked Sendable {
    public var key: UnsafePointer<CChar>! = nil
    public var value: UnsafePointer<CChar>! = nil

    public init(key: UnsafePointer<CChar>! = nil, value: UnsafePointer<CChar>! = nil) {
        self.key = key
        self.value = value
    }
}

public struct swiftty_input_key_s: @unchecked Sendable {
    public var action: swiftty_input_action_e = swiftty_input_action_e(0)
    public var mods: swiftty_input_mods_e = swiftty_input_mods_e(0)
    public var consumed_mods: swiftty_input_mods_e = swiftty_input_mods_e(0)
    public var keycode: UInt32 = 0
    public var text: UnsafePointer<CChar>! = nil
    public var unshifted_codepoint: UInt32 = 0
    public var composing: Bool = false

    public init(action: swiftty_input_action_e = swiftty_input_action_e(0), mods: swiftty_input_mods_e = swiftty_input_mods_e(0), consumed_mods: swiftty_input_mods_e = swiftty_input_mods_e(0), keycode: UInt32 = 0, text: UnsafePointer<CChar>! = nil, unshifted_codepoint: UInt32 = 0, composing: Bool = false) {
        self.action = action
        self.mods = mods
        self.consumed_mods = consumed_mods
        self.keycode = keycode
        self.text = text
        self.unshifted_codepoint = unshifted_codepoint
        self.composing = composing
    }
}

public struct swiftty_platform_ios_s: @unchecked Sendable {
    public var uiview: UnsafeMutableRawPointer! = nil

    public init(uiview: UnsafeMutableRawPointer! = nil) {
        self.uiview = uiview
    }
}

/// A C union in Swiftty; here each member has its own storage.
public struct swiftty_platform_u: @unchecked Sendable {
    public var ios: swiftty_platform_ios_s = swiftty_platform_ios_s()

    public init(ios: swiftty_platform_ios_s = swiftty_platform_ios_s()) {
        self.ios = ios
    }
}

public struct swiftty_point_s: @unchecked Sendable {
    public var tag: swiftty_point_tag_e = swiftty_point_tag_e(0)
    public var coord: swiftty_point_coord_e = swiftty_point_coord_e(0)
    public var x: UInt32 = 0
    public var y: UInt32 = 0

    public init(tag: swiftty_point_tag_e = swiftty_point_tag_e(0), coord: swiftty_point_coord_e = swiftty_point_coord_e(0), x: UInt32 = 0, y: UInt32 = 0) {
        self.tag = tag
        self.coord = coord
        self.x = x
        self.y = y
    }
}

public struct swiftty_runtime_config_s: @unchecked Sendable {
    public var userdata: UnsafeMutableRawPointer! = nil
    public var supports_selection_clipboard: Bool = false
    public var action_cb: ((swiftty_app_t?, swiftty_target_s, swiftty_action_s) -> Bool)? = nil
    public var read_clipboard_cb: ((UnsafeMutableRawPointer?, swiftty_clipboard_e, UnsafeMutableRawPointer?) -> Bool)? = nil
    public var confirm_read_clipboard_cb: ((UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?, swiftty_clipboard_request_e) -> Void)? = nil
    public var write_clipboard_cb: ((UnsafeMutableRawPointer?, swiftty_clipboard_e, UnsafePointer<swiftty_clipboard_content_s>?, Int, Bool) -> Void)? = nil
    public var close_surface_cb: ((UnsafeMutableRawPointer?, Bool) -> Void)? = nil

    public init(userdata: UnsafeMutableRawPointer! = nil, supports_selection_clipboard: Bool = false, action_cb: ((swiftty_app_t?, swiftty_target_s, swiftty_action_s) -> Bool)? = nil, read_clipboard_cb: ((UnsafeMutableRawPointer?, swiftty_clipboard_e, UnsafeMutableRawPointer?) -> Bool)? = nil, confirm_read_clipboard_cb: ((UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?, swiftty_clipboard_request_e) -> Void)? = nil, write_clipboard_cb: ((UnsafeMutableRawPointer?, swiftty_clipboard_e, UnsafePointer<swiftty_clipboard_content_s>?, Int, Bool) -> Void)? = nil, close_surface_cb: ((UnsafeMutableRawPointer?, Bool) -> Void)? = nil) {
        self.userdata = userdata
        self.supports_selection_clipboard = supports_selection_clipboard
        self.action_cb = action_cb
        self.read_clipboard_cb = read_clipboard_cb
        self.confirm_read_clipboard_cb = confirm_read_clipboard_cb
        self.write_clipboard_cb = write_clipboard_cb
        self.close_surface_cb = close_surface_cb
    }
}

public struct swiftty_selection_s: @unchecked Sendable {
    public var top_left: swiftty_point_s = swiftty_point_s()
    public var bottom_right: swiftty_point_s = swiftty_point_s()
    public var rectangle: Bool = false

    public init(top_left: swiftty_point_s = swiftty_point_s(), bottom_right: swiftty_point_s = swiftty_point_s(), rectangle: Bool = false) {
        self.top_left = top_left
        self.bottom_right = bottom_right
        self.rectangle = rectangle
    }
}

public struct swiftty_surface_config_s: @unchecked Sendable {
    public var platform_tag: swiftty_platform_e = swiftty_platform_e(0)
    public var platform: swiftty_platform_u = swiftty_platform_u()
    public var userdata: UnsafeMutableRawPointer! = nil
    public var scale_factor: Double = 0
    public var font_size: Float = 0
    public var working_directory: UnsafePointer<CChar>! = nil
    public var command: UnsafePointer<CChar>! = nil
    public var env_vars: UnsafeMutablePointer<swiftty_env_var_s>! = nil
    public var env_var_count: Int = 0
    public var initial_input: UnsafePointer<CChar>! = nil
    public var wait_after_command: Bool = false
    public var use_external_io: Bool = false
    public var initially_visible: Bool = false
    public var context: swiftty_surface_context_e = swiftty_surface_context_e(0)

    public init(platform_tag: swiftty_platform_e = swiftty_platform_e(0), platform: swiftty_platform_u = swiftty_platform_u(), userdata: UnsafeMutableRawPointer! = nil, scale_factor: Double = 0, font_size: Float = 0, working_directory: UnsafePointer<CChar>! = nil, command: UnsafePointer<CChar>! = nil, env_vars: UnsafeMutablePointer<swiftty_env_var_s>! = nil, env_var_count: Int = 0, initial_input: UnsafePointer<CChar>! = nil, wait_after_command: Bool = false, use_external_io: Bool = false, initially_visible: Bool = false, context: swiftty_surface_context_e = swiftty_surface_context_e(0)) {
        self.platform_tag = platform_tag
        self.platform = platform
        self.userdata = userdata
        self.scale_factor = scale_factor
        self.font_size = font_size
        self.working_directory = working_directory
        self.command = command
        self.env_vars = env_vars
        self.env_var_count = env_var_count
        self.initial_input = initial_input
        self.wait_after_command = wait_after_command
        self.use_external_io = use_external_io
        self.initially_visible = initially_visible
        self.context = context
    }
}

public struct swiftty_surface_size_s: @unchecked Sendable {
    public var columns: UInt16 = 0
    public var rows: UInt16 = 0
    public var width_px: UInt32 = 0
    public var height_px: UInt32 = 0
    public var cell_width_px: UInt32 = 0
    public var cell_height_px: UInt32 = 0

    public init(columns: UInt16 = 0, rows: UInt16 = 0, width_px: UInt32 = 0, height_px: UInt32 = 0, cell_width_px: UInt32 = 0, cell_height_px: UInt32 = 0) {
        self.columns = columns
        self.rows = rows
        self.width_px = width_px
        self.height_px = height_px
        self.cell_width_px = cell_width_px
        self.cell_height_px = cell_height_px
    }
}

public struct swiftty_target_s: @unchecked Sendable {
    public var tag: swiftty_target_tag_e = swiftty_target_tag_e(0)
    public var target: swiftty_target_u = swiftty_target_u()

    public init(tag: swiftty_target_tag_e = swiftty_target_tag_e(0), target: swiftty_target_u = swiftty_target_u()) {
        self.tag = tag
        self.target = target
    }
}

/// A C union in Swiftty; here each member has its own storage.
public struct swiftty_target_u: @unchecked Sendable {
    public var surface: UnsafeMutableRawPointer! = nil

    public init(surface: UnsafeMutableRawPointer! = nil) {
        self.surface = surface
    }
}

public struct swiftty_text_s: @unchecked Sendable {
    public var tl_px_x: Double = 0
    public var tl_px_y: Double = 0
    public var offset_start: UInt32 = 0
    public var offset_len: UInt32 = 0
    public var text: UnsafePointer<CChar>! = nil
    public var text_len: UInt = 0

    public init(tl_px_x: Double = 0, tl_px_y: Double = 0, offset_start: UInt32 = 0, offset_len: UInt32 = 0, text: UnsafePointer<CChar>! = nil, text_len: UInt = 0) {
        self.tl_px_x = tl_px_x
        self.tl_px_y = tl_px_y
        self.offset_start = offset_start
        self.offset_len = offset_len
        self.text = text
        self.text_len = text_len
    }
}

public struct swiftty_tmux_debug_snapshot_s: @unchecked Sendable {
    public var abi_version: UInt32 = 0
    public var viewer_state: UInt8 = 0
    public var parser_state: UInt8 = 0
    public var parser_tolerant: UInt8 = 0
    public var tmux_active: UInt8 = 0
    public var force_unhook_pending: UInt8 = 0
    public var resume_pending: UInt8 = 0
    public var command_in_flight: UInt8 = 0
    public var in_flight_cmd_kind: UInt8 = 0
    public var parser_last_error: UInt8 = 0
    public var viewer_last_error: UInt8 = 0
    public var command_queue_depth: UInt32 = 0
    public var command_queue_highwater: UInt32 = 0
    public var sent_fifo_depth: UInt32 = 0
    public var sent_fifo_highwater: UInt32 = 0
    public var session_id: UInt32 = 0
    public var window_count: UInt32 = 0
    public var pane_count: UInt32 = 0
    public var retired_pane_count: UInt32 = 0
    public var paused_pane_count: UInt32 = 0
    public var uninitialized_pane_count: UInt32 = 0
    public var pending_pane_responses: UInt32 = 0
    public var parser_buffer_bytes: UInt32 = 0
    public var parser_buffer_highwater: UInt32 = 0
    public var parser_buffer_max_bytes: UInt32 = 0
    public var ms_since_last_output: UInt64 = 0
    public var ms_since_last_block: UInt64 = 0
    public var ms_since_last_command_sent: UInt64 = 0
    public var ms_since_last_notification: UInt64 = 0
    public var ms_since_viewer_created: UInt64 = 0
    public var resync_age_ms: UInt64 = 0
    public var total_notifications: UInt64 = 0
    public var total_blocks: UInt64 = 0
    public var total_output_events: UInt64 = 0
    public var total_commands_sent: UInt64 = 0
    public var gw_read_enter_bytes: UInt64 = 0
    public var gw_read_done_bytes: UInt64 = 0
    public var gw_tmux_put_bytes: UInt64 = 0
    public var ms_since_read_enter: UInt64 = 0
    public var ms_since_read_done: UInt64 = 0
    public var pane_lock_timeouts: UInt64 = 0
    public var read_site_pane_id: UInt32 = 0
    public var read_thread_site: UInt8 = 0

    public init(abi_version: UInt32 = 0, viewer_state: UInt8 = 0, parser_state: UInt8 = 0, parser_tolerant: UInt8 = 0, tmux_active: UInt8 = 0, force_unhook_pending: UInt8 = 0, resume_pending: UInt8 = 0, command_in_flight: UInt8 = 0, in_flight_cmd_kind: UInt8 = 0, parser_last_error: UInt8 = 0, viewer_last_error: UInt8 = 0, command_queue_depth: UInt32 = 0, command_queue_highwater: UInt32 = 0, sent_fifo_depth: UInt32 = 0, sent_fifo_highwater: UInt32 = 0, session_id: UInt32 = 0, window_count: UInt32 = 0, pane_count: UInt32 = 0, retired_pane_count: UInt32 = 0, paused_pane_count: UInt32 = 0, uninitialized_pane_count: UInt32 = 0, pending_pane_responses: UInt32 = 0, parser_buffer_bytes: UInt32 = 0, parser_buffer_highwater: UInt32 = 0, parser_buffer_max_bytes: UInt32 = 0, ms_since_last_output: UInt64 = 0, ms_since_last_block: UInt64 = 0, ms_since_last_command_sent: UInt64 = 0, ms_since_last_notification: UInt64 = 0, ms_since_viewer_created: UInt64 = 0, resync_age_ms: UInt64 = 0, total_notifications: UInt64 = 0, total_blocks: UInt64 = 0, total_output_events: UInt64 = 0, total_commands_sent: UInt64 = 0, gw_read_enter_bytes: UInt64 = 0, gw_read_done_bytes: UInt64 = 0, gw_tmux_put_bytes: UInt64 = 0, ms_since_read_enter: UInt64 = 0, ms_since_read_done: UInt64 = 0, pane_lock_timeouts: UInt64 = 0, read_site_pane_id: UInt32 = 0, read_thread_site: UInt8 = 0) {
        self.abi_version = abi_version
        self.viewer_state = viewer_state
        self.parser_state = parser_state
        self.parser_tolerant = parser_tolerant
        self.tmux_active = tmux_active
        self.force_unhook_pending = force_unhook_pending
        self.resume_pending = resume_pending
        self.command_in_flight = command_in_flight
        self.in_flight_cmd_kind = in_flight_cmd_kind
        self.parser_last_error = parser_last_error
        self.viewer_last_error = viewer_last_error
        self.command_queue_depth = command_queue_depth
        self.command_queue_highwater = command_queue_highwater
        self.sent_fifo_depth = sent_fifo_depth
        self.sent_fifo_highwater = sent_fifo_highwater
        self.session_id = session_id
        self.window_count = window_count
        self.pane_count = pane_count
        self.retired_pane_count = retired_pane_count
        self.paused_pane_count = paused_pane_count
        self.uninitialized_pane_count = uninitialized_pane_count
        self.pending_pane_responses = pending_pane_responses
        self.parser_buffer_bytes = parser_buffer_bytes
        self.parser_buffer_highwater = parser_buffer_highwater
        self.parser_buffer_max_bytes = parser_buffer_max_bytes
        self.ms_since_last_output = ms_since_last_output
        self.ms_since_last_block = ms_since_last_block
        self.ms_since_last_command_sent = ms_since_last_command_sent
        self.ms_since_last_notification = ms_since_last_notification
        self.ms_since_viewer_created = ms_since_viewer_created
        self.resync_age_ms = resync_age_ms
        self.total_notifications = total_notifications
        self.total_blocks = total_blocks
        self.total_output_events = total_output_events
        self.total_commands_sent = total_commands_sent
        self.gw_read_enter_bytes = gw_read_enter_bytes
        self.gw_read_done_bytes = gw_read_done_bytes
        self.gw_tmux_put_bytes = gw_tmux_put_bytes
        self.ms_since_read_enter = ms_since_read_enter
        self.ms_since_read_done = ms_since_read_done
        self.pane_lock_timeouts = pane_lock_timeouts
        self.read_site_pane_id = read_site_pane_id
        self.read_thread_site = read_thread_site
    }
}

public struct swiftty_tmux_layout_info_s: @unchecked Sendable {
    public var kind: swiftty_tmux_layout_kind_e = swiftty_tmux_layout_kind_e(0)
    public var width: UInt = 0
    public var height: UInt = 0
    public var x: UInt = 0
    public var y: UInt = 0
    public var pane_id: UInt = 0
    public var child_count: UInt = 0

    public init(kind: swiftty_tmux_layout_kind_e = swiftty_tmux_layout_kind_e(0), width: UInt = 0, height: UInt = 0, x: UInt = 0, y: UInt = 0, pane_id: UInt = 0, child_count: UInt = 0) {
        self.kind = kind
        self.width = width
        self.height = height
        self.x = x
        self.y = y
        self.pane_id = pane_id
        self.child_count = child_count
    }
}

public struct swiftty_tmux_op_s: @unchecked Sendable {
    public var tag: swiftty_tmux_op_tag_e = swiftty_tmux_op_tag_e(0)
    public var window_id: UInt = 0
    public var has_window_id: Bool = false
    public var pane_id: UInt = 0
    public var width: UInt = 0
    public var height: UInt = 0
    public var viewer_terminal: UnsafeMutableRawPointer! = nil
    public var viewer_pane: UnsafeMutableRawPointer! = nil
    public var layout: UnsafeRawPointer! = nil
    public var title: UnsafePointer<CChar>! = nil
    public var title_len: UInt = 0
    public var window_ids: UnsafePointer<UInt>! = nil
    public var window_ids_len: UInt = 0
    public var pane_ids: UnsafePointer<UInt>! = nil
    public var pane_ids_len: UInt = 0
    public var window_index: UInt = 0
    public var zoomed_pane_id: UInt = 0
    public var has_zoomed_pane_id: Bool = false

    public init(tag: swiftty_tmux_op_tag_e = swiftty_tmux_op_tag_e(0), window_id: UInt = 0, has_window_id: Bool = false, pane_id: UInt = 0, width: UInt = 0, height: UInt = 0, viewer_terminal: UnsafeMutableRawPointer! = nil, viewer_pane: UnsafeMutableRawPointer! = nil, layout: UnsafeRawPointer! = nil, title: UnsafePointer<CChar>! = nil, title_len: UInt = 0, window_ids: UnsafePointer<UInt>! = nil, window_ids_len: UInt = 0, pane_ids: UnsafePointer<UInt>! = nil, pane_ids_len: UInt = 0, window_index: UInt = 0, zoomed_pane_id: UInt = 0, has_zoomed_pane_id: Bool = false) {
        self.tag = tag
        self.window_id = window_id
        self.has_window_id = has_window_id
        self.pane_id = pane_id
        self.width = width
        self.height = height
        self.viewer_terminal = viewer_terminal
        self.viewer_pane = viewer_pane
        self.layout = layout
        self.title = title
        self.title_len = title_len
        self.window_ids = window_ids
        self.window_ids_len = window_ids_len
        self.pane_ids = pane_ids
        self.pane_ids_len = pane_ids_len
        self.window_index = window_index
        self.zoomed_pane_id = zoomed_pane_id
        self.has_zoomed_pane_id = has_zoomed_pane_id
    }
}
