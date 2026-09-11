/*
 * ios_pid_allocator.c
 * Lock-free dynamic PID allocator implementation
 */

#include "ios_pid_allocator.h"
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include <stdio.h>
#include <sys/param.h>  // For MAXPATHLEN
#include <assert.h>

// Initial PID value (start at 100 to avoid conflicts with system PIDs)
#define INITIAL_PID 100

// Hash table size for PID lookup
#define PID_HASH_TABLE_SIZE 256

// PID context structure
struct _ios_pid_context {
    pid_t pid;                              // PID number
    _Atomic(pthread_t) thread_id;           // Thread ID (atomic for lock-free access)

    // Environment management (migrated from libc_replacement.c)
    char** environment;                     // Environment variables array
    char** copy_environment;                // Copy for makeGlobal/makeLocal
    int num_variables_set;                  // Number of variables in environment

    // Directory tracking
    char previous_directory[MAXPATHLEN];    // Previous working directory
    pid_t parent_pid;                       // Parent process PID

    // Free-list linkage
    struct _ios_pid_context* next_free;     // Next in free list (when deallocated)

    // Hash table linkage
    struct _ios_pid_context* next_in_bucket; // Next in hash bucket (when allocated)

    // Reference counting for safe cleanup
    _Atomic(int) ref_count;                 // Reference count
    _Atomic(bool) is_allocated;             // True if currently allocated
};

// Hash table for active PIDs
typedef struct {
    ios_pid_context_t* buckets[PID_HASH_TABLE_SIZE];
    pthread_rwlock_t bucket_locks[PID_HASH_TABLE_SIZE];
} pid_hash_table_t;

// Free-list head (lock-free stack)
typedef struct {
    _Atomic(ios_pid_context_t*) head;       // Head of free list
    _Atomic(int) size;                      // Number of items in free list
} pid_free_list_t;

// Global allocator state
static struct {
    pid_hash_table_t active_pids;           // Hash table of active PIDs
    pid_free_list_t free_list;              // Free list for reuse
    _Atomic(pid_t) next_pid;                // Next PID to allocate
    _Atomic(int) total_allocated;           // Total PIDs ever allocated
    _Atomic(int) currently_active;          // PIDs currently in use
    pthread_once_t init_once;               // One-time initialization
    bool initialized;                       // Initialization flag

    // Cleanup synchronization (replaces cleanup_counter spinlock)
    pthread_mutex_t cleanup_mutex;          // Protects cleanup_counter
    pthread_cond_t cleanup_done;            // Signaled when cleanup_counter reaches 0
    _Atomic(int) cleanup_counter;           // Number of ongoing cleanups
} g_pid_allocator = {
    .init_once = PTHREAD_ONCE_INIT,
    .initialized = false
};

// Forward declarations
static void pid_allocator_init_once(void);
static inline size_t hash_pid(pid_t pid);
static ios_pid_context_t* pid_allocator_create_context(pid_t pid);
static void pid_allocator_insert_active(ios_pid_context_t* ctx);
static void pid_allocator_remove_active(ios_pid_context_t* ctx);

/**
 * Hash function for PID numbers
 */
static inline size_t hash_pid(pid_t pid) {
    return ((unsigned int)pid) % PID_HASH_TABLE_SIZE;
}

/**
 * One-time initialization
 */
static void pid_allocator_init_once(void) {
    if (g_pid_allocator.initialized) {
        return;
    }

    // Initialize hash table
    for (int i = 0; i < PID_HASH_TABLE_SIZE; i++) {
        g_pid_allocator.active_pids.buckets[i] = NULL;
        pthread_rwlock_init(&g_pid_allocator.active_pids.bucket_locks[i], NULL);
    }

    // Initialize free list
    atomic_init(&g_pid_allocator.free_list.head, NULL);
    atomic_init(&g_pid_allocator.free_list.size, 0);

    // Initialize counters
    atomic_init(&g_pid_allocator.next_pid, INITIAL_PID);
    atomic_init(&g_pid_allocator.total_allocated, 0);
    atomic_init(&g_pid_allocator.currently_active, 0);

    // Initialize cleanup synchronization
    pthread_mutex_init(&g_pid_allocator.cleanup_mutex, NULL);
    pthread_cond_init(&g_pid_allocator.cleanup_done, NULL);
    atomic_init(&g_pid_allocator.cleanup_counter, 0);

    g_pid_allocator.initialized = true;
    fprintf(stderr, "[ios_pid_allocator] Initialized (starting PID=%d)\n", INITIAL_PID);
}

/**
 * Initialize PID allocator subsystem
 */
void ios_pid_allocator_init(void) {
    pthread_once(&g_pid_allocator.init_once, pid_allocator_init_once);
}

/**
 * Create new PID context structure
 */
static ios_pid_context_t* pid_allocator_create_context(pid_t pid) {
    ios_pid_context_t* ctx = calloc(1, sizeof(ios_pid_context_t));
    if (!ctx) {
        return NULL;
    }

    ctx->pid = pid;
    atomic_init(&ctx->thread_id, 0);
    ctx->environment = NULL;
    ctx->copy_environment = NULL;
    ctx->num_variables_set = 0;
    memset(ctx->previous_directory, 0, MAXPATHLEN);
    ctx->parent_pid = 0;
    ctx->next_free = NULL;
    ctx->next_in_bucket = NULL;
    atomic_init(&ctx->ref_count, 1);  // Initial reference
    atomic_init(&ctx->is_allocated, true);

    return ctx;
}

/**
 * Insert context into active PID hash table
 */
static void pid_allocator_insert_active(ios_pid_context_t* ctx) {
    size_t bucket_idx = hash_pid(ctx->pid);

    pthread_rwlock_wrlock(&g_pid_allocator.active_pids.bucket_locks[bucket_idx]);

    // Insert at head of bucket
    ctx->next_in_bucket = g_pid_allocator.active_pids.buckets[bucket_idx];
    g_pid_allocator.active_pids.buckets[bucket_idx] = ctx;

    pthread_rwlock_unlock(&g_pid_allocator.active_pids.bucket_locks[bucket_idx]);
}

/**
 * Remove context from active PID hash table
 */
static void pid_allocator_remove_active(ios_pid_context_t* ctx) {
    size_t bucket_idx = hash_pid(ctx->pid);

    pthread_rwlock_wrlock(&g_pid_allocator.active_pids.bucket_locks[bucket_idx]);

    ios_pid_context_t** entry_ptr = &g_pid_allocator.active_pids.buckets[bucket_idx];
    while (*entry_ptr != NULL) {
        if (*entry_ptr == ctx) {
            *entry_ptr = ctx->next_in_bucket;
            ctx->next_in_bucket = NULL;
            break;
        }
        entry_ptr = &(*entry_ptr)->next_in_bucket;
    }

    pthread_rwlock_unlock(&g_pid_allocator.active_pids.bucket_locks[bucket_idx]);
}

/**
 * Allocate PID from free list (lock-free pop)
 */
static ios_pid_context_t* pid_allocator_pop_free_list(void) {
    ios_pid_context_t* head = atomic_load(&g_pid_allocator.free_list.head);

    while (head != NULL) {
        ios_pid_context_t* next = head->next_free;

        // Try to CAS the head pointer
        if (atomic_compare_exchange_weak(&g_pid_allocator.free_list.head, &head, next)) {
            // Successfully popped from free list
            atomic_fetch_sub(&g_pid_allocator.free_list.size, 1);
            head->next_free = NULL;
            atomic_store(&head->is_allocated, true);
            atomic_store(&head->ref_count, 1);  // Reset reference count
            return head;
        }

        // CAS failed, head was updated by another thread, retry
    }

    return NULL;  // Free list is empty
}

/**
 * Push PID context to free list (lock-free push)
 */
static void pid_allocator_push_free_list(ios_pid_context_t* ctx) {
    // Clean up context before returning to free list
    if (ctx->environment) {
        for (int i = 0; i < ctx->num_variables_set; i++) {
            free(ctx->environment[i]);
        }
        free(ctx->environment);
        ctx->environment = NULL;
    }

    if (ctx->copy_environment) {
        free(ctx->copy_environment);
        ctx->copy_environment = NULL;
    }

    ctx->num_variables_set = 0;
    atomic_store(&ctx->thread_id, 0);
    atomic_store(&ctx->is_allocated, false);

    // Lock-free push to free list
    ios_pid_context_t* old_head = atomic_load(&g_pid_allocator.free_list.head);

    do {
        ctx->next_free = old_head;
    } while (!atomic_compare_exchange_weak(&g_pid_allocator.free_list.head, &old_head, ctx));

    atomic_fetch_add(&g_pid_allocator.free_list.size, 1);
}

/**
 * Allocate a new PID and context
 */
ios_pid_context_t* ios_pid_allocate(void) {
    ios_pid_allocator_init();

    // Wait for any ongoing cleanups to complete
    // Replaces: while (cleanup_counter > 0) { }
    ios_pid_wait_for_cleanup();

    // Try to reuse from free list first
    ios_pid_context_t* ctx = pid_allocator_pop_free_list();

    if (ctx == NULL) {
        // Free list empty, allocate new PID
        pid_t new_pid = atomic_fetch_add(&g_pid_allocator.next_pid, 1);
        ctx = pid_allocator_create_context(new_pid);

        if (!ctx) {
            fprintf(stderr, "[ios_pid_allocator] ERROR: Failed to allocate context for PID %d\n", new_pid);
            return NULL;
        }

        atomic_fetch_add(&g_pid_allocator.total_allocated, 1);
        fprintf(stderr, "[ios_pid_allocator] Allocated new PID %d (total=%d)\n",
                new_pid, (int)atomic_load(&g_pid_allocator.total_allocated));
    } else {
        fprintf(stderr, "[ios_pid_allocator] Reused PID %d from free list (size=%d)\n",
                ctx->pid, (int)atomic_load(&g_pid_allocator.free_list.size));
    }

    // Insert into active PID table
    pid_allocator_insert_active(ctx);
    atomic_fetch_add(&g_pid_allocator.currently_active, 1);

    return ctx;
}

/**
 * Release a PID and its context
 */
void ios_pid_release(ios_pid_context_t* ctx) {
    if (!ctx) {
        return;
    }

    // Decrement reference count
    int prev_count = atomic_fetch_sub(&ctx->ref_count, 1);
    if (prev_count > 1) {
        // Still has references, don't release yet
        return;
    }

    fprintf(stderr, "[ios_pid_allocator] Releasing PID %d\n", ctx->pid);

    // Remove from active table
    pid_allocator_remove_active(ctx);
    atomic_fetch_sub(&g_pid_allocator.currently_active, 1);

    // Return to free list for reuse
    pid_allocator_push_free_list(ctx);
}

/**
 * Get PID number from context
 */
pid_t ios_pid_get_id(ios_pid_context_t* ctx) {
    return ctx ? ctx->pid : -1;
}

/**
 * Set thread ID for PID context
 */
void ios_pid_set_thread(ios_pid_context_t* ctx, pthread_t thread) {
    if (ctx) {
        atomic_store(&ctx->thread_id, thread);
    }
}

/**
 * Get thread ID from PID context
 */
pthread_t ios_pid_get_thread(ios_pid_context_t* ctx) {
    return ctx ? atomic_load(&ctx->thread_id) : 0;
}

/**
 * Lookup PID context by PID number
 */
ios_pid_context_t* ios_pid_lookup(pid_t pid) {
    ios_pid_allocator_init();

    size_t bucket_idx = hash_pid(pid);

    pthread_rwlock_rdlock(&g_pid_allocator.active_pids.bucket_locks[bucket_idx]);

    ios_pid_context_t* ctx = g_pid_allocator.active_pids.buckets[bucket_idx];
    while (ctx != NULL) {
        if (ctx->pid == pid && atomic_load(&ctx->is_allocated)) {
            // Increment reference count before returning
            atomic_fetch_add(&ctx->ref_count, 1);
            pthread_rwlock_unlock(&g_pid_allocator.active_pids.bucket_locks[bucket_idx]);
            return ctx;
        }
        ctx = ctx->next_in_bucket;
    }

    pthread_rwlock_unlock(&g_pid_allocator.active_pids.bucket_locks[bucket_idx]);
    return NULL;
}

/**
 * Lookup PID context by thread ID (linear search)
 */
ios_pid_context_t* ios_pid_lookup_by_thread(pthread_t thread) {
    ios_pid_allocator_init();

    // Search all buckets (no index by thread, must scan)
    for (int i = 0; i < PID_HASH_TABLE_SIZE; i++) {
        pthread_rwlock_rdlock(&g_pid_allocator.active_pids.bucket_locks[i]);

        ios_pid_context_t* ctx = g_pid_allocator.active_pids.buckets[i];
        while (ctx != NULL) {
            if (pthread_equal(atomic_load(&ctx->thread_id), thread) && atomic_load(&ctx->is_allocated)) {
                atomic_fetch_add(&ctx->ref_count, 1);
                pthread_rwlock_unlock(&g_pid_allocator.active_pids.bucket_locks[i]);
                return ctx;
            }
            ctx = ctx->next_in_bucket;
        }

        pthread_rwlock_unlock(&g_pid_allocator.active_pids.bucket_locks[i]);
    }

    return NULL;
}

/**
 * Get environment array for PID context
 */
char** ios_pid_get_environment(ios_pid_context_t* ctx) {
    return ctx ? ctx->environment : NULL;
}

/**
 * Set environment array for PID context
 */
void ios_pid_set_environment(ios_pid_context_t* ctx, char** env) {
    if (ctx) {
        ctx->environment = env;
    }
}

/**
 * Get number of environment variables set
 */
int ios_pid_get_env_count(ios_pid_context_t* ctx) {
    return ctx ? ctx->num_variables_set : 0;
}

/**
 * Set number of environment variables
 */
void ios_pid_set_env_count(ios_pid_context_t* ctx, int count) {
    if (ctx) {
        ctx->num_variables_set = count;
    }
}

/**
 * Get previous directory for PID context
 */
const char* ios_pid_get_previous_dir(ios_pid_context_t* ctx) {
    return ctx ? ctx->previous_directory : NULL;
}

/**
 * Set previous directory for PID context
 */
void ios_pid_set_previous_dir(ios_pid_context_t* ctx, const char* dir) {
    if (ctx && dir) {
        strncpy(ctx->previous_directory, dir, MAXPATHLEN - 1);
        ctx->previous_directory[MAXPATHLEN - 1] = '\0';
    }
}

/**
 * Get parent PID
 */
pid_t ios_pid_get_parent(ios_pid_context_t* ctx) {
    return ctx ? ctx->parent_pid : -1;
}

/**
 * Set parent PID
 */
void ios_pid_set_parent(ios_pid_context_t* ctx, pid_t parent_pid) {
    if (ctx) {
        ctx->parent_pid = parent_pid;
    }
}

/**
 * Shutdown PID allocator subsystem
 */
void ios_pid_allocator_shutdown(void) {
    if (!g_pid_allocator.initialized) {
        return;
    }

    fprintf(stderr, "[ios_pid_allocator] Shutting down (active=%d, free_list=%d)\n",
            (int)atomic_load(&g_pid_allocator.currently_active),
            (int)atomic_load(&g_pid_allocator.free_list.size));

    // Free all active PIDs
    for (int i = 0; i < PID_HASH_TABLE_SIZE; i++) {
        pthread_rwlock_wrlock(&g_pid_allocator.active_pids.bucket_locks[i]);

        ios_pid_context_t* ctx = g_pid_allocator.active_pids.buckets[i];
        while (ctx != NULL) {
            ios_pid_context_t* next = ctx->next_in_bucket;

            // Free environment
            if (ctx->environment) {
                for (int j = 0; j < ctx->num_variables_set; j++) {
                    free(ctx->environment[j]);
                }
                free(ctx->environment);
            }
            if (ctx->copy_environment) {
                free(ctx->copy_environment);
            }

            free(ctx);
            ctx = next;
        }

        g_pid_allocator.active_pids.buckets[i] = NULL;
        pthread_rwlock_unlock(&g_pid_allocator.active_pids.bucket_locks[i]);
        pthread_rwlock_destroy(&g_pid_allocator.active_pids.bucket_locks[i]);
    }

    // Free all PIDs in free list
    ios_pid_context_t* free_ctx = atomic_load(&g_pid_allocator.free_list.head);
    while (free_ctx != NULL) {
        ios_pid_context_t* next = free_ctx->next_free;
        free(free_ctx);
        free_ctx = next;
    }

    g_pid_allocator.initialized = false;
}

/**
 * Get allocator statistics
 */
void ios_pid_get_stats(int* total_allocated, int* currently_active, int* free_list_size) {
    if (total_allocated) {
        *total_allocated = atomic_load(&g_pid_allocator.total_allocated);
    }
    if (currently_active) {
        *currently_active = atomic_load(&g_pid_allocator.currently_active);
    }
    if (free_list_size) {
        *free_list_size = atomic_load(&g_pid_allocator.free_list.size);
    }
}

/**
 * Begin cleanup for PID
 *
 * Increments cleanup counter. Threads waiting in ios_pid_allocate()
 * will block until cleanup completes.
 * Replaces: cleanup_counter++
 */
void ios_pid_begin_cleanup(void) {
    pthread_mutex_lock(&g_pid_allocator.cleanup_mutex);
    atomic_fetch_add(&g_pid_allocator.cleanup_counter, 1);
    pthread_mutex_unlock(&g_pid_allocator.cleanup_mutex);
}

/**
 * End cleanup for PID
 *
 * Decrements cleanup counter and signals waiting threads when
 * counter reaches zero.
 * Replaces: cleanup_counter--
 */
void ios_pid_end_cleanup(void) {
    pthread_mutex_lock(&g_pid_allocator.cleanup_mutex);

    int prev_count = atomic_fetch_sub(&g_pid_allocator.cleanup_counter, 1);

    if (prev_count == 1) {
        // Last cleanup finished, wake up all waiting threads
        pthread_cond_broadcast(&g_pid_allocator.cleanup_done);
    }

    pthread_mutex_unlock(&g_pid_allocator.cleanup_mutex);
}

/**
 * Wait for cleanup to complete
 *
 * Blocks until all ongoing cleanups finish (cleanup_counter == 0).
 * Much more efficient than spinlock - uses condition variable.
 * Replaces: while (cleanup_counter > 0) { }
 */
void ios_pid_wait_for_cleanup(void) {
    pthread_mutex_lock(&g_pid_allocator.cleanup_mutex);

    while (atomic_load(&g_pid_allocator.cleanup_counter) > 0) {
        pthread_cond_wait(&g_pid_allocator.cleanup_done, &g_pid_allocator.cleanup_mutex);
    }

    pthread_mutex_unlock(&g_pid_allocator.cleanup_mutex);
}
