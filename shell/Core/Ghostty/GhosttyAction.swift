import SwiftUI
import GhosttyKit
import Combine

extension Ghostty.Action {
    /// Wrapper for the start_search action from C API
    nonisolated struct StartSearch: Sendable {
        let needle: String?

        init(c: ghostty_action_start_search_s) {
            if let cStr = c.needle {
                self.needle = String(cString: cStr)
            } else {
                self.needle = nil
            }
        }
    }
}

// MARK: - Search State

extension Ghostty {
    /// Observable state for scrollback search
    @MainActor
    @Observable
    final class SearchState {
        var needle: String = ""
        var selected: UInt?
        var total: UInt?

        init(from startSearch: Ghostty.Action.StartSearch) {
            self.needle = startSearch.needle ?? ""
        }
    }
}

extension Ghostty.Action {
    nonisolated struct ProgressReport: Equatable, Sendable {
        enum State: Equatable, Sendable, CustomStringConvertible {
            case remove
            case set
            case error
            case indeterminate
            case pause

            init(_ c: ghostty_action_progress_report_state_e) {
                switch c {
                case GHOSTTY_PROGRESS_STATE_REMOVE:
                    self = .remove
                case GHOSTTY_PROGRESS_STATE_SET:
                    self = .set
                case GHOSTTY_PROGRESS_STATE_ERROR:
                    self = .error
                case GHOSTTY_PROGRESS_STATE_INDETERMINATE:
                    self = .indeterminate
                case GHOSTTY_PROGRESS_STATE_PAUSE:
                    self = .pause
                default:
                    self = .remove
                }
            }

            var description: String {
                switch self {
                case .remove: return "remove"
                case .set: return "set"
                case .error: return "error"
                case .indeterminate: return "indeterminate"
                case .pause: return "pause"
                }
            }
        }

        let state: State
        let progress: UInt8?

        init(c: ghostty_action_progress_report_s) {
            self.state = State(c.state)
            self.progress = c.progress >= 0 ? UInt8(c.progress) : nil
        }
    }
}
