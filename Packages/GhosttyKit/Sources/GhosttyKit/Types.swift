// Swift definitions of the libghostty embedder API types Shell uses.
// Names, fields and constant values follow Ghostty's ghostty.h (MIT,
// Mitchell Hashimoto) so call sites read the same; there is no C ABI.
// Generated once from that header; edit by hand from here on.

// swiftlint:disable identifier_name type_name file_length

public typealias ghostty_app_t = UnsafeMutableRawPointer
public typealias ghostty_config_t = UnsafeMutableRawPointer
public typealias ghostty_surface_t = UnsafeMutableRawPointer
public typealias ghostty_input_scroll_mods_t = Int32

public let GHOSTTY_SUCCESS: Int32 = 0

public struct ghostty_action_mouse_shape_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public let GHOSTTY_MOUSE_SHAPE_DEFAULT = ghostty_action_mouse_shape_e(0)
public let GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU = ghostty_action_mouse_shape_e(1)
public let GHOSTTY_MOUSE_SHAPE_HELP = ghostty_action_mouse_shape_e(2)
public let GHOSTTY_MOUSE_SHAPE_POINTER = ghostty_action_mouse_shape_e(3)
public let GHOSTTY_MOUSE_SHAPE_PROGRESS = ghostty_action_mouse_shape_e(4)
public let GHOSTTY_MOUSE_SHAPE_WAIT = ghostty_action_mouse_shape_e(5)
public let GHOSTTY_MOUSE_SHAPE_CELL = ghostty_action_mouse_shape_e(6)
public let GHOSTTY_MOUSE_SHAPE_CROSSHAIR = ghostty_action_mouse_shape_e(7)
public let GHOSTTY_MOUSE_SHAPE_TEXT = ghostty_action_mouse_shape_e(8)
public let GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT = ghostty_action_mouse_shape_e(9)
public let GHOSTTY_MOUSE_SHAPE_ALIAS = ghostty_action_mouse_shape_e(10)
public let GHOSTTY_MOUSE_SHAPE_COPY = ghostty_action_mouse_shape_e(11)
public let GHOSTTY_MOUSE_SHAPE_MOVE = ghostty_action_mouse_shape_e(12)
public let GHOSTTY_MOUSE_SHAPE_NO_DROP = ghostty_action_mouse_shape_e(13)
public let GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED = ghostty_action_mouse_shape_e(14)
public let GHOSTTY_MOUSE_SHAPE_GRAB = ghostty_action_mouse_shape_e(15)
public let GHOSTTY_MOUSE_SHAPE_GRABBING = ghostty_action_mouse_shape_e(16)
public let GHOSTTY_MOUSE_SHAPE_ALL_SCROLL = ghostty_action_mouse_shape_e(17)
public let GHOSTTY_MOUSE_SHAPE_COL_RESIZE = ghostty_action_mouse_shape_e(18)
public let GHOSTTY_MOUSE_SHAPE_ROW_RESIZE = ghostty_action_mouse_shape_e(19)
public let GHOSTTY_MOUSE_SHAPE_N_RESIZE = ghostty_action_mouse_shape_e(20)
public let GHOSTTY_MOUSE_SHAPE_E_RESIZE = ghostty_action_mouse_shape_e(21)
public let GHOSTTY_MOUSE_SHAPE_S_RESIZE = ghostty_action_mouse_shape_e(22)
public let GHOSTTY_MOUSE_SHAPE_W_RESIZE = ghostty_action_mouse_shape_e(23)
public let GHOSTTY_MOUSE_SHAPE_NE_RESIZE = ghostty_action_mouse_shape_e(24)
public let GHOSTTY_MOUSE_SHAPE_NW_RESIZE = ghostty_action_mouse_shape_e(25)
public let GHOSTTY_MOUSE_SHAPE_SE_RESIZE = ghostty_action_mouse_shape_e(26)
public let GHOSTTY_MOUSE_SHAPE_SW_RESIZE = ghostty_action_mouse_shape_e(27)
public let GHOSTTY_MOUSE_SHAPE_EW_RESIZE = ghostty_action_mouse_shape_e(28)
public let GHOSTTY_MOUSE_SHAPE_NS_RESIZE = ghostty_action_mouse_shape_e(29)
public let GHOSTTY_MOUSE_SHAPE_NESW_RESIZE = ghostty_action_mouse_shape_e(30)
public let GHOSTTY_MOUSE_SHAPE_NWSE_RESIZE = ghostty_action_mouse_shape_e(31)
public let GHOSTTY_MOUSE_SHAPE_ZOOM_IN = ghostty_action_mouse_shape_e(32)
public let GHOSTTY_MOUSE_SHAPE_ZOOM_OUT = ghostty_action_mouse_shape_e(33)

public struct ghostty_action_mouse_visibility_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public let GHOSTTY_MOUSE_VISIBLE = ghostty_action_mouse_visibility_e(0)
public let GHOSTTY_MOUSE_HIDDEN = ghostty_action_mouse_visibility_e(1)

public struct ghostty_action_open_url_kind_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public let GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN = ghostty_action_open_url_kind_e(0)
public let GHOSTTY_ACTION_OPEN_URL_KIND_TEXT = ghostty_action_open_url_kind_e(1)
public let GHOSTTY_ACTION_OPEN_URL_KIND_HTML = ghostty_action_open_url_kind_e(2)
public let GHOSTTY_ACTION_OPEN_URL_KIND_OSC8 = ghostty_action_open_url_kind_e(3)

public struct ghostty_action_progress_report_state_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public let GHOSTTY_PROGRESS_STATE_REMOVE = ghostty_action_progress_report_state_e(0)
public let GHOSTTY_PROGRESS_STATE_SET = ghostty_action_progress_report_state_e(1)
public let GHOSTTY_PROGRESS_STATE_ERROR = ghostty_action_progress_report_state_e(2)
public let GHOSTTY_PROGRESS_STATE_INDETERMINATE = ghostty_action_progress_report_state_e(3)
public let GHOSTTY_PROGRESS_STATE_PAUSE = ghostty_action_progress_report_state_e(4)

public struct ghostty_action_tag_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public let GHOSTTY_ACTION_QUIT = ghostty_action_tag_e(0)
public let GHOSTTY_ACTION_NEW_WINDOW = ghostty_action_tag_e(1)
public let GHOSTTY_ACTION_NEW_TAB = ghostty_action_tag_e(2)
public let GHOSTTY_ACTION_CLOSE_TAB = ghostty_action_tag_e(3)
public let GHOSTTY_ACTION_NEW_SPLIT = ghostty_action_tag_e(4)
public let GHOSTTY_ACTION_CLOSE_ALL_WINDOWS = ghostty_action_tag_e(5)
public let GHOSTTY_ACTION_TOGGLE_MAXIMIZE = ghostty_action_tag_e(6)
public let GHOSTTY_ACTION_TOGGLE_FULLSCREEN = ghostty_action_tag_e(7)
public let GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW = ghostty_action_tag_e(8)
public let GHOSTTY_ACTION_TOGGLE_WINDOW_DECORATIONS = ghostty_action_tag_e(9)
public let GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL = ghostty_action_tag_e(10)
public let GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE = ghostty_action_tag_e(11)
public let GHOSTTY_ACTION_TOGGLE_VISIBILITY = ghostty_action_tag_e(12)
public let GHOSTTY_ACTION_TOGGLE_BACKGROUND_OPACITY = ghostty_action_tag_e(13)
public let GHOSTTY_ACTION_MOVE_TAB = ghostty_action_tag_e(14)
public let GHOSTTY_ACTION_GOTO_TAB = ghostty_action_tag_e(15)
public let GHOSTTY_ACTION_GOTO_SPLIT = ghostty_action_tag_e(16)
public let GHOSTTY_ACTION_GOTO_WINDOW = ghostty_action_tag_e(17)
public let GHOSTTY_ACTION_RESIZE_SPLIT = ghostty_action_tag_e(18)
public let GHOSTTY_ACTION_EQUALIZE_SPLITS = ghostty_action_tag_e(19)
public let GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM = ghostty_action_tag_e(20)
public let GHOSTTY_ACTION_PRESENT_TERMINAL = ghostty_action_tag_e(21)
public let GHOSTTY_ACTION_SIZE_LIMIT = ghostty_action_tag_e(22)
public let GHOSTTY_ACTION_RESET_WINDOW_SIZE = ghostty_action_tag_e(23)
public let GHOSTTY_ACTION_INITIAL_SIZE = ghostty_action_tag_e(24)
public let GHOSTTY_ACTION_CELL_SIZE = ghostty_action_tag_e(25)
public let GHOSTTY_ACTION_SCROLLBAR = ghostty_action_tag_e(26)
public let GHOSTTY_ACTION_RENDER = ghostty_action_tag_e(27)
public let GHOSTTY_ACTION_INSPECTOR = ghostty_action_tag_e(28)
public let GHOSTTY_ACTION_SHOW_GTK_INSPECTOR = ghostty_action_tag_e(29)
public let GHOSTTY_ACTION_RENDER_INSPECTOR = ghostty_action_tag_e(30)
public let GHOSTTY_ACTION_EXPORT_TERMINAL_IO = ghostty_action_tag_e(31)
public let GHOSTTY_ACTION_DESKTOP_NOTIFICATION = ghostty_action_tag_e(32)
public let GHOSTTY_ACTION_SET_TITLE = ghostty_action_tag_e(33)
public let GHOSTTY_ACTION_SET_TAB_TITLE = ghostty_action_tag_e(34)
public let GHOSTTY_ACTION_SET_WINDOW_TITLE = ghostty_action_tag_e(35)
public let GHOSTTY_ACTION_PROMPT_TITLE = ghostty_action_tag_e(36)
public let GHOSTTY_ACTION_PWD = ghostty_action_tag_e(37)
public let GHOSTTY_ACTION_MOUSE_SHAPE = ghostty_action_tag_e(38)
public let GHOSTTY_ACTION_MOUSE_VISIBILITY = ghostty_action_tag_e(39)
public let GHOSTTY_ACTION_MOUSE_OVER_LINK = ghostty_action_tag_e(40)
public let GHOSTTY_ACTION_RENDERER_HEALTH = ghostty_action_tag_e(41)
public let GHOSTTY_ACTION_OPEN_CONFIG = ghostty_action_tag_e(42)
public let GHOSTTY_ACTION_QUIT_TIMER = ghostty_action_tag_e(43)
public let GHOSTTY_ACTION_FLOAT_WINDOW = ghostty_action_tag_e(44)
public let GHOSTTY_ACTION_SECURE_INPUT = ghostty_action_tag_e(45)
public let GHOSTTY_ACTION_KEY_SEQUENCE = ghostty_action_tag_e(46)
public let GHOSTTY_ACTION_KEY_TABLE = ghostty_action_tag_e(47)
public let GHOSTTY_ACTION_COLOR_CHANGE = ghostty_action_tag_e(48)
public let GHOSTTY_ACTION_RELOAD_CONFIG = ghostty_action_tag_e(49)
public let GHOSTTY_ACTION_CONFIG_CHANGE = ghostty_action_tag_e(50)
public let GHOSTTY_ACTION_CLOSE_WINDOW = ghostty_action_tag_e(51)
public let GHOSTTY_ACTION_RING_BELL = ghostty_action_tag_e(52)
public let GHOSTTY_ACTION_SELECTION_CHANGED = ghostty_action_tag_e(53)
public let GHOSTTY_ACTION_UNDO = ghostty_action_tag_e(54)
public let GHOSTTY_ACTION_REDO = ghostty_action_tag_e(55)
public let GHOSTTY_ACTION_CHECK_FOR_UPDATES = ghostty_action_tag_e(56)
public let GHOSTTY_ACTION_OPEN_URL = ghostty_action_tag_e(57)
public let GHOSTTY_ACTION_SHOW_CHILD_EXITED = ghostty_action_tag_e(58)
public let GHOSTTY_ACTION_PROGRESS_REPORT = ghostty_action_tag_e(59)
public let GHOSTTY_ACTION_SHOW_ON_SCREEN_KEYBOARD = ghostty_action_tag_e(60)
public let GHOSTTY_ACTION_COMMAND_FINISHED = ghostty_action_tag_e(61)
public let GHOSTTY_ACTION_START_SEARCH = ghostty_action_tag_e(62)
public let GHOSTTY_ACTION_END_SEARCH = ghostty_action_tag_e(63)
public let GHOSTTY_ACTION_SEARCH_TOTAL = ghostty_action_tag_e(64)
public let GHOSTTY_ACTION_SEARCH_SELECTED = ghostty_action_tag_e(65)
public let GHOSTTY_ACTION_READONLY = ghostty_action_tag_e(66)
public let GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD = ghostty_action_tag_e(67)
public let GHOSTTY_ACTION_MOVE_TAB_TO_NEW_WINDOW = ghostty_action_tag_e(68)
public let GHOSTTY_ACTION_TMUX_RECONCILE = ghostty_action_tag_e(69)
public let GHOSTTY_ACTION_TMUX_SESSIONS_CHANGED = ghostty_action_tag_e(70)
public let GHOSTTY_ACTION_TMUX_SESSION_CHANGED = ghostty_action_tag_e(71)
public let GHOSTTY_ACTION_TMUX_COMMAND_RESPONSE = ghostty_action_tag_e(72)
public let GHOSTTY_ACTION_SURFACE_CONTENT_CHANGED = ghostty_action_tag_e(73)
public let GHOSTTY_ACTION_PTY_RESIZE = ghostty_action_tag_e(74)
/// A tmux pane's captured content was applied (visible-pane sync).
public let GHOSTTY_ACTION_TMUX_PANE_SYNCED = ghostty_action_tag_e(75)

public struct ghostty_clipboard_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public let GHOSTTY_CLIPBOARD_STANDARD = ghostty_clipboard_e(0)
public let GHOSTTY_CLIPBOARD_SELECTION = ghostty_clipboard_e(1)

public struct ghostty_clipboard_request_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public let GHOSTTY_CLIPBOARD_REQUEST_PASTE = ghostty_clipboard_request_e(0)
public let GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ = ghostty_clipboard_request_e(1)
public let GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE = ghostty_clipboard_request_e(2)

public struct ghostty_input_action_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public let GHOSTTY_ACTION_RELEASE = ghostty_input_action_e(0)
public let GHOSTTY_ACTION_PRESS = ghostty_input_action_e(1)
public let GHOSTTY_ACTION_REPEAT = ghostty_input_action_e(2)

public struct ghostty_input_key_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public let GHOSTTY_KEY_UNIDENTIFIED = ghostty_input_key_e(0)
public let GHOSTTY_KEY_BACKQUOTE = ghostty_input_key_e(1)
public let GHOSTTY_KEY_BACKSLASH = ghostty_input_key_e(2)
public let GHOSTTY_KEY_BRACKET_LEFT = ghostty_input_key_e(3)
public let GHOSTTY_KEY_BRACKET_RIGHT = ghostty_input_key_e(4)
public let GHOSTTY_KEY_COMMA = ghostty_input_key_e(5)
public let GHOSTTY_KEY_DIGIT_0 = ghostty_input_key_e(6)
public let GHOSTTY_KEY_DIGIT_1 = ghostty_input_key_e(7)
public let GHOSTTY_KEY_DIGIT_2 = ghostty_input_key_e(8)
public let GHOSTTY_KEY_DIGIT_3 = ghostty_input_key_e(9)
public let GHOSTTY_KEY_DIGIT_4 = ghostty_input_key_e(10)
public let GHOSTTY_KEY_DIGIT_5 = ghostty_input_key_e(11)
public let GHOSTTY_KEY_DIGIT_6 = ghostty_input_key_e(12)
public let GHOSTTY_KEY_DIGIT_7 = ghostty_input_key_e(13)
public let GHOSTTY_KEY_DIGIT_8 = ghostty_input_key_e(14)
public let GHOSTTY_KEY_DIGIT_9 = ghostty_input_key_e(15)
public let GHOSTTY_KEY_EQUAL = ghostty_input_key_e(16)
public let GHOSTTY_KEY_INTL_BACKSLASH = ghostty_input_key_e(17)
public let GHOSTTY_KEY_INTL_RO = ghostty_input_key_e(18)
public let GHOSTTY_KEY_INTL_YEN = ghostty_input_key_e(19)
public let GHOSTTY_KEY_A = ghostty_input_key_e(20)
public let GHOSTTY_KEY_B = ghostty_input_key_e(21)
public let GHOSTTY_KEY_C = ghostty_input_key_e(22)
public let GHOSTTY_KEY_D = ghostty_input_key_e(23)
public let GHOSTTY_KEY_E = ghostty_input_key_e(24)
public let GHOSTTY_KEY_F = ghostty_input_key_e(25)
public let GHOSTTY_KEY_G = ghostty_input_key_e(26)
public let GHOSTTY_KEY_H = ghostty_input_key_e(27)
public let GHOSTTY_KEY_I = ghostty_input_key_e(28)
public let GHOSTTY_KEY_J = ghostty_input_key_e(29)
public let GHOSTTY_KEY_K = ghostty_input_key_e(30)
public let GHOSTTY_KEY_L = ghostty_input_key_e(31)
public let GHOSTTY_KEY_M = ghostty_input_key_e(32)
public let GHOSTTY_KEY_N = ghostty_input_key_e(33)
public let GHOSTTY_KEY_O = ghostty_input_key_e(34)
public let GHOSTTY_KEY_P = ghostty_input_key_e(35)
public let GHOSTTY_KEY_Q = ghostty_input_key_e(36)
public let GHOSTTY_KEY_R = ghostty_input_key_e(37)
public let GHOSTTY_KEY_S = ghostty_input_key_e(38)
public let GHOSTTY_KEY_T = ghostty_input_key_e(39)
public let GHOSTTY_KEY_U = ghostty_input_key_e(40)
public let GHOSTTY_KEY_V = ghostty_input_key_e(41)
public let GHOSTTY_KEY_W = ghostty_input_key_e(42)
public let GHOSTTY_KEY_X = ghostty_input_key_e(43)
public let GHOSTTY_KEY_Y = ghostty_input_key_e(44)
public let GHOSTTY_KEY_Z = ghostty_input_key_e(45)
public let GHOSTTY_KEY_MINUS = ghostty_input_key_e(46)
public let GHOSTTY_KEY_PERIOD = ghostty_input_key_e(47)
public let GHOSTTY_KEY_QUOTE = ghostty_input_key_e(48)
public let GHOSTTY_KEY_SEMICOLON = ghostty_input_key_e(49)
public let GHOSTTY_KEY_SLASH = ghostty_input_key_e(50)
public let GHOSTTY_KEY_ALT_LEFT = ghostty_input_key_e(51)
public let GHOSTTY_KEY_ALT_RIGHT = ghostty_input_key_e(52)
public let GHOSTTY_KEY_BACKSPACE = ghostty_input_key_e(53)
public let GHOSTTY_KEY_CAPS_LOCK = ghostty_input_key_e(54)
public let GHOSTTY_KEY_CONTEXT_MENU = ghostty_input_key_e(55)
public let GHOSTTY_KEY_CONTROL_LEFT = ghostty_input_key_e(56)
public let GHOSTTY_KEY_CONTROL_RIGHT = ghostty_input_key_e(57)
public let GHOSTTY_KEY_ENTER = ghostty_input_key_e(58)
public let GHOSTTY_KEY_META_LEFT = ghostty_input_key_e(59)
public let GHOSTTY_KEY_META_RIGHT = ghostty_input_key_e(60)
public let GHOSTTY_KEY_SHIFT_LEFT = ghostty_input_key_e(61)
public let GHOSTTY_KEY_SHIFT_RIGHT = ghostty_input_key_e(62)
public let GHOSTTY_KEY_SPACE = ghostty_input_key_e(63)
public let GHOSTTY_KEY_TAB = ghostty_input_key_e(64)
public let GHOSTTY_KEY_CONVERT = ghostty_input_key_e(65)
public let GHOSTTY_KEY_KANA_MODE = ghostty_input_key_e(66)
public let GHOSTTY_KEY_NON_CONVERT = ghostty_input_key_e(67)
public let GHOSTTY_KEY_DELETE = ghostty_input_key_e(68)
public let GHOSTTY_KEY_END = ghostty_input_key_e(69)
public let GHOSTTY_KEY_HELP = ghostty_input_key_e(70)
public let GHOSTTY_KEY_HOME = ghostty_input_key_e(71)
public let GHOSTTY_KEY_INSERT = ghostty_input_key_e(72)
public let GHOSTTY_KEY_PAGE_DOWN = ghostty_input_key_e(73)
public let GHOSTTY_KEY_PAGE_UP = ghostty_input_key_e(74)
public let GHOSTTY_KEY_ARROW_DOWN = ghostty_input_key_e(75)
public let GHOSTTY_KEY_ARROW_LEFT = ghostty_input_key_e(76)
public let GHOSTTY_KEY_ARROW_RIGHT = ghostty_input_key_e(77)
public let GHOSTTY_KEY_ARROW_UP = ghostty_input_key_e(78)
public let GHOSTTY_KEY_NUM_LOCK = ghostty_input_key_e(79)
public let GHOSTTY_KEY_NUMPAD_0 = ghostty_input_key_e(80)
public let GHOSTTY_KEY_NUMPAD_1 = ghostty_input_key_e(81)
public let GHOSTTY_KEY_NUMPAD_2 = ghostty_input_key_e(82)
public let GHOSTTY_KEY_NUMPAD_3 = ghostty_input_key_e(83)
public let GHOSTTY_KEY_NUMPAD_4 = ghostty_input_key_e(84)
public let GHOSTTY_KEY_NUMPAD_5 = ghostty_input_key_e(85)
public let GHOSTTY_KEY_NUMPAD_6 = ghostty_input_key_e(86)
public let GHOSTTY_KEY_NUMPAD_7 = ghostty_input_key_e(87)
public let GHOSTTY_KEY_NUMPAD_8 = ghostty_input_key_e(88)
public let GHOSTTY_KEY_NUMPAD_9 = ghostty_input_key_e(89)
public let GHOSTTY_KEY_NUMPAD_ADD = ghostty_input_key_e(90)
public let GHOSTTY_KEY_NUMPAD_BACKSPACE = ghostty_input_key_e(91)
public let GHOSTTY_KEY_NUMPAD_CLEAR = ghostty_input_key_e(92)
public let GHOSTTY_KEY_NUMPAD_CLEAR_ENTRY = ghostty_input_key_e(93)
public let GHOSTTY_KEY_NUMPAD_COMMA = ghostty_input_key_e(94)
public let GHOSTTY_KEY_NUMPAD_DECIMAL = ghostty_input_key_e(95)
public let GHOSTTY_KEY_NUMPAD_DIVIDE = ghostty_input_key_e(96)
public let GHOSTTY_KEY_NUMPAD_ENTER = ghostty_input_key_e(97)
public let GHOSTTY_KEY_NUMPAD_EQUAL = ghostty_input_key_e(98)
public let GHOSTTY_KEY_NUMPAD_MEMORY_ADD = ghostty_input_key_e(99)
public let GHOSTTY_KEY_NUMPAD_MEMORY_CLEAR = ghostty_input_key_e(100)
public let GHOSTTY_KEY_NUMPAD_MEMORY_RECALL = ghostty_input_key_e(101)
public let GHOSTTY_KEY_NUMPAD_MEMORY_STORE = ghostty_input_key_e(102)
public let GHOSTTY_KEY_NUMPAD_MEMORY_SUBTRACT = ghostty_input_key_e(103)
public let GHOSTTY_KEY_NUMPAD_MULTIPLY = ghostty_input_key_e(104)
public let GHOSTTY_KEY_NUMPAD_PAREN_LEFT = ghostty_input_key_e(105)
public let GHOSTTY_KEY_NUMPAD_PAREN_RIGHT = ghostty_input_key_e(106)
public let GHOSTTY_KEY_NUMPAD_SUBTRACT = ghostty_input_key_e(107)
public let GHOSTTY_KEY_NUMPAD_SEPARATOR = ghostty_input_key_e(108)
public let GHOSTTY_KEY_NUMPAD_UP = ghostty_input_key_e(109)
public let GHOSTTY_KEY_NUMPAD_DOWN = ghostty_input_key_e(110)
public let GHOSTTY_KEY_NUMPAD_RIGHT = ghostty_input_key_e(111)
public let GHOSTTY_KEY_NUMPAD_LEFT = ghostty_input_key_e(112)
public let GHOSTTY_KEY_NUMPAD_BEGIN = ghostty_input_key_e(113)
public let GHOSTTY_KEY_NUMPAD_HOME = ghostty_input_key_e(114)
public let GHOSTTY_KEY_NUMPAD_END = ghostty_input_key_e(115)
public let GHOSTTY_KEY_NUMPAD_INSERT = ghostty_input_key_e(116)
public let GHOSTTY_KEY_NUMPAD_DELETE = ghostty_input_key_e(117)
public let GHOSTTY_KEY_NUMPAD_PAGE_UP = ghostty_input_key_e(118)
public let GHOSTTY_KEY_NUMPAD_PAGE_DOWN = ghostty_input_key_e(119)
public let GHOSTTY_KEY_ESCAPE = ghostty_input_key_e(120)
public let GHOSTTY_KEY_F1 = ghostty_input_key_e(121)
public let GHOSTTY_KEY_F2 = ghostty_input_key_e(122)
public let GHOSTTY_KEY_F3 = ghostty_input_key_e(123)
public let GHOSTTY_KEY_F4 = ghostty_input_key_e(124)
public let GHOSTTY_KEY_F5 = ghostty_input_key_e(125)
public let GHOSTTY_KEY_F6 = ghostty_input_key_e(126)
public let GHOSTTY_KEY_F7 = ghostty_input_key_e(127)
public let GHOSTTY_KEY_F8 = ghostty_input_key_e(128)
public let GHOSTTY_KEY_F9 = ghostty_input_key_e(129)
public let GHOSTTY_KEY_F10 = ghostty_input_key_e(130)
public let GHOSTTY_KEY_F11 = ghostty_input_key_e(131)
public let GHOSTTY_KEY_F12 = ghostty_input_key_e(132)
public let GHOSTTY_KEY_F13 = ghostty_input_key_e(133)
public let GHOSTTY_KEY_F14 = ghostty_input_key_e(134)
public let GHOSTTY_KEY_F15 = ghostty_input_key_e(135)
public let GHOSTTY_KEY_F16 = ghostty_input_key_e(136)
public let GHOSTTY_KEY_F17 = ghostty_input_key_e(137)
public let GHOSTTY_KEY_F18 = ghostty_input_key_e(138)
public let GHOSTTY_KEY_F19 = ghostty_input_key_e(139)
public let GHOSTTY_KEY_F20 = ghostty_input_key_e(140)
public let GHOSTTY_KEY_F21 = ghostty_input_key_e(141)
public let GHOSTTY_KEY_F22 = ghostty_input_key_e(142)
public let GHOSTTY_KEY_F23 = ghostty_input_key_e(143)
public let GHOSTTY_KEY_F24 = ghostty_input_key_e(144)
public let GHOSTTY_KEY_F25 = ghostty_input_key_e(145)
public let GHOSTTY_KEY_FN = ghostty_input_key_e(146)
public let GHOSTTY_KEY_FN_LOCK = ghostty_input_key_e(147)
public let GHOSTTY_KEY_PRINT_SCREEN = ghostty_input_key_e(148)
public let GHOSTTY_KEY_SCROLL_LOCK = ghostty_input_key_e(149)
public let GHOSTTY_KEY_PAUSE = ghostty_input_key_e(150)
public let GHOSTTY_KEY_BROWSER_BACK = ghostty_input_key_e(151)
public let GHOSTTY_KEY_BROWSER_FAVORITES = ghostty_input_key_e(152)
public let GHOSTTY_KEY_BROWSER_FORWARD = ghostty_input_key_e(153)
public let GHOSTTY_KEY_BROWSER_HOME = ghostty_input_key_e(154)
public let GHOSTTY_KEY_BROWSER_REFRESH = ghostty_input_key_e(155)
public let GHOSTTY_KEY_BROWSER_SEARCH = ghostty_input_key_e(156)
public let GHOSTTY_KEY_BROWSER_STOP = ghostty_input_key_e(157)
public let GHOSTTY_KEY_EJECT = ghostty_input_key_e(158)
public let GHOSTTY_KEY_LAUNCH_APP_1 = ghostty_input_key_e(159)
public let GHOSTTY_KEY_LAUNCH_APP_2 = ghostty_input_key_e(160)
public let GHOSTTY_KEY_LAUNCH_MAIL = ghostty_input_key_e(161)
public let GHOSTTY_KEY_MEDIA_PLAY_PAUSE = ghostty_input_key_e(162)
public let GHOSTTY_KEY_MEDIA_SELECT = ghostty_input_key_e(163)
public let GHOSTTY_KEY_MEDIA_STOP = ghostty_input_key_e(164)
public let GHOSTTY_KEY_MEDIA_TRACK_NEXT = ghostty_input_key_e(165)
public let GHOSTTY_KEY_MEDIA_TRACK_PREVIOUS = ghostty_input_key_e(166)
public let GHOSTTY_KEY_POWER = ghostty_input_key_e(167)
public let GHOSTTY_KEY_SLEEP = ghostty_input_key_e(168)
public let GHOSTTY_KEY_AUDIO_VOLUME_DOWN = ghostty_input_key_e(169)
public let GHOSTTY_KEY_AUDIO_VOLUME_MUTE = ghostty_input_key_e(170)
public let GHOSTTY_KEY_AUDIO_VOLUME_UP = ghostty_input_key_e(171)
public let GHOSTTY_KEY_WAKE_UP = ghostty_input_key_e(172)
public let GHOSTTY_KEY_COPY = ghostty_input_key_e(173)
public let GHOSTTY_KEY_CUT = ghostty_input_key_e(174)
public let GHOSTTY_KEY_PASTE = ghostty_input_key_e(175)

public struct ghostty_input_mods_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public let GHOSTTY_MODS_NONE = ghostty_input_mods_e(0)
public let GHOSTTY_MODS_SHIFT = ghostty_input_mods_e(1)
public let GHOSTTY_MODS_CTRL = ghostty_input_mods_e(2)
public let GHOSTTY_MODS_ALT = ghostty_input_mods_e(4)
public let GHOSTTY_MODS_SUPER = ghostty_input_mods_e(8)
public let GHOSTTY_MODS_CAPS = ghostty_input_mods_e(16)
public let GHOSTTY_MODS_NUM = ghostty_input_mods_e(32)
public let GHOSTTY_MODS_SHIFT_RIGHT = ghostty_input_mods_e(64)
public let GHOSTTY_MODS_CTRL_RIGHT = ghostty_input_mods_e(128)
public let GHOSTTY_MODS_ALT_RIGHT = ghostty_input_mods_e(256)
public let GHOSTTY_MODS_SUPER_RIGHT = ghostty_input_mods_e(512)

public struct ghostty_input_mouse_button_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public let GHOSTTY_MOUSE_UNKNOWN = ghostty_input_mouse_button_e(0)
public let GHOSTTY_MOUSE_LEFT = ghostty_input_mouse_button_e(1)
public let GHOSTTY_MOUSE_RIGHT = ghostty_input_mouse_button_e(2)
public let GHOSTTY_MOUSE_MIDDLE = ghostty_input_mouse_button_e(3)
public let GHOSTTY_MOUSE_FOUR = ghostty_input_mouse_button_e(4)
public let GHOSTTY_MOUSE_FIVE = ghostty_input_mouse_button_e(5)
public let GHOSTTY_MOUSE_SIX = ghostty_input_mouse_button_e(6)
public let GHOSTTY_MOUSE_SEVEN = ghostty_input_mouse_button_e(7)
public let GHOSTTY_MOUSE_EIGHT = ghostty_input_mouse_button_e(8)
public let GHOSTTY_MOUSE_NINE = ghostty_input_mouse_button_e(9)
public let GHOSTTY_MOUSE_TEN = ghostty_input_mouse_button_e(10)
public let GHOSTTY_MOUSE_ELEVEN = ghostty_input_mouse_button_e(11)

public struct ghostty_input_mouse_state_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public let GHOSTTY_MOUSE_RELEASE = ghostty_input_mouse_state_e(0)
public let GHOSTTY_MOUSE_PRESS = ghostty_input_mouse_state_e(1)

public struct ghostty_platform_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public let GHOSTTY_PLATFORM_INVALID = ghostty_platform_e(0)
public let GHOSTTY_PLATFORM_MACOS = ghostty_platform_e(1)
public let GHOSTTY_PLATFORM_IOS = ghostty_platform_e(2)

public struct ghostty_point_coord_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public let GHOSTTY_POINT_COORD_EXACT = ghostty_point_coord_e(0)
public let GHOSTTY_POINT_COORD_TOP_LEFT = ghostty_point_coord_e(1)
public let GHOSTTY_POINT_COORD_BOTTOM_RIGHT = ghostty_point_coord_e(2)

public struct ghostty_point_tag_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public let GHOSTTY_POINT_ACTIVE = ghostty_point_tag_e(0)
public let GHOSTTY_POINT_VIEWPORT = ghostty_point_tag_e(1)
public let GHOSTTY_POINT_SCREEN = ghostty_point_tag_e(2)
public let GHOSTTY_POINT_SURFACE = ghostty_point_tag_e(3)

public struct ghostty_surface_context_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public let GHOSTTY_SURFACE_CONTEXT_WINDOW = ghostty_surface_context_e(0)
public let GHOSTTY_SURFACE_CONTEXT_TAB = ghostty_surface_context_e(1)
public let GHOSTTY_SURFACE_CONTEXT_SPLIT = ghostty_surface_context_e(2)

public struct ghostty_target_tag_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public let GHOSTTY_TARGET_APP = ghostty_target_tag_e(0)
public let GHOSTTY_TARGET_SURFACE = ghostty_target_tag_e(1)

public struct ghostty_tmux_layout_kind_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public let GHOSTTY_TMUX_LAYOUT_PANE = ghostty_tmux_layout_kind_e(0)
public let GHOSTTY_TMUX_LAYOUT_HORIZONTAL = ghostty_tmux_layout_kind_e(1)
public let GHOSTTY_TMUX_LAYOUT_VERTICAL = ghostty_tmux_layout_kind_e(2)

public struct ghostty_tmux_op_tag_e: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public let GHOSTTY_TMUX_OP_SYNC_BEGIN = ghostty_tmux_op_tag_e(0)
public let GHOSTTY_TMUX_OP_ENSURE_WINDOW = ghostty_tmux_op_tag_e(1)
public let GHOSTTY_TMUX_OP_ENSURE_PANE = ghostty_tmux_op_tag_e(2)
public let GHOSTTY_TMUX_OP_SET_LAYOUT = ghostty_tmux_op_tag_e(3)
public let GHOSTTY_TMUX_OP_SET_FOCUS = ghostty_tmux_op_tag_e(4)
public let GHOSTTY_TMUX_OP_PRUNE_ABSENT = ghostty_tmux_op_tag_e(5)
public let GHOSTTY_TMUX_OP_SYNC_END = ghostty_tmux_op_tag_e(6)
public let GHOSTTY_TMUX_OP_SET_TAB_TITLE = ghostty_tmux_op_tag_e(7)
public let GHOSTTY_TMUX_OP_SET_WINDOW_TITLE = ghostty_tmux_op_tag_e(8)

public struct ghostty_action_cell_size_s: @unchecked Sendable {
    public var width: UInt32 = 0
    public var height: UInt32 = 0

    public init(width: UInt32 = 0, height: UInt32 = 0) {
        self.width = width
        self.height = height
    }
}

public struct ghostty_action_desktop_notification_s: @unchecked Sendable {
    public var title: UnsafePointer<CChar>! = nil
    public var body: UnsafePointer<CChar>! = nil

    public init(title: UnsafePointer<CChar>! = nil, body: UnsafePointer<CChar>! = nil) {
        self.title = title
        self.body = body
    }
}

public struct ghostty_action_mouse_over_link_s: @unchecked Sendable {
    public var url: UnsafePointer<CChar>! = nil
    public var len: Int = 0

    public init(url: UnsafePointer<CChar>! = nil, len: Int = 0) {
        self.url = url
        self.len = len
    }
}

public struct ghostty_action_open_url_s: @unchecked Sendable {
    public var kind: ghostty_action_open_url_kind_e = ghostty_action_open_url_kind_e(0)
    public var url: UnsafePointer<CChar>! = nil
    public var len: UInt = 0

    public init(kind: ghostty_action_open_url_kind_e = ghostty_action_open_url_kind_e(0), url: UnsafePointer<CChar>! = nil, len: UInt = 0) {
        self.kind = kind
        self.url = url
        self.len = len
    }
}

public struct ghostty_action_progress_report_s: @unchecked Sendable {
    public var state: ghostty_action_progress_report_state_e = ghostty_action_progress_report_state_e(0)
    public var progress: Int8 = 0

    public init(state: ghostty_action_progress_report_state_e = ghostty_action_progress_report_state_e(0), progress: Int8 = 0) {
        self.state = state
        self.progress = progress
    }
}

public struct ghostty_action_pty_resize_s: @unchecked Sendable {
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

public struct ghostty_action_pwd_s: @unchecked Sendable {
    public var pwd: UnsafePointer<CChar>! = nil

    public init(pwd: UnsafePointer<CChar>! = nil) {
        self.pwd = pwd
    }
}

public struct ghostty_action_s: @unchecked Sendable {
    public var tag: ghostty_action_tag_e = ghostty_action_tag_e(0)
    public var action: ghostty_action_u = ghostty_action_u()

    public init(tag: ghostty_action_tag_e = ghostty_action_tag_e(0), action: ghostty_action_u = ghostty_action_u()) {
        self.tag = tag
        self.action = action
    }
}

public struct ghostty_action_scrollbar_s: @unchecked Sendable {
    public var total: UInt64 = 0
    public var offset: UInt64 = 0
    public var len: UInt64 = 0

    public init(total: UInt64 = 0, offset: UInt64 = 0, len: UInt64 = 0) {
        self.total = total
        self.offset = offset
        self.len = len
    }
}

public struct ghostty_action_search_selected_s: @unchecked Sendable {
    public var selected: Int = 0

    public init(selected: Int = 0) {
        self.selected = selected
    }
}

public struct ghostty_action_search_total_s: @unchecked Sendable {
    public var total: Int = 0

    public init(total: Int = 0) {
        self.total = total
    }
}

public struct ghostty_action_set_title_s: @unchecked Sendable {
    public var title: UnsafePointer<CChar>! = nil

    public init(title: UnsafePointer<CChar>! = nil) {
        self.title = title
    }
}

public struct ghostty_action_start_search_s: @unchecked Sendable {
    public var needle: UnsafePointer<CChar>! = nil

    public init(needle: UnsafePointer<CChar>! = nil) {
        self.needle = needle
    }
}

public struct ghostty_action_tmux_command_response_s: @unchecked Sendable {
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

public struct ghostty_action_tmux_session_changed_s: @unchecked Sendable {
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

public struct ghostty_action_tmux_pane_synced_s: @unchecked Sendable {
    public var pane_id: UInt64 = 0
    /// The viewer generation the capture belongs to.
    public var generation: UInt64 = 0

    public init(pane_id: UInt64 = 0, generation: UInt64 = 0) {
        self.pane_id = pane_id
        self.generation = generation
    }
}

/// A C union in Ghostty; here each member has its own storage.
public struct ghostty_action_u: @unchecked Sendable {
    public var cell_size: ghostty_action_cell_size_s = ghostty_action_cell_size_s()
    public var pty_resize: ghostty_action_pty_resize_s = ghostty_action_pty_resize_s()
    public var scrollbar: ghostty_action_scrollbar_s = ghostty_action_scrollbar_s()
    public var desktop_notification: ghostty_action_desktop_notification_s = ghostty_action_desktop_notification_s()
    public var set_title: ghostty_action_set_title_s = ghostty_action_set_title_s()
    public var pwd: ghostty_action_pwd_s = ghostty_action_pwd_s()
    public var mouse_shape: ghostty_action_mouse_shape_e = ghostty_action_mouse_shape_e(0)
    public var mouse_visibility: ghostty_action_mouse_visibility_e = ghostty_action_mouse_visibility_e(0)
    public var mouse_over_link: ghostty_action_mouse_over_link_s = ghostty_action_mouse_over_link_s()
    public var open_url: ghostty_action_open_url_s = ghostty_action_open_url_s()
    public var progress_report: ghostty_action_progress_report_s = ghostty_action_progress_report_s()
    public var start_search: ghostty_action_start_search_s = ghostty_action_start_search_s()
    public var search_total: ghostty_action_search_total_s = ghostty_action_search_total_s()
    public var search_selected: ghostty_action_search_selected_s = ghostty_action_search_selected_s()
    public var tmux_reconcile: UnsafeMutableRawPointer! = nil
    public var tmux_session_changed: ghostty_action_tmux_session_changed_s = ghostty_action_tmux_session_changed_s()
    public var tmux_command_response: ghostty_action_tmux_command_response_s = ghostty_action_tmux_command_response_s()
    public var tmux_pane_synced: ghostty_action_tmux_pane_synced_s = ghostty_action_tmux_pane_synced_s()

    public init(cell_size: ghostty_action_cell_size_s = ghostty_action_cell_size_s(), pty_resize: ghostty_action_pty_resize_s = ghostty_action_pty_resize_s(), scrollbar: ghostty_action_scrollbar_s = ghostty_action_scrollbar_s(), desktop_notification: ghostty_action_desktop_notification_s = ghostty_action_desktop_notification_s(), set_title: ghostty_action_set_title_s = ghostty_action_set_title_s(), pwd: ghostty_action_pwd_s = ghostty_action_pwd_s(), mouse_shape: ghostty_action_mouse_shape_e = ghostty_action_mouse_shape_e(0), mouse_visibility: ghostty_action_mouse_visibility_e = ghostty_action_mouse_visibility_e(0), mouse_over_link: ghostty_action_mouse_over_link_s = ghostty_action_mouse_over_link_s(), open_url: ghostty_action_open_url_s = ghostty_action_open_url_s(), progress_report: ghostty_action_progress_report_s = ghostty_action_progress_report_s(), start_search: ghostty_action_start_search_s = ghostty_action_start_search_s(), search_total: ghostty_action_search_total_s = ghostty_action_search_total_s(), search_selected: ghostty_action_search_selected_s = ghostty_action_search_selected_s(), tmux_reconcile: UnsafeMutableRawPointer! = nil, tmux_session_changed: ghostty_action_tmux_session_changed_s = ghostty_action_tmux_session_changed_s(), tmux_command_response: ghostty_action_tmux_command_response_s = ghostty_action_tmux_command_response_s()) {
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

public struct ghostty_clipboard_content_s: @unchecked Sendable {
    public var mime: UnsafePointer<CChar>! = nil
    public var data: UnsafePointer<CChar>! = nil

    public init(mime: UnsafePointer<CChar>! = nil, data: UnsafePointer<CChar>! = nil) {
        self.mime = mime
        self.data = data
    }
}

public struct ghostty_diagnostic_s: @unchecked Sendable {
    public var message: UnsafePointer<CChar>! = nil

    public init(message: UnsafePointer<CChar>! = nil) {
        self.message = message
    }
}

public struct ghostty_env_var_s: @unchecked Sendable {
    public var key: UnsafePointer<CChar>! = nil
    public var value: UnsafePointer<CChar>! = nil

    public init(key: UnsafePointer<CChar>! = nil, value: UnsafePointer<CChar>! = nil) {
        self.key = key
        self.value = value
    }
}

public struct ghostty_input_key_s: @unchecked Sendable {
    public var action: ghostty_input_action_e = ghostty_input_action_e(0)
    public var mods: ghostty_input_mods_e = ghostty_input_mods_e(0)
    public var consumed_mods: ghostty_input_mods_e = ghostty_input_mods_e(0)
    public var keycode: UInt32 = 0
    public var text: UnsafePointer<CChar>! = nil
    public var unshifted_codepoint: UInt32 = 0
    public var composing: Bool = false

    public init(action: ghostty_input_action_e = ghostty_input_action_e(0), mods: ghostty_input_mods_e = ghostty_input_mods_e(0), consumed_mods: ghostty_input_mods_e = ghostty_input_mods_e(0), keycode: UInt32 = 0, text: UnsafePointer<CChar>! = nil, unshifted_codepoint: UInt32 = 0, composing: Bool = false) {
        self.action = action
        self.mods = mods
        self.consumed_mods = consumed_mods
        self.keycode = keycode
        self.text = text
        self.unshifted_codepoint = unshifted_codepoint
        self.composing = composing
    }
}

public struct ghostty_platform_ios_s: @unchecked Sendable {
    public var uiview: UnsafeMutableRawPointer! = nil

    public init(uiview: UnsafeMutableRawPointer! = nil) {
        self.uiview = uiview
    }
}

/// A C union in Ghostty; here each member has its own storage.
public struct ghostty_platform_u: @unchecked Sendable {
    public var ios: ghostty_platform_ios_s = ghostty_platform_ios_s()

    public init(ios: ghostty_platform_ios_s = ghostty_platform_ios_s()) {
        self.ios = ios
    }
}

public struct ghostty_point_s: @unchecked Sendable {
    public var tag: ghostty_point_tag_e = ghostty_point_tag_e(0)
    public var coord: ghostty_point_coord_e = ghostty_point_coord_e(0)
    public var x: UInt32 = 0
    public var y: UInt32 = 0

    public init(tag: ghostty_point_tag_e = ghostty_point_tag_e(0), coord: ghostty_point_coord_e = ghostty_point_coord_e(0), x: UInt32 = 0, y: UInt32 = 0) {
        self.tag = tag
        self.coord = coord
        self.x = x
        self.y = y
    }
}

public struct ghostty_runtime_config_s: @unchecked Sendable {
    public var userdata: UnsafeMutableRawPointer! = nil
    public var supports_selection_clipboard: Bool = false
    public var wakeup_cb: ((UnsafeMutableRawPointer?) -> Void)? = nil
    public var action_cb: ((ghostty_app_t?, ghostty_target_s, ghostty_action_s) -> Bool)? = nil
    public var read_clipboard_cb: ((UnsafeMutableRawPointer?, ghostty_clipboard_e, UnsafeMutableRawPointer?) -> Bool)? = nil
    public var confirm_read_clipboard_cb: ((UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?, ghostty_clipboard_request_e) -> Void)? = nil
    public var write_clipboard_cb: ((UnsafeMutableRawPointer?, ghostty_clipboard_e, UnsafePointer<ghostty_clipboard_content_s>?, Int, Bool) -> Void)? = nil
    public var close_surface_cb: ((UnsafeMutableRawPointer?, Bool) -> Void)? = nil

    public init(userdata: UnsafeMutableRawPointer! = nil, supports_selection_clipboard: Bool = false, wakeup_cb: ((UnsafeMutableRawPointer?) -> Void)? = nil, action_cb: ((ghostty_app_t?, ghostty_target_s, ghostty_action_s) -> Bool)? = nil, read_clipboard_cb: ((UnsafeMutableRawPointer?, ghostty_clipboard_e, UnsafeMutableRawPointer?) -> Bool)? = nil, confirm_read_clipboard_cb: ((UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?, ghostty_clipboard_request_e) -> Void)? = nil, write_clipboard_cb: ((UnsafeMutableRawPointer?, ghostty_clipboard_e, UnsafePointer<ghostty_clipboard_content_s>?, Int, Bool) -> Void)? = nil, close_surface_cb: ((UnsafeMutableRawPointer?, Bool) -> Void)? = nil) {
        self.userdata = userdata
        self.supports_selection_clipboard = supports_selection_clipboard
        self.wakeup_cb = wakeup_cb
        self.action_cb = action_cb
        self.read_clipboard_cb = read_clipboard_cb
        self.confirm_read_clipboard_cb = confirm_read_clipboard_cb
        self.write_clipboard_cb = write_clipboard_cb
        self.close_surface_cb = close_surface_cb
    }
}

public struct ghostty_selection_s: @unchecked Sendable {
    public var top_left: ghostty_point_s = ghostty_point_s()
    public var bottom_right: ghostty_point_s = ghostty_point_s()
    public var rectangle: Bool = false

    public init(top_left: ghostty_point_s = ghostty_point_s(), bottom_right: ghostty_point_s = ghostty_point_s(), rectangle: Bool = false) {
        self.top_left = top_left
        self.bottom_right = bottom_right
        self.rectangle = rectangle
    }
}

public struct ghostty_surface_config_s: @unchecked Sendable {
    public var platform_tag: ghostty_platform_e = ghostty_platform_e(0)
    public var platform: ghostty_platform_u = ghostty_platform_u()
    public var userdata: UnsafeMutableRawPointer! = nil
    public var scale_factor: Double = 0
    public var font_size: Float = 0
    public var working_directory: UnsafePointer<CChar>! = nil
    public var command: UnsafePointer<CChar>! = nil
    public var env_vars: UnsafeMutablePointer<ghostty_env_var_s>! = nil
    public var env_var_count: Int = 0
    public var initial_input: UnsafePointer<CChar>! = nil
    public var wait_after_command: Bool = false
    public var use_external_io: Bool = false
    public var initially_visible: Bool = false
    public var context: ghostty_surface_context_e = ghostty_surface_context_e(0)

    public init(platform_tag: ghostty_platform_e = ghostty_platform_e(0), platform: ghostty_platform_u = ghostty_platform_u(), userdata: UnsafeMutableRawPointer! = nil, scale_factor: Double = 0, font_size: Float = 0, working_directory: UnsafePointer<CChar>! = nil, command: UnsafePointer<CChar>! = nil, env_vars: UnsafeMutablePointer<ghostty_env_var_s>! = nil, env_var_count: Int = 0, initial_input: UnsafePointer<CChar>! = nil, wait_after_command: Bool = false, use_external_io: Bool = false, initially_visible: Bool = false, context: ghostty_surface_context_e = ghostty_surface_context_e(0)) {
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

public struct ghostty_surface_size_s: @unchecked Sendable {
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

public struct ghostty_target_s: @unchecked Sendable {
    public var tag: ghostty_target_tag_e = ghostty_target_tag_e(0)
    public var target: ghostty_target_u = ghostty_target_u()

    public init(tag: ghostty_target_tag_e = ghostty_target_tag_e(0), target: ghostty_target_u = ghostty_target_u()) {
        self.tag = tag
        self.target = target
    }
}

/// A C union in Ghostty; here each member has its own storage.
public struct ghostty_target_u: @unchecked Sendable {
    public var surface: UnsafeMutableRawPointer! = nil

    public init(surface: UnsafeMutableRawPointer! = nil) {
        self.surface = surface
    }
}

public struct ghostty_text_s: @unchecked Sendable {
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

public struct ghostty_tmux_debug_snapshot_s: @unchecked Sendable {
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

public struct ghostty_tmux_layout_info_s: @unchecked Sendable {
    public var kind: ghostty_tmux_layout_kind_e = ghostty_tmux_layout_kind_e(0)
    public var width: UInt = 0
    public var height: UInt = 0
    public var x: UInt = 0
    public var y: UInt = 0
    public var pane_id: UInt = 0
    public var child_count: UInt = 0

    public init(kind: ghostty_tmux_layout_kind_e = ghostty_tmux_layout_kind_e(0), width: UInt = 0, height: UInt = 0, x: UInt = 0, y: UInt = 0, pane_id: UInt = 0, child_count: UInt = 0) {
        self.kind = kind
        self.width = width
        self.height = height
        self.x = x
        self.y = y
        self.pane_id = pane_id
        self.child_count = child_count
    }
}

public struct ghostty_tmux_op_s: @unchecked Sendable {
    public var tag: ghostty_tmux_op_tag_e = ghostty_tmux_op_tag_e(0)
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

    public init(tag: ghostty_tmux_op_tag_e = ghostty_tmux_op_tag_e(0), window_id: UInt = 0, has_window_id: Bool = false, pane_id: UInt = 0, width: UInt = 0, height: UInt = 0, viewer_terminal: UnsafeMutableRawPointer! = nil, viewer_pane: UnsafeMutableRawPointer! = nil, layout: UnsafeRawPointer! = nil, title: UnsafePointer<CChar>! = nil, title_len: UInt = 0, window_ids: UnsafePointer<UInt>! = nil, window_ids_len: UInt = 0, pane_ids: UnsafePointer<UInt>! = nil, pane_ids_len: UInt = 0, window_index: UInt = 0, zoomed_pane_id: UInt = 0, has_zoomed_pane_id: Bool = false) {
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
