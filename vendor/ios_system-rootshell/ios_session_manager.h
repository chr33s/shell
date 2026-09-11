/*
 * ios_session_manager.h
 * Thread-safe session management for ios_system
 *
 * Provides concurrent session storage with reference counting,
 * fine-grained locking, and copy-on-write semantics.
 */

#ifndef IOS_SESSION_MANAGER_H
#define IOS_SESSION_MANAGER_H

#include <pthread.h>
#include <stdio.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <sys/param.h>

#ifdef __cplusplus
extern "C" {
#endif

// Forward declarations
typedef struct _sessionParameters sessionParameters;
typedef struct _ios_session_ref ios_session_ref_t;

/**
 * Session parameters structure with thread-safety additions
 */
typedef struct _sessionParameters {
    // Original fields
    bool isMainThread;
    char currentDir[MAXPATHLEN];
    char previousDirectory[MAXPATHLEN];
    char localMiniRoot[MAXPATHLEN];
    pthread_t current_command_root_thread;
    pthread_t lastThreadId;
    pthread_t mainThreadId;
    FILE* stdin;
    FILE* stdout;
    FILE* stderr;
    FILE* tty;
    const void* context;
    int global_errno;
    int numCommandsAllocated;
    int numCommand;
    char** commandName;
    char columns[5];
    char lines[5];
    bool activePager;

    // Cooperative cancellation
    _Atomic(bool) cancel_requested; // Set by ios_kill; commands check this to exit
    int cancel_pipe_read_fd;        // Read end for cooperative cancellation wakeups
    int cancel_pipe_write_fd;       // Write end for cooperative cancellation wakeups

    // New thread-safety fields
    pthread_rwlock_t rwlock;       // Fine-grained per-session lock
    _Atomic(int) ref_count;        // Reference counting for safe deletion
    _Atomic(bool) is_destroying;   // Flag to prevent new references during cleanup
} sessionParameters;

/**
 * Initialize the session manager subsystem
 * Must be called before any other session manager functions
 * Thread-safe: Can be called multiple times (idempotent)
 */
void ios_session_manager_init(void);

/**
 * Shutdown the session manager and cleanup all resources
 * Blocks until all sessions are released (ref_count == 0)
 * Thread-safe: Can be called multiple times (idempotent)
 */
void ios_session_manager_shutdown(void);

/**
 * Get or create a session for the given session ID
 * Increments reference count on the session
 *
 * @param sessionId Unique identifier for the session
 * @return Session reference (never NULL, creates new session if not found)
 *
 * Thread-safe: Multiple threads can call concurrently
 * Caller must call ios_session_release() when done
 */
ios_session_ref_t* ios_session_get_or_create(const void* sessionId);

/**
 * Get existing session without creating new one
 * Increments reference count on the session
 *
 * @param sessionId Unique identifier for the session
 * @return Session reference or NULL if not found
 *
 * Thread-safe: Multiple threads can call concurrently
 * Caller must call ios_session_release() when done if non-NULL
 */
ios_session_ref_t* ios_session_get(const void* sessionId);

/**
 * Release a reference to a session
 * Decrements reference count; destroys session when count reaches zero
 *
 * @param ref Session reference to release (can be NULL)
 *
 * Thread-safe: Multiple threads can release concurrently
 */
void ios_session_release(ios_session_ref_t* ref);

/**
 * Get the sessionParameters pointer from a session reference
 * The returned pointer is valid as long as the reference is held
 *
 * @param ref Session reference
 * @return Pointer to sessionParameters (never NULL if ref is valid)
 *
 * Thread-safe: Can be called concurrently
 */
sessionParameters* ios_session_get_params(ios_session_ref_t* ref);

/**
 * Acquire read lock on session
 * Multiple readers can hold lock simultaneously
 *
 * @param session Session to lock
 *
 * Usage:
 *   ios_session_read_lock(session);
 *   // Read session fields
 *   ios_session_read_unlock(session);
 */
void ios_session_read_lock(sessionParameters* session);

/**
 * Release read lock on session
 *
 * @param session Session to unlock
 */
void ios_session_read_unlock(sessionParameters* session);

/**
 * Acquire write lock on session
 * Exclusive access - blocks all readers and other writers
 *
 * @param session Session to lock
 *
 * Usage:
 *   ios_session_write_lock(session);
 *   // Modify session fields
 *   ios_session_write_unlock(session);
 */
void ios_session_write_lock(sessionParameters* session);

/**
 * Release write lock on session
 *
 * @param session Session to unlock
 */
void ios_session_write_unlock(sessionParameters* session);

/**
 * Delete a session by ID
 * Marks session for destruction; actual deletion happens when ref_count reaches 0
 *
 * @param sessionId Session to delete
 * @return true if session was found and marked for deletion, false otherwise
 *
 * Thread-safe: Multiple threads can call concurrently
 */
bool ios_session_delete(const void* sessionId);

/**
 * Get statistics about session manager state
 * For debugging and monitoring
 *
 * @param total_sessions Output: total number of active sessions
 * @param total_refs Output: total number of outstanding references
 */
void ios_session_get_stats(int* total_sessions, int* total_refs);

/**
 * Initialize session parameters with default values
 * Called automatically by ios_session_get_or_create()
 *
 * @param sp Session parameters to initialize
 */
void ios_session_init_params(sessionParameters* sp);

/**
 * Cleanup session parameters
 * Called automatically when session is destroyed
 *
 * @param sp Session parameters to cleanup
 */
void ios_session_cleanup_params(sessionParameters* sp);

/**
 * Request cooperative cancellation for a session.
 * Safe to call multiple times; writes a wake byte only on the first transition.
 *
 * @param session Session to cancel
 * @return 0 on success, -1 on error
 */
int ios_session_request_cancel(sessionParameters* session);

/**
 * Clear cooperative cancellation state for a session and drain wake bytes.
 *
 * @param session Session to reset
 */
void ios_session_clear_cancel(sessionParameters* session);

/**
 * Get the read fd for the session cancellation pipe.
 *
 * @param session Session to query
 * @return Cancellation read fd, or -1 if unavailable
 */
int ios_session_cancel_fd(sessionParameters* session);

#ifdef __cplusplus
}
#endif

#endif /* IOS_SESSION_MANAGER_H */
