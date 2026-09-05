//
//  shell-Bridging-Header.h
//  shell
//
//  Bridging header for the Ghostty C API and the iOS local-shell backend.
//

#ifndef shell_Bridging_Header_h
#define shell_Bridging_Header_h

// Import the Ghostty C API
#import "ghostty.h"

// Import ios_system for local shell support (iOS/visionOS only, not Catalyst).
// The umbrella pulls in ios_async.h / ios_pid_allocator.h, so importing those
// directly would ask for submodules the module map doesn't declare.
#if !TARGET_OS_MACCATALYST
#import <ios_system/ios_system.h>
#endif

// Accessor for ios_system's thread-local FILE* streams.
// Swift cannot access C __thread variables directly, so we provide inline wrappers.
#if !TARGET_OS_MACCATALYST
static inline FILE* ios_get_thread_stdin(void) { return thread_stdin; }
static inline FILE* ios_get_thread_stdout(void) { return thread_stdout; }
static inline FILE* ios_get_thread_stderr(void) { return thread_stderr; }
static inline void ios_set_thread_stdout(FILE* f) { thread_stdout = f; }
static inline void ios_set_thread_stderr(FILE* f) { thread_stderr = f; }
#endif

// Additional iOS-specific functions
#ifdef __cplusplus
extern "C" {
#endif

/// Get the PTY master file descriptor for iOS external backend.
/// Returns -1 if not using iOS external backend or if FD is unavailable.
int ghostty_surface_pty_master_fd(void* surface);

/// Get the response pipe read FD for iOS external backend.
/// Swift should read from this FD to get terminal responses (e.g., cursor position).
/// Returns -1 if not using iOS external backend or if FD is unavailable.
int ghostty_surface_response_read_fd(void* surface);

/// Returns whether cursor key application mode (DECCKM) is active.
/// When true, arrow keys should send SS3 sequences (\x1bOA, etc.)
/// When false, arrow keys should send CSI sequences (\x1b[A, etc.)
bool ghostty_surface_cursor_key_mode(void* surface);

/// Returns whether focus event reporting (DEC mode 1004) is active.
bool ghostty_surface_focus_event_mode(void* surface);

/// Returns the total number of rows in the primary screen (including scrollback).
uintptr_t ghostty_surface_total_rows(void* surface);

/// Returns the displayed terminal's primary-screen scrollbar state.
bool ghostty_surface_display_scrollbar(void* surface, ghostty_action_scrollbar_s* out);

/// Dump the entire primary screen as ANSI-styled text. Returns NULL if empty.
/// Caller must free with ghostty_surface_free_dump.
const char* ghostty_surface_dump_primary_screen(void* surface, uintptr_t* out_len);

/// Dump the alternate screen viewport as ANSI-styled text. Returns NULL if
/// the alternate screen is not initialized or empty.
/// Caller must free with ghostty_surface_free_dump.
const char* ghostty_surface_dump_alternate_screen(void* surface, uintptr_t* out_len);

/// Returns whether the alternate screen is currently active (e.g., vim, htop).
bool ghostty_surface_is_alternate_active(void* surface);

/// Free text returned by ghostty_surface_dump_primary_screen or
/// ghostty_surface_dump_alternate_screen.
void ghostty_surface_free_dump(const char* ptr, uintptr_t len);

/// Set a render-only vertical scroll offset in pixels for smooth scrollback.
void ghostty_surface_set_smooth_scroll_offset(ghostty_surface_t surface, double y_px);

/// Scroll to an absolute row and apply a render-only smooth scroll offset.
void ghostty_surface_scroll_to_row_smooth(ghostty_surface_t surface, uintptr_t row, double y_px);

/// Reserve a bottom inset in framebuffer pixels (e.g. the iOS home-indicator
/// safe-area strip). The grid and prompt stay put; the reserved strip renders
/// blank at rest and is filled by smooth-scroll overscan rows when the viewport
/// is scrolled off the bottom. Pass 0 to clear.
void ghostty_surface_set_bottom_inset(ghostty_surface_t surface, double px);

/// Begin a touch selection-handle drag anchored at the fixed (opposite)
/// endpoint of the current selection. Returns false if there is no selection.
bool ghostty_surface_selection_handle_drag_begin(ghostty_surface_t surface, bool dragging_start);

/// Report whether each endpoint of the current selection is within the viewport.
/// Lets the touch UI show only the visible endpoint's handle for a selection
/// that spans more than one screen. Returns false if there is no selection.
bool ghostty_surface_selection_viewport_visibility(ghostty_surface_t surface, bool* start_visible, bool* end_visible);

#ifdef __cplusplus
}
#endif

#endif /* shell_Bridging_Header_h */
