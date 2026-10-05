//
//  shell-Bridging-Header.h
//  shell
//
//  Bridging header for the iOS local-shell backend. The terminal API comes
//  from the SwifttyKit Swift package (`import SwifttyKit`).
//

#ifndef shell_Bridging_Header_h
#define shell_Bridging_Header_h

// Import ios_system for the in-process local shell (every platform; on Mac
// Catalyst it backs the sandboxed build, see LocalShellBackend).
// The umbrella pulls in ios_async.h / ios_pid_allocator.h, so importing those
// directly would ask for submodules the module map doesn't declare.
#import <ios_system/ios_system.h>

// Accessor for ios_system's thread-local FILE* streams.
// Swift cannot access C __thread variables directly, so we provide inline wrappers.
static inline FILE* ios_get_thread_stdin(void) { return thread_stdin; }
static inline FILE* ios_get_thread_stdout(void) { return thread_stdout; }
static inline FILE* ios_get_thread_stderr(void) { return thread_stderr; }
static inline void ios_set_thread_stdout(FILE* f) { thread_stdout = f; }
static inline void ios_set_thread_stderr(FILE* f) { thread_stderr = f; }

#endif /* shell_Bridging_Header_h */
