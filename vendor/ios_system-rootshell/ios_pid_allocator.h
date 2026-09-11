/*
 * ios_pid_allocator.h
 * Lock-free dynamic PID allocator for ios_system
 *
 * Replaces fixed-size IOS_MAX_THREADS array with dynamic lock-free allocator.
 * Provides efficient allocation/deallocation without global locks.
 */

#ifndef IOS_PID_ALLOCATOR_H
#define IOS_PID_ALLOCATOR_H

#include <pthread.h>
#include <stdbool.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

// PID context structure (opaque to callers)
typedef struct _ios_pid_context ios_pid_context_t;

// PID allocation/deallocation
/**
 * Allocate a new PID and context
 *
 * Returns a new PID context with unique ID. The context stores:
 * - pthread_t thread ID
 * - Environment variables (migrated from old per-PID arrays)
 * - Previous directory path
 * - Parent PID
 *
 * @return New PID context or NULL on error
 */
ios_pid_context_t* ios_pid_allocate(void);

/**
 * Release a PID and its context
 *
 * Frees the PID for reuse and cleans up associated resources.
 * Thread-safe and lock-free.
 *
 * @param ctx PID context to release
 */
void ios_pid_release(ios_pid_context_t* ctx);

// PID context accessors
/**
 * Get PID number from context
 *
 * @param ctx PID context
 * @return PID number (positive integer)
 */
pid_t ios_pid_get_id(ios_pid_context_t* ctx);

/**
 * Set thread ID for PID context
 *
 * @param ctx PID context
 * @param thread Thread ID to associate with this PID
 */
void ios_pid_set_thread(ios_pid_context_t* ctx, pthread_t thread);

/**
 * Get thread ID from PID context
 *
 * @param ctx PID context
 * @return Thread ID or 0 if not set
 */
pthread_t ios_pid_get_thread(ios_pid_context_t* ctx);

/**
 * Lookup PID context by PID number
 *
 * @param pid PID number to lookup
 * @return PID context or NULL if not found
 */
ios_pid_context_t* ios_pid_lookup(pid_t pid);

/**
 * Lookup PID context by thread ID
 *
 * @param thread Thread ID to lookup
 * @return PID context or NULL if not found
 */
ios_pid_context_t* ios_pid_lookup_by_thread(pthread_t thread);

// Environment management (migrated from libc_replacement.c)
/**
 * Get environment array for PID context
 *
 * @param ctx PID context
 * @return Environment variable array (NULL-terminated)
 */
char** ios_pid_get_environment(ios_pid_context_t* ctx);

/**
 * Set environment array for PID context
 *
 * @param ctx PID context
 * @param env Environment variable array
 */
void ios_pid_set_environment(ios_pid_context_t* ctx, char** env);

/**
 * Get number of environment variables set
 *
 * @param ctx PID context
 * @return Number of variables
 */
int ios_pid_get_env_count(ios_pid_context_t* ctx);

/**
 * Set number of environment variables
 *
 * @param ctx PID context
 * @param count Number of variables
 */
void ios_pid_set_env_count(ios_pid_context_t* ctx, int count);

// Directory management
/**
 * Get previous directory for PID context
 *
 * @param ctx PID context
 * @return Previous directory path
 */
const char* ios_pid_get_previous_dir(ios_pid_context_t* ctx);

/**
 * Set previous directory for PID context
 *
 * @param ctx PID context
 * @param dir Directory path
 */
void ios_pid_set_previous_dir(ios_pid_context_t* ctx, const char* dir);

/**
 * Get parent PID
 *
 * @param ctx PID context
 * @return Parent PID number
 */
pid_t ios_pid_get_parent(ios_pid_context_t* ctx);

/**
 * Set parent PID
 *
 * @param ctx PID context
 * @param parent_pid Parent PID number
 */
void ios_pid_set_parent(ios_pid_context_t* ctx, pid_t parent_pid);

// Initialization and statistics
/**
 * Initialize PID allocator subsystem
 *
 * Must be called before any other PID allocator functions.
 * Safe to call multiple times (uses pthread_once).
 */
void ios_pid_allocator_init(void);

/**
 * Shutdown PID allocator subsystem
 *
 * Releases all PIDs and frees memory.
 * Should only be called at application shutdown.
 */
void ios_pid_allocator_shutdown(void);

/**
 * Get allocator statistics
 *
 * @param total_allocated Output: total PIDs ever allocated
 * @param currently_active Output: PIDs currently in use
 * @param free_list_size Output: PIDs available for reuse
 */
void ios_pid_get_stats(int* total_allocated, int* currently_active, int* free_list_size);

// Cleanup synchronization (replaces cleanup_counter spinlock)
/**
 * Begin cleanup for PID
 *
 * Increments cleanup counter to prevent new PIDs from being allocated
 * while cleanup is in progress. Use with ios_pid_end_cleanup().
 * Replaces: cleanup_counter++
 */
void ios_pid_begin_cleanup(void);

/**
 * End cleanup for PID
 *
 * Decrements cleanup counter and signals any threads waiting for cleanup
 * to complete. Use after ios_pid_begin_cleanup().
 * Replaces: cleanup_counter--
 */
void ios_pid_end_cleanup(void);

/**
 * Wait for cleanup to complete
 *
 * Blocks until all ongoing cleanups complete (cleanup counter reaches 0).
 * Replaces: while (cleanup_counter > 0) { }
 * Much more efficient than spinlock - uses condition variable.
 */
void ios_pid_wait_for_cleanup(void);

#ifdef __cplusplus
}
#endif

#endif /* IOS_PID_ALLOCATOR_H */
