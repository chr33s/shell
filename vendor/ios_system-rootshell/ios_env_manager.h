/*
 * ios_env_manager.h
 * Thread-safe per-thread environment variable management with copy-on-write semantics
 *
 * Each pthread has its own environment that is inherited (copied) from the parent thread.
 * Modifications (setenv/unsetenv) are thread-local and don't affect other threads.
 */

#ifndef IOS_ENV_MANAGER_H
#define IOS_ENV_MANAGER_H

#include <pthread.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Initialize the environment manager subsystem
 * Must be called before any other environment manager functions
 * Thread-safe: Can be called multiple times (idempotent)
 */
void ios_env_manager_init(void);

/**
 * Shutdown the environment manager and cleanup all resources
 * Thread-safe: Can be called multiple times (idempotent)
 */
void ios_env_manager_shutdown(void);

/**
 * Initialize environment for current thread
 * Copies parent thread's environment (copy-on-write)
 * If no parent, initializes from process environment
 *
 * @param parent_tid Parent thread ID (0 for no parent, use process environment)
 *
 * Must be called once per thread before any environment operations
 * Thread-safe: Each thread calls for itself
 */
void ios_env_init_thread(pthread_t parent_tid);

/**
 * Cleanup environment for current thread
 * Frees all environment variables and storage
 *
 * Must be called when thread terminates
 * Thread-safe: Each thread calls for itself
 */
void ios_env_cleanup_thread(void);

/**
 * Get environment variable value for current thread
 * Thread-safe read operation
 *
 * @param name Variable name
 * @return Variable value or NULL if not found
 *
 * The returned pointer is valid until the variable is modified or thread exits
 */
char* ios_env_getenv(const char* name);

/**
 * Set environment variable for current thread
 * Thread-safe write operation (only affects current thread)
 *
 * @param name Variable name
 * @param value Variable value
 * @param overwrite If 0, don't overwrite existing variable
 * @return 0 on success, -1 on error (sets errno)
 */
int ios_env_setenv(const char* name, const char* value, int overwrite);

/**
 * Unset environment variable for current thread
 * Thread-safe write operation (only affects current thread)
 *
 * @param name Variable name
 * @return 0 on success, -1 on error (sets errno)
 */
int ios_env_unsetenv(const char* name);

/**
 * Get entire environment array for current thread
 * Used for execve-style functions
 *
 * @return NULL-terminated array of "NAME=VALUE" strings
 *
 * The returned array is valid until any environment modification or thread exit
 * Do not modify or free the returned array
 */
char** ios_env_get_environ(void);

/**
 * Copy environment from one thread to another
 * Used when forking or creating child processes
 *
 * @param source_tid Source thread ID
 * @param dest_tid Destination thread ID
 * @return 0 on success, -1 on error
 */
int ios_env_copy_from_thread(pthread_t source_tid, pthread_t dest_tid);

/**
 * Get statistics about environment manager state
 * For debugging and monitoring
 *
 * @param total_threads Output: total number of threads with environments
 * @param total_vars Output: total number of environment variables across all threads
 */
void ios_env_get_stats(int* total_threads, int* total_vars);

#ifdef __cplusplus
}
#endif

#endif /* IOS_ENV_MANAGER_H */
