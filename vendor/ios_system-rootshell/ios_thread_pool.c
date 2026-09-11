/*
 * ios_thread_pool.c
 * Thread pool implementation
 */

#include "ios_thread_pool.h"
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/sysctl.h>
#include <stdatomic.h>
#include <stdio.h>
#include <signal.h>

// Default configuration values
#define DEFAULT_MAX_QUEUE_SIZE 256
#define DEFAULT_THREAD_NAME "ios_worker"

// Thread-local storage for current work item (accessible from work functions)
static __thread ios_work_item_t* current_work_item = NULL;

// Work item states
typedef enum {
    WORK_PENDING,
    WORK_EXECUTING,
    WORK_COMPLETED,
    WORK_CANCELLED
} work_state_t;

// Work item structure (opaque to callers)
struct _ios_work_item {
    ios_work_function_t work_fn;
    void* arg;
    void* result;
    ios_work_priority_t priority;
    ios_work_complete_callback_t callback;
    void* user_data;

    _Atomic(work_state_t) state;
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    _Atomic(int) ref_count;

    struct _ios_work_item* next;  // For queue linking
};

// Thread pool structure
struct _ios_thread_pool {
    pthread_t* workers;
    int num_threads;
    int max_queue_size;
    bool enable_priorities;
    char name[64];

    // Work queue (priority-based circular buffers)
    ios_work_item_t** queue_urgent;
    ios_work_item_t** queue_high;
    ios_work_item_t** queue_normal;
    ios_work_item_t** queue_low;
    int queue_head[4];  // Per-priority head index
    int queue_tail[4];  // Per-priority tail index
    int queue_count[4]; // Per-priority item count
    int queue_capacity[4]; // Per-priority capacity

    // Synchronization
    pthread_mutex_t queue_mutex;
    pthread_cond_t work_available;
    pthread_cond_t queue_not_full;

    // Pool state
    _Atomic(bool) shutdown;
    _Atomic(bool) draining;
    _Atomic(int) active_workers;

    // Statistics
    _Atomic(uint64_t) total_submitted;
    _Atomic(uint64_t) total_completed;
    _Atomic(uint64_t) total_dropped;
};

// Forward declarations
static void* worker_thread_main(void* arg);
static ios_work_item_t* dequeue_work(ios_thread_pool_t* pool);
static int enqueue_work(ios_thread_pool_t* pool, ios_work_item_t* item);
static int get_cpu_count(void);
static ios_work_item_t* work_item_create(ios_work_function_t fn, void* arg, ios_work_priority_t priority);
static void work_item_retain(ios_work_item_t* item);
static void work_item_release_internal(ios_work_item_t* item);

/**
 * Get number of CPU cores
 */
static int get_cpu_count(void) {
    int count = 0;
    size_t size = sizeof(count);

    if (sysctlbyname("hw.ncpu", &count, &size, NULL, 0) == 0) {
        return count;
    }

    return 4;  // Fallback to reasonable default
}

/**
 * Create work item
 */
static ios_work_item_t* work_item_create(ios_work_function_t fn, void* arg, ios_work_priority_t priority) {
    ios_work_item_t* item = calloc(1, sizeof(ios_work_item_t));
    if (item == NULL) {
        return NULL;
    }

    item->work_fn = fn;
    item->arg = arg;
    item->result = NULL;
    item->priority = priority;
    item->callback = NULL;
    item->user_data = NULL;

    atomic_init(&item->state, WORK_PENDING);
    pthread_mutex_init(&item->mutex, NULL);
    pthread_cond_init(&item->cond, NULL);
    atomic_init(&item->ref_count, 1);
    item->next = NULL;

    return item;
}

/**
 * Retain work item (increment ref count)
 */
static void work_item_retain(ios_work_item_t* item) {
    if (item) {
        atomic_fetch_add(&item->ref_count, 1);
    }
}

/**
 * Release work item (internal)
 */
static void work_item_release_internal(ios_work_item_t* item) {
    if (item == NULL) {
        return;
    }

    int old_count = atomic_fetch_sub(&item->ref_count, 1);
    if (old_count == 1) {
        // Last reference, free it
        pthread_mutex_destroy(&item->mutex);
        pthread_cond_destroy(&item->cond);
        free(item);
    }
}

/**
 * Worker thread main loop
 */
static void* worker_thread_main(void* arg) {
    ios_thread_pool_t* pool = (ios_thread_pool_t*)arg;

    // Block SIGINT in worker threads - use pthread_cancel() for interruption
    // This prevents cross-thread signal delivery from corrupting blocking syscalls
    sigset_t mask;
    sigemptyset(&mask);
    sigaddset(&mask, SIGINT);
    pthread_sigmask(SIG_BLOCK, &mask, NULL);

           fprintf(stderr, "           \n", pthread_self());

    while (true) {
        ios_work_item_t* item = NULL;

        pthread_mutex_lock(&pool->queue_mutex);

        // Wait for work or shutdown
        while (!atomic_load(&pool->shutdown) &&
               (item = dequeue_work(pool)) == NULL) {
            pthread_cond_wait(&pool->work_available, &pool->queue_mutex);
        }

        if (atomic_load(&pool->shutdown) && item == NULL) {
            pthread_mutex_unlock(&pool->queue_mutex);
            break;  // Shutdown with no work
        }

        pthread_mutex_unlock(&pool->queue_mutex);

        if (item == NULL) {
            continue;
        }

        // Execute work
        atomic_fetch_add(&pool->active_workers, 1);
        atomic_store(&item->state, WORK_EXECUTING);

        // Store current work item in TLS so run_function can access it
        current_work_item = item;

        void* result = item->work_fn(item->arg);

        // Clear TLS
        current_work_item = NULL;

        atomic_fetch_sub(&pool->active_workers, 1);

        // Store result and mark complete
        pthread_mutex_lock(&item->mutex);
        item->result = result;
        atomic_store(&item->state, WORK_COMPLETED);
        pthread_cond_broadcast(&item->cond);
        pthread_mutex_unlock(&item->mutex);

        // Invoke callback if present
        if (item->callback) {
            item->callback(result, item->user_data);
        }

        atomic_fetch_add(&pool->total_completed, 1);

        // Release our reference
        work_item_release_internal(item);
    }

           fprintf(stderr, "           \n", pthread_self());
    return NULL;
}

/**
 * Dequeue work item (highest priority first)
 * Caller must hold queue_mutex
 */
static ios_work_item_t* dequeue_work(ios_thread_pool_t* pool) {
    // Check priorities from highest to lowest
    for (int p = IOS_PRIORITY_URGENT; p >= IOS_PRIORITY_LOW; p--) {
        if (pool->queue_count[p] > 0) {
            ios_work_item_t** queue;

            switch (p) {
                case IOS_PRIORITY_URGENT: queue = pool->queue_urgent; break;
                case IOS_PRIORITY_HIGH:   queue = pool->queue_high; break;
                case IOS_PRIORITY_NORMAL: queue = pool->queue_normal; break;
                case IOS_PRIORITY_LOW:    queue = pool->queue_low; break;
                default: continue;
            }

            int head = pool->queue_head[p];
            ios_work_item_t* item = queue[head];
            queue[head] = NULL;

            pool->queue_head[p] = (head + 1) % pool->queue_capacity[p];
            pool->queue_count[p]--;

            // Signal queue not full
            pthread_cond_signal(&pool->queue_not_full);

            return item;
        }
    }

    return NULL;
}

/**
 * Enqueue work item
 * Caller must hold queue_mutex
 */
static int enqueue_work(ios_thread_pool_t* pool, ios_work_item_t* item) {
    int p = item->priority;

    if (pool->queue_count[p] >= pool->queue_capacity[p]) {
        return -1;  // Queue full
    }

    ios_work_item_t** queue;
    switch (p) {
        case IOS_PRIORITY_URGENT: queue = pool->queue_urgent; break;
        case IOS_PRIORITY_HIGH:   queue = pool->queue_high; break;
        case IOS_PRIORITY_NORMAL: queue = pool->queue_normal; break;
        case IOS_PRIORITY_LOW:    queue = pool->queue_low; break;
        default: return -1;
    }

    int tail = pool->queue_tail[p];
    queue[tail] = item;
    pool->queue_tail[p] = (tail + 1) % pool->queue_capacity[p];
    pool->queue_count[p]++;

    // Retain item while in queue
    work_item_retain(item);

    // Signal workers
    pthread_cond_signal(&pool->work_available);

    return 0;
}

/**
 * Create thread pool with default configuration
 */
ios_thread_pool_t* ios_thread_pool_create_default(void) {
    ios_thread_pool_config_t config = {
        .num_threads = 0,  // Auto-detect
        .max_queue_size = DEFAULT_MAX_QUEUE_SIZE,
        .enable_priorities = true,
        .name = DEFAULT_THREAD_NAME
    };

    return ios_thread_pool_create(&config);
}

/**
 * Create thread pool with custom configuration
 */
ios_thread_pool_t* ios_thread_pool_create(const ios_thread_pool_config_t* config) {
    ios_thread_pool_t* pool = calloc(1, sizeof(ios_thread_pool_t));
    if (pool == NULL) {
        return NULL;
    }

    // Determine thread count
    if (config->num_threads <= 0) {
        pool->num_threads = get_cpu_count();
    } else {
        pool->num_threads = config->num_threads;
    }

    pool->max_queue_size = config->max_queue_size > 0 ? config->max_queue_size : DEFAULT_MAX_QUEUE_SIZE;
    pool->enable_priorities = config->enable_priorities;
    strncpy(pool->name, config->name ? config->name : DEFAULT_THREAD_NAME, sizeof(pool->name) - 1);

    // Allocate priority queues (distribute capacity)
    int urgent_cap = pool->max_queue_size / 8;    // 12.5%
    int high_cap = pool->max_queue_size / 4;      // 25%
    int normal_cap = pool->max_queue_size / 2;    // 50%
    int low_cap = pool->max_queue_size / 8;       // 12.5%

    pool->queue_capacity[IOS_PRIORITY_URGENT] = urgent_cap;
    pool->queue_capacity[IOS_PRIORITY_HIGH] = high_cap;
    pool->queue_capacity[IOS_PRIORITY_NORMAL] = normal_cap;
    pool->queue_capacity[IOS_PRIORITY_LOW] = low_cap;

    pool->queue_urgent = calloc(urgent_cap, sizeof(ios_work_item_t*));
    pool->queue_high = calloc(high_cap, sizeof(ios_work_item_t*));
    pool->queue_normal = calloc(normal_cap, sizeof(ios_work_item_t*));
    pool->queue_low = calloc(low_cap, sizeof(ios_work_item_t*));

    if (!pool->queue_urgent || !pool->queue_high || !pool->queue_normal || !pool->queue_low) {
        free(pool->queue_urgent);
        free(pool->queue_high);
        free(pool->queue_normal);
        free(pool->queue_low);
        free(pool);
        return NULL;
    }

    // Initialize queue state
    for (int i = 0; i < 4; i++) {
        pool->queue_head[i] = 0;
        pool->queue_tail[i] = 0;
        pool->queue_count[i] = 0;
    }

    // Initialize synchronization
    pthread_mutex_init(&pool->queue_mutex, NULL);
    pthread_cond_init(&pool->work_available, NULL);
    pthread_cond_init(&pool->queue_not_full, NULL);

    // Initialize state
    atomic_init(&pool->shutdown, false);
    atomic_init(&pool->draining, false);
    atomic_init(&pool->active_workers, 0);
    atomic_init(&pool->total_submitted, 0);
    atomic_init(&pool->total_completed, 0);
    atomic_init(&pool->total_dropped, 0);

    // Create worker threads
    pool->workers = calloc(pool->num_threads, sizeof(pthread_t));
    if (pool->workers == NULL) {
        free(pool->queue_urgent);
        free(pool->queue_high);
        free(pool->queue_normal);
        free(pool->queue_low);
        free(pool);
        return NULL;
    }

    for (int i = 0; i < pool->num_threads; i++) {
        if (pthread_create(&pool->workers[i], NULL, worker_thread_main, pool) != 0) {
           fprintf(stderr, "           \n", i);
            // Cleanup and return NULL
            atomic_store(&pool->shutdown, true);
            pthread_cond_broadcast(&pool->work_available);
            for (int j = 0; j < i; j++) {
                pthread_join(pool->workers[j], NULL);
            }
            free(pool->workers);
            free(pool->queue_urgent);
            free(pool->queue_high);
            free(pool->queue_normal);
            free(pool->queue_low);
            free(pool);
            return NULL;
        }
    }

           fprintf(stderr, "           \n", pool->name, pool->num_threads);

    return pool;
}

/**
 * Submit work item (blocking)
 */
ios_work_item_t* ios_thread_pool_submit(
    ios_thread_pool_t* pool,
    ios_work_function_t work_fn,
    void* arg,
    ios_work_priority_t priority)
{
    if (pool == NULL || work_fn == NULL) {
        return NULL;
    }

    if (atomic_load(&pool->shutdown)) {
        return NULL;
    }

    ios_work_item_t* item = work_item_create(work_fn, arg, priority);
    if (item == NULL) {
        return NULL;
    }

    pthread_mutex_lock(&pool->queue_mutex);

    // Wait for space in queue (backpressure)
    int p = priority;
    while (pool->queue_count[p] >= pool->queue_capacity[p] && !atomic_load(&pool->shutdown)) {
        pthread_cond_wait(&pool->queue_not_full, &pool->queue_mutex);
    }

    if (atomic_load(&pool->shutdown)) {
        pthread_mutex_unlock(&pool->queue_mutex);
        work_item_release_internal(item);
        return NULL;
    }

    if (enqueue_work(pool, item) != 0) {
        pthread_mutex_unlock(&pool->queue_mutex);
        atomic_fetch_add(&pool->total_dropped, 1);
        work_item_release_internal(item);
        return NULL;
    }

    atomic_fetch_add(&pool->total_submitted, 1);
    pthread_mutex_unlock(&pool->queue_mutex);

    return item;
}

/**
 * Try to submit work (non-blocking)
 */
ios_work_item_t* ios_thread_pool_try_submit(
    ios_thread_pool_t* pool,
    ios_work_function_t work_fn,
    void* arg,
    ios_work_priority_t priority)
{
    if (pool == NULL || work_fn == NULL) {
        return NULL;
    }

    if (atomic_load(&pool->shutdown)) {
        return NULL;
    }

    ios_work_item_t* item = work_item_create(work_fn, arg, priority);
    if (item == NULL) {
        return NULL;
    }

    pthread_mutex_lock(&pool->queue_mutex);

    if (enqueue_work(pool, item) != 0) {
        pthread_mutex_unlock(&pool->queue_mutex);
        atomic_fetch_add(&pool->total_dropped, 1);
        work_item_release_internal(item);
        return NULL;
    }

    atomic_fetch_add(&pool->total_submitted, 1);
    pthread_mutex_unlock(&pool->queue_mutex);

    return item;
}

/**
 * Submit work with callback
 */
ios_work_item_t* ios_thread_pool_submit_with_callback(
    ios_thread_pool_t* pool,
    ios_work_function_t work_fn,
    void* arg,
    ios_work_priority_t priority,
    ios_work_complete_callback_t callback,
    void* user_data)
{
    ios_work_item_t* item = ios_thread_pool_submit(pool, work_fn, arg, priority);
    if (item) {
        item->callback = callback;
        item->user_data = user_data;
    }
    return item;
}

// Cleanup handler for pthread_cancel - unlocks mutex to prevent deadlock
static void ios_work_wait_cleanup(void* arg) {
    pthread_mutex_t* mutex = (pthread_mutex_t*)arg;
    pthread_mutex_unlock(mutex);
}

/**
 * Wait for work to complete
 */
int ios_work_wait(ios_work_item_t* item, void** result) {
    if (item == NULL) {
        return -1;
    }

    pthread_mutex_lock(&item->mutex);

    // Register cleanup handler to unlock mutex if thread is cancelled
    // pthread_cond_wait is a cancellation point - without this handler,
    // the mutex would be left locked on cancellation, causing deadlock
    pthread_cleanup_push(ios_work_wait_cleanup, &item->mutex);

    while (atomic_load(&item->state) != WORK_COMPLETED &&
           atomic_load(&item->state) != WORK_CANCELLED) {
        pthread_cond_wait(&item->cond, &item->mutex);
    }

    // Pop cleanup handler (0 = don't execute it, we'll unlock manually)
    pthread_cleanup_pop(0);

    if (result) {
        *result = item->result;
    }

    work_state_t final_state = atomic_load(&item->state);
    pthread_mutex_unlock(&item->mutex);

    return final_state == WORK_COMPLETED ? 0 : -1;
}

/**
 * Check if work is complete
 */
bool ios_work_is_complete(ios_work_item_t* item) {
    if (item == NULL) {
        return false;
    }

    work_state_t state = atomic_load(&item->state);
    return (state == WORK_COMPLETED || state == WORK_CANCELLED);
}

/**
 * Get current work item (from thread-local storage)
 * Only valid when called from within a work function
 */
ios_work_item_t* ios_work_get_current(void) {
    return current_work_item;
}

/**
 * Mark work item as completed
 * Called from cleanup handlers when pthread_exit is used
 */
void ios_work_complete(ios_work_item_t* item, void* result) {
    if (item == NULL) {
        return;
    }

    pthread_mutex_lock(&item->mutex);

    // Only complete if currently executing (not already completed/cancelled)
    if (atomic_load(&item->state) == WORK_EXECUTING) {
        item->result = result;
        atomic_store(&item->state, WORK_COMPLETED);
        pthread_cond_broadcast(&item->cond);
    }

    pthread_mutex_unlock(&item->mutex);
}

/**
 * Cancel work (only if still pending)
 */
bool ios_work_cancel(ios_work_item_t* item) {
    if (item == NULL) {
        return false;
    }

    work_state_t expected = WORK_PENDING;
    if (atomic_compare_exchange_strong(&item->state, &expected, WORK_CANCELLED)) {
        pthread_mutex_lock(&item->mutex);
        pthread_cond_broadcast(&item->cond);
        pthread_mutex_unlock(&item->mutex);
        return true;
    }

    return false;
}

/**
 * Release work item
 */
void ios_work_release(ios_work_item_t* item) {
    work_item_release_internal(item);
}

/**
 * Shutdown thread pool
 */
int ios_thread_pool_shutdown(ios_thread_pool_t* pool, int timeout_ms) {
    if (pool == NULL) {
        return -1;
    }

           fprintf(stderr, "           \n", pool->name);

    atomic_store(&pool->shutdown, true);

    pthread_mutex_lock(&pool->queue_mutex);
    pthread_cond_broadcast(&pool->work_available);
    pthread_cond_broadcast(&pool->queue_not_full);
    pthread_mutex_unlock(&pool->queue_mutex);

    // Wait for workers to finish
    for (int i = 0; i < pool->num_threads; i++) {
        pthread_join(pool->workers[i], NULL);
    }

           fprintf(stderr, "           \n", pool->name);

    return 0;
}

/**
 * Destroy thread pool
 */
void ios_thread_pool_destroy(ios_thread_pool_t* pool) {
    if (pool == NULL) {
        return;
    }

    ios_thread_pool_shutdown(pool, -1);

    // Free queues
    free(pool->queue_urgent);
    free(pool->queue_high);
    free(pool->queue_normal);
    free(pool->queue_low);
    free(pool->workers);

    pthread_mutex_destroy(&pool->queue_mutex);
    pthread_cond_destroy(&pool->work_available);
    pthread_cond_destroy(&pool->queue_not_full);

    free(pool);
}

/**
 * Get pool statistics
 */
int ios_thread_pool_get_stats(ios_thread_pool_t* pool, ios_thread_pool_stats_t* stats) {
    if (pool == NULL || stats == NULL) {
        return -1;
    }

    stats->num_threads = pool->num_threads;
    stats->active_threads = atomic_load(&pool->active_workers);
    stats->idle_threads = pool->num_threads - stats->active_threads;

    pthread_mutex_lock(&pool->queue_mutex);
    stats->queue_size = pool->queue_count[0] + pool->queue_count[1] +
                        pool->queue_count[2] + pool->queue_count[3];
    pthread_mutex_unlock(&pool->queue_mutex);

    stats->max_queue_size = pool->max_queue_size;
    stats->total_submitted = atomic_load(&pool->total_submitted);
    stats->total_completed = atomic_load(&pool->total_completed);
    stats->total_dropped = atomic_load(&pool->total_dropped);

    return 0;
}

/**
 * Drain pool (wait for all work)
 */
int ios_thread_pool_drain(ios_thread_pool_t* pool, int timeout_ms) {
    if (pool == NULL) {
        return -1;
    }

    atomic_store(&pool->draining, true);

    // Wait until queue is empty and all workers idle
    while (true) {
        pthread_mutex_lock(&pool->queue_mutex);
        int total_queued = pool->queue_count[0] + pool->queue_count[1] +
                          pool->queue_count[2] + pool->queue_count[3];
        pthread_mutex_unlock(&pool->queue_mutex);

        int active = atomic_load(&pool->active_workers);

        if (total_queued == 0 && active == 0) {
            break;
        }

        usleep(10000);  // 10ms
    }

    atomic_store(&pool->draining, false);

    return 0;
}

/**
 * Resize thread pool
 */
int ios_thread_pool_resize(ios_thread_pool_t* pool, int new_size) {
    // TODO: Implement dynamic resizing
    // For now, return error (not supported)
    return -1;
}
