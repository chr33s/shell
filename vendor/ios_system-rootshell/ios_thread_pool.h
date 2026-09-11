/*
 * ios_thread_pool.h
 * Thread pool infrastructure for ios_system command execution
 *
 * Provides bounded thread pool with work queue, priority scheduling,
 * and graceful shutdown. Replaces per-command pthread_create() to
 * reduce overhead and enable better resource management.
 */

#ifndef IOS_THREAD_POOL_H
#define IOS_THREAD_POOL_H

#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Forward declarations
typedef struct _ios_thread_pool ios_thread_pool_t;
typedef struct _ios_work_item ios_work_item_t;

// Work item priority levels
typedef enum {
    IOS_PRIORITY_LOW = 0,      // Background commands
    IOS_PRIORITY_NORMAL = 1,   // Regular commands
    IOS_PRIORITY_HIGH = 2,     // Interactive commands
    IOS_PRIORITY_URGENT = 3    // Urgent/system commands
} ios_work_priority_t;

// Work item completion callback
typedef void (*ios_work_complete_callback_t)(void* result, void* user_data);

// Work function signature (same as pthread entry point)
typedef void* (*ios_work_function_t)(void* arg);

/**
 * Thread pool configuration
 */
typedef struct {
    int num_threads;           // Number of worker threads (0 = auto-detect)
    int max_queue_size;        // Maximum pending work items (0 = unlimited)
    bool enable_priorities;    // Enable priority-based scheduling
    const char* name;          // Pool name (for logging/debugging)
} ios_thread_pool_config_t;

/**
 * Thread pool statistics
 */
typedef struct {
    int num_threads;           // Total worker threads
    int active_threads;        // Threads currently executing work
    int idle_threads;          // Threads waiting for work
    int queue_size;            // Current queue depth
    int max_queue_size;        // Maximum queue capacity
    uint64_t total_submitted;  // Total work items submitted
    uint64_t total_completed;  // Total work items completed
    uint64_t total_dropped;    // Work items dropped (queue full)
} ios_thread_pool_stats_t;

/**
 * Create thread pool with default configuration
 * Auto-detects optimal thread count based on CPU cores
 *
 * @return Thread pool handle or NULL on error
 *
 * Thread-safe: Can be called from any thread
 */
ios_thread_pool_t* ios_thread_pool_create_default(void);

/**
 * Create thread pool with custom configuration
 *
 * @param config Pool configuration
 * @return Thread pool handle or NULL on error
 *
 * Thread-safe: Can be called from any thread
 */
ios_thread_pool_t* ios_thread_pool_create(const ios_thread_pool_config_t* config);

/**
 * Submit work item to thread pool (blocking if queue full)
 *
 * @param pool Thread pool
 * @param work_fn Work function to execute
 * @param arg Argument passed to work function
 * @param priority Work priority
 * @return Work item handle or NULL on error
 *
 * Thread-safe: Multiple threads can submit concurrently
 * Blocks if queue is full (backpressure)
 */
ios_work_item_t* ios_thread_pool_submit(
    ios_thread_pool_t* pool,
    ios_work_function_t work_fn,
    void* arg,
    ios_work_priority_t priority
);

/**
 * Try to submit work item (non-blocking)
 * Returns immediately if queue is full
 *
 * @param pool Thread pool
 * @param work_fn Work function to execute
 * @param arg Argument passed to work function
 * @param priority Work priority
 * @return Work item handle or NULL if queue full
 *
 * Thread-safe: Multiple threads can submit concurrently
 */
ios_work_item_t* ios_thread_pool_try_submit(
    ios_thread_pool_t* pool,
    ios_work_function_t work_fn,
    void* arg,
    ios_work_priority_t priority
);

/**
 * Submit work with completion callback
 * Callback is invoked when work completes (on worker thread)
 *
 * @param pool Thread pool
 * @param work_fn Work function to execute
 * @param arg Argument passed to work function
 * @param priority Work priority
 * @param callback Completion callback
 * @param user_data User data passed to callback
 * @return Work item handle or NULL on error
 */
ios_work_item_t* ios_thread_pool_submit_with_callback(
    ios_thread_pool_t* pool,
    ios_work_function_t work_fn,
    void* arg,
    ios_work_priority_t priority,
    ios_work_complete_callback_t callback,
    void* user_data
);

/**
 * Wait for work item to complete
 *
 * @param item Work item handle
 * @param result Output: result returned by work function (can be NULL)
 * @return 0 on success, -1 on error
 *
 * Thread-safe: Can be called from any thread
 * Blocks until work completes
 */
int ios_work_wait(ios_work_item_t* item, void** result);

/**
 * Check if work item has completed (non-blocking)
 *
 * @param item Work item handle
 * @return true if completed, false otherwise
 */
bool ios_work_is_complete(ios_work_item_t* item);

/**
 * Cancel pending work item
 * Only works if item is still in queue (not yet started)
 *
 * @param item Work item handle
 * @return true if cancelled, false if already executing or completed
 */
bool ios_work_cancel(ios_work_item_t* item);

/**
 * Release work item handle
 * Must be called after ios_work_wait() or when no longer needed
 *
 * @param item Work item handle
 */
void ios_work_release(ios_work_item_t* item);

/**
 * Get current work item
 * Only valid when called from within a work function
 *
 * @return Current work item or NULL if not in work context
 */
ios_work_item_t* ios_work_get_current(void);

/**
 * Mark work item as completed
 * Internal use only - called from cleanup handlers when pthread_exit is used
 *
 * @param item Work item handle
 * @param result Result to store
 */
void ios_work_complete(ios_work_item_t* item, void* result);

/**
 * Wait for all pending work to complete
 * Blocks new submissions while draining
 *
 * @param pool Thread pool
 * @param timeout_ms Timeout in milliseconds (-1 = infinite)
 * @return 0 if all work completed, -1 on timeout
 */
int ios_thread_pool_drain(ios_thread_pool_t* pool, int timeout_ms);

/**
 * Shutdown thread pool gracefully
 * Completes all pending work before terminating workers
 *
 * @param pool Thread pool
 * @param timeout_ms Timeout in milliseconds (-1 = infinite)
 * @return 0 on clean shutdown, -1 on timeout
 *
 * After timeout, forcibly terminates workers and drops pending work
 */
int ios_thread_pool_shutdown(ios_thread_pool_t* pool, int timeout_ms);

/**
 * Destroy thread pool (immediate)
 * Stops all workers immediately, drops pending work
 * Only use for emergency cleanup
 *
 * @param pool Thread pool
 */
void ios_thread_pool_destroy(ios_thread_pool_t* pool);

/**
 * Get thread pool statistics
 *
 * @param pool Thread pool
 * @param stats Output: statistics structure
 * @return 0 on success, -1 on error
 */
int ios_thread_pool_get_stats(ios_thread_pool_t* pool, ios_thread_pool_stats_t* stats);

/**
 * Adjust thread pool size dynamically
 * Grows or shrinks worker thread count
 *
 * @param pool Thread pool
 * @param new_size New thread count
 * @return 0 on success, -1 on error
 *
 * Note: Shrinking waits for excess workers to finish current work
 */
int ios_thread_pool_resize(ios_thread_pool_t* pool, int new_size);

#ifdef __cplusplus
}
#endif

#endif /* IOS_THREAD_POOL_H */
