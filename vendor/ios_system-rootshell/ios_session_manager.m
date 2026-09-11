/*
 * ios_session_manager.c
 * Thread-safe session management implementation
 */

#include "ios_session_manager.h"
#include "ios_env_manager.h"
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <unistd.h>
#include <limits.h>  // For NAME_MAX
#include <stdatomic.h>
#include <fcntl.h>
#include <errno.h>
#import <Foundation/Foundation.h>

// Hash table implementation for concurrent session storage
#define SESSION_HASH_TABLE_SIZE 256  // Power of 2 for fast modulo

typedef struct _session_entry {
    const void* session_id;              // Key
    sessionParameters* session;          // Value
    struct _session_entry* next;         // Chaining for collision resolution
} session_entry_t;

typedef struct _session_hash_table {
    session_entry_t* buckets[SESSION_HASH_TABLE_SIZE];
    pthread_rwlock_t bucket_locks[SESSION_HASH_TABLE_SIZE];  // Per-bucket locks for scalability
    _Atomic(int) total_sessions;
    _Atomic(int) total_refs;
    bool initialized;
    pthread_mutex_t init_mutex;
} session_hash_table_t;

// Global session storage
static session_hash_table_t g_session_table = {.initialized = false};

// Session reference structure (opaque to callers)
struct _ios_session_ref {
    sessionParameters* session;
    const void* session_id;
};

// Hash function for session IDs (pointer addresses)
static inline size_t hash_session_id(const void* session_id) {
    uintptr_t addr = (uintptr_t)session_id;
    // Simple but effective hash: mix high and low bits
    return (addr ^ (addr >> 16)) & (SESSION_HASH_TABLE_SIZE - 1);
}

// Forward declarations
static void session_table_init(void);
static void session_table_cleanup(void);

/**
 * Initialize the session manager subsystem
 */
void ios_session_manager_init(void) {
    static pthread_once_t init_once = PTHREAD_ONCE_INIT;
    pthread_once(&init_once, session_table_init);
}

/**
 * Internal: Initialize session hash table (called once)
 */
static void session_table_init(void) {
    if (g_session_table.initialized) {
        return;
    }

    // Initialize environment manager first
    ios_env_manager_init();

    pthread_mutex_init(&g_session_table.init_mutex, NULL);

    // Initialize all buckets and per-bucket locks
    for (int i = 0; i < SESSION_HASH_TABLE_SIZE; i++) {
        g_session_table.buckets[i] = NULL;

        pthread_rwlockattr_t attr;
        pthread_rwlockattr_init(&attr);
        // Note: pthread_rwlockattr_setkind_np is Linux-specific, not needed on macOS/iOS
        pthread_rwlock_init(&g_session_table.bucket_locks[i], &attr);
        pthread_rwlockattr_destroy(&attr);
    }

    atomic_init(&g_session_table.total_sessions, 0);
    atomic_init(&g_session_table.total_refs, 0);
    g_session_table.initialized = true;
}

/**
 * Shutdown the session manager
 */
void ios_session_manager_shutdown(void) {
    if (!g_session_table.initialized) {
        return;
    }

    pthread_mutex_lock(&g_session_table.init_mutex);

    if (!g_session_table.initialized) {
        pthread_mutex_unlock(&g_session_table.init_mutex);
        return;
    }

    // Wait for all references to be released (with timeout)
    int wait_iterations = 0;
    while (atomic_load(&g_session_table.total_refs) > 0 && wait_iterations < 1000) {
        pthread_mutex_unlock(&g_session_table.init_mutex);
        usleep(10000);  // 10ms
        pthread_mutex_lock(&g_session_table.init_mutex);
        wait_iterations++;
    }

    if (atomic_load(&g_session_table.total_refs) > 0) {
        NSLog(@"[ios_session_manager] Warning: Shutdown with %d outstanding references",
              (int)atomic_load(&g_session_table.total_refs));
    }

    // Destroy all sessions and cleanup hash table
    for (int i = 0; i < SESSION_HASH_TABLE_SIZE; i++) {
        pthread_rwlock_wrlock(&g_session_table.bucket_locks[i]);

        session_entry_t* entry = g_session_table.buckets[i];
        while (entry != NULL) {
            session_entry_t* next = entry->next;

            // Cleanup session
            if (entry->session) {
                ios_session_cleanup_params(entry->session);
                pthread_rwlock_destroy(&entry->session->rwlock);
                free(entry->session);
            }
            free(entry);

            entry = next;
        }

        g_session_table.buckets[i] = NULL;
        pthread_rwlock_unlock(&g_session_table.bucket_locks[i]);
        pthread_rwlock_destroy(&g_session_table.bucket_locks[i]);
    }

    atomic_store(&g_session_table.total_sessions, 0);
    atomic_store(&g_session_table.total_refs, 0);
    g_session_table.initialized = false;

    pthread_mutex_unlock(&g_session_table.init_mutex);
    pthread_mutex_destroy(&g_session_table.init_mutex);
}

/**
 * Internal: Lookup session in hash table (caller must hold bucket lock)
 */
static session_entry_t* session_table_lookup_locked(const void* session_id, size_t bucket_idx) {
    session_entry_t* entry = g_session_table.buckets[bucket_idx];
    while (entry != NULL) {
        if (entry->session_id == session_id) {
            return entry;
        }
        entry = entry->next;
    }
    return NULL;
}

/**
 * Internal: Insert new session into hash table (caller must hold write lock)
 */
static session_entry_t* session_table_insert_locked(const void* session_id, size_t bucket_idx) {
    session_entry_t* new_entry = malloc(sizeof(session_entry_t));
    if (!new_entry) {
        return NULL;
    }

    // Allocate and initialize session
    sessionParameters* new_session = malloc(sizeof(sessionParameters));
    if (!new_session) {
        free(new_entry);
        return NULL;
    }

    ios_session_init_params(new_session);

    // Initialize thread-safety fields
    pthread_rwlock_init(&new_session->rwlock, NULL);
    atomic_init(&new_session->ref_count, 0);
    atomic_init(&new_session->is_destroying, false);
    atomic_init(&new_session->cancel_requested, false);

    // Setup entry
    new_entry->session_id = session_id;
    new_entry->session = new_session;
    new_entry->next = g_session_table.buckets[bucket_idx];

    // Insert at head
    g_session_table.buckets[bucket_idx] = new_entry;
    atomic_fetch_add(&g_session_table.total_sessions, 1);

    return new_entry;
}

/**
 * Get or create a session for the given session ID
 */
ios_session_ref_t* ios_session_get_or_create(const void* sessionId) {
    ios_session_manager_init();

    size_t bucket_idx = hash_session_id(sessionId);
    session_entry_t* entry = NULL;

    // Try read lock first (fast path for existing sessions)
    pthread_rwlock_rdlock(&g_session_table.bucket_locks[bucket_idx]);
    entry = session_table_lookup_locked(sessionId, bucket_idx);

    if (entry != NULL && !atomic_load(&entry->session->is_destroying)) {
        // Session exists and not being destroyed - acquire reference
        atomic_fetch_add(&entry->session->ref_count, 1);
        atomic_fetch_add(&g_session_table.total_refs, 1);
        pthread_rwlock_unlock(&g_session_table.bucket_locks[bucket_idx]);

        // Create and return reference
        ios_session_ref_t* ref = malloc(sizeof(ios_session_ref_t));
        ref->session = entry->session;
        ref->session_id = sessionId;
        return ref;
    }
    pthread_rwlock_unlock(&g_session_table.bucket_locks[bucket_idx]);

    // Session doesn't exist - need write lock to create
    pthread_rwlock_wrlock(&g_session_table.bucket_locks[bucket_idx]);

    // Double-check after acquiring write lock (another thread may have created it)
    entry = session_table_lookup_locked(sessionId, bucket_idx);
    if (entry != NULL && !atomic_load(&entry->session->is_destroying)) {
        // Another thread created it
        atomic_fetch_add(&entry->session->ref_count, 1);
        atomic_fetch_add(&g_session_table.total_refs, 1);
        pthread_rwlock_unlock(&g_session_table.bucket_locks[bucket_idx]);

        ios_session_ref_t* ref = malloc(sizeof(ios_session_ref_t));
        ref->session = entry->session;
        ref->session_id = sessionId;
        return ref;
    }

    // Create new session
    entry = session_table_insert_locked(sessionId, bucket_idx);
    if (!entry) {
        pthread_rwlock_unlock(&g_session_table.bucket_locks[bucket_idx]);
        // NSLog(@"[ios_session_manager] Error: Failed to allocate session");
        return NULL;
    }

    // Acquire initial reference
    atomic_fetch_add(&entry->session->ref_count, 1);
    atomic_fetch_add(&g_session_table.total_refs, 1);
    pthread_rwlock_unlock(&g_session_table.bucket_locks[bucket_idx]);

    // Create and return reference
    ios_session_ref_t* ref = malloc(sizeof(ios_session_ref_t));
    ref->session = entry->session;
    ref->session_id = sessionId;
    return ref;
}

/**
 * Get existing session without creating new one
 */
ios_session_ref_t* ios_session_get(const void* sessionId) {
    ios_session_manager_init();

    size_t bucket_idx = hash_session_id(sessionId);

    pthread_rwlock_rdlock(&g_session_table.bucket_locks[bucket_idx]);
    session_entry_t* entry = session_table_lookup_locked(sessionId, bucket_idx);

    if (entry == NULL || atomic_load(&entry->session->is_destroying)) {
        pthread_rwlock_unlock(&g_session_table.bucket_locks[bucket_idx]);
        return NULL;
    }

    // Acquire reference
    atomic_fetch_add(&entry->session->ref_count, 1);
    atomic_fetch_add(&g_session_table.total_refs, 1);
    pthread_rwlock_unlock(&g_session_table.bucket_locks[bucket_idx]);

    ios_session_ref_t* ref = malloc(sizeof(ios_session_ref_t));
    ref->session = entry->session;
    ref->session_id = sessionId;
    return ref;
}

/**
 * Release a reference to a session
 */
void ios_session_release(ios_session_ref_t* ref) {
    if (ref == NULL) {
        return;
    }

    sessionParameters* session = ref->session;
    const void* session_id = ref->session_id;

    // Free the reference structure
    free(ref);

    // Decrement reference count
    int prev_count = atomic_fetch_sub(&session->ref_count, 1);
    atomic_fetch_sub(&g_session_table.total_refs, 1);

    assert(prev_count > 0);  // Sanity check

    // If this was the last reference and session is marked for destruction, cleanup
    if (prev_count == 1 && atomic_load(&session->is_destroying)) {
        size_t bucket_idx = hash_session_id(session_id);

        pthread_rwlock_wrlock(&g_session_table.bucket_locks[bucket_idx]);

        // Find and remove from hash table
        session_entry_t** entry_ptr = &g_session_table.buckets[bucket_idx];
        while (*entry_ptr != NULL) {
            if ((*entry_ptr)->session == session) {
                session_entry_t* to_free = *entry_ptr;
                *entry_ptr = to_free->next;

                // Cleanup session
                ios_session_cleanup_params(session);
                pthread_rwlock_destroy(&session->rwlock);
                free(session);
                free(to_free);

                atomic_fetch_sub(&g_session_table.total_sessions, 1);
                break;
            }
            entry_ptr = &(*entry_ptr)->next;
        }

        pthread_rwlock_unlock(&g_session_table.bucket_locks[bucket_idx]);
    }
}

/**
 * Get the sessionParameters pointer from a session reference
 */
sessionParameters* ios_session_get_params(ios_session_ref_t* ref) {
    assert(ref != NULL);
    return ref->session;
}

/**
 * Session locking functions
 */
void ios_session_read_lock(sessionParameters* session) {
    pthread_rwlock_rdlock(&session->rwlock);
}

void ios_session_read_unlock(sessionParameters* session) {
    pthread_rwlock_unlock(&session->rwlock);
}

void ios_session_write_lock(sessionParameters* session) {
    pthread_rwlock_wrlock(&session->rwlock);
}

void ios_session_write_unlock(sessionParameters* session) {
    pthread_rwlock_unlock(&session->rwlock);
}

/**
 * Delete a session by ID
 */
bool ios_session_delete(const void* sessionId) {
    ios_session_manager_init();

    size_t bucket_idx = hash_session_id(sessionId);

    pthread_rwlock_rdlock(&g_session_table.bucket_locks[bucket_idx]);
    session_entry_t* entry = session_table_lookup_locked(sessionId, bucket_idx);

    if (entry == NULL) {
        pthread_rwlock_unlock(&g_session_table.bucket_locks[bucket_idx]);
        return false;
    }

    // Mark session for destruction
    atomic_store(&entry->session->is_destroying, true);

    // If no references, delete immediately; otherwise wait for last release
    bool has_refs = (atomic_load(&entry->session->ref_count) > 0);
    pthread_rwlock_unlock(&g_session_table.bucket_locks[bucket_idx]);

    if (!has_refs) {
        // No references, safe to delete now
        pthread_rwlock_wrlock(&g_session_table.bucket_locks[bucket_idx]);

        session_entry_t** entry_ptr = &g_session_table.buckets[bucket_idx];
        while (*entry_ptr != NULL) {
            if ((*entry_ptr)->session_id == sessionId) {
                session_entry_t* to_free = *entry_ptr;
                *entry_ptr = to_free->next;

                ios_session_cleanup_params(to_free->session);
                pthread_rwlock_destroy(&to_free->session->rwlock);
                free(to_free->session);
                free(to_free);

                atomic_fetch_sub(&g_session_table.total_sessions, 1);
                break;
            }
            entry_ptr = &(*entry_ptr)->next;
        }

        pthread_rwlock_unlock(&g_session_table.bucket_locks[bucket_idx]);
    }

    return true;
}

/**
 * Get session manager statistics
 */
void ios_session_get_stats(int* total_sessions, int* total_refs) {
    if (total_sessions) {
        *total_sessions = atomic_load(&g_session_table.total_sessions);
    }
    if (total_refs) {
        *total_refs = atomic_load(&g_session_table.total_refs);
    }
}

/**
 * Initialize session parameters with default values
 */
void ios_session_init_params(sessionParameters* sp) {
    NSFileManager *fileManager = [[NSFileManager alloc] init];
    sp->isMainThread = true;
    sp->current_command_root_thread = 0;
    sp->lastThreadId = 0;
    sp->mainThreadId = 0;
    sp->stdin = stdin;
    sp->stdout = stdout;
    sp->stderr = stderr;
    sp->tty = stdin;  // Match original behavior
    sp->context = NULL;
    sp->global_errno = 0;

    // Allocate command name array (10 slots initially)
    sp->numCommandsAllocated = 10;
    sp->numCommand = 0;
    sp->commandName = malloc(sizeof(char*) * sp->numCommandsAllocated);
    if (sp->commandName != NULL) {
        for (int i = 0; i < sp->numCommandsAllocated; i++) {
            sp->commandName[i] = malloc(sizeof(char) * NAME_MAX);
            if (sp->commandName[i] != NULL) {
                sp->commandName[i][0] = '\0';
            }
        }
    }

    strcpy(sp->columns, "80");
    strcpy(sp->lines, "80");  // Match original (was "80" not "25")
    sp->activePager = false;
    sp->cancel_pipe_read_fd = -1;
    sp->cancel_pipe_write_fd = -1;

    int cancel_pipe[2];
    if (pipe(cancel_pipe) == 0) {
        sp->cancel_pipe_read_fd = cancel_pipe[0];
        sp->cancel_pipe_write_fd = cancel_pipe[1];

        int flags = fcntl(sp->cancel_pipe_read_fd, F_GETFL, 0);
        if (flags >= 0) {
            fcntl(sp->cancel_pipe_read_fd, F_SETFL, flags | O_NONBLOCK);
        }
        flags = fcntl(sp->cancel_pipe_write_fd, F_GETFL, 0);
        if (flags >= 0) {
            fcntl(sp->cancel_pipe_write_fd, F_SETFL, flags | O_NONBLOCK);
        }
    }

    // Initialize directories
    NSString* currentPath = [fileManager currentDirectoryPath];
    strncpy(sp->currentDir, [currentPath UTF8String], MAXPATHLEN - 1);
    sp->currentDir[MAXPATHLEN - 1] = '\0';
    strncpy(sp->previousDirectory, sp->currentDir, MAXPATHLEN);
    strcpy(sp->localMiniRoot, "");
}

/**
 * Cleanup session parameters
 */
void ios_session_cleanup_params(sessionParameters* sp) {
    // Free command name array if allocated
    if (sp->commandName != NULL) {
        for (int i = 0; i < sp->numCommandsAllocated; i++) {
            if (sp->commandName[i] != NULL) {
                free(sp->commandName[i]);
            }
        }
        free(sp->commandName);
        sp->commandName = NULL;
    }

    // Close file handles if they're not standard streams
    if (sp->stdin != NULL && sp->stdin != stdin) {
        fclose(sp->stdin);
    }
    if (sp->stdout != NULL && sp->stdout != stdout) {
        fclose(sp->stdout);
    }
    if (sp->stderr != NULL && sp->stderr != stderr) {
        fclose(sp->stderr);
    }
    if (sp->tty != NULL && sp->tty != stdin) {
        fclose(sp->tty);
    }

    if (sp->cancel_pipe_read_fd >= 0) {
        close(sp->cancel_pipe_read_fd);
        sp->cancel_pipe_read_fd = -1;
    }
    if (sp->cancel_pipe_write_fd >= 0) {
        close(sp->cancel_pipe_write_fd);
        sp->cancel_pipe_write_fd = -1;
    }
}

int ios_session_request_cancel(sessionParameters* session) {
    if (session == NULL) {
        return -1;
    }

    bool already_cancelled = atomic_exchange(&session->cancel_requested, true);
    if (!already_cancelled && session->cancel_pipe_write_fd >= 0) {
        char wake_byte = '!';
        ssize_t written;
        do {
            written = write(session->cancel_pipe_write_fd, &wake_byte, 1);
        } while (written < 0 && errno == EINTR);
    }

    return 0;
}

void ios_session_clear_cancel(sessionParameters* session) {
    if (session == NULL) {
        return;
    }

    atomic_store(&session->cancel_requested, false);

    if (session->cancel_pipe_read_fd < 0) {
        return;
    }

    char buffer[32];
    while (true) {
        ssize_t count = read(session->cancel_pipe_read_fd, buffer, sizeof(buffer));
        if (count > 0) {
            continue;
        }
        if (count < 0 && errno == EINTR) {
            continue;
        }
        break;
    }
}

int ios_session_cancel_fd(sessionParameters* session) {
    if (session == NULL) {
        return -1;
    }
    return session->cancel_pipe_read_fd;
}
