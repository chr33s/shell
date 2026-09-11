/*
 * ios_interpreter_pool.c
 * Thread-safe interpreter resource pool implementation
 */

#include "ios_interpreter_pool.h"
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <time.h>
#include <dispatch/dispatch.h>
#include <stdatomic.h>
#include <stdio.h>

// Default pool sizes
#define DEFAULT_PYTHON_SLOTS 6
#define DEFAULT_PERL_SLOTS 4
#define DEFAULT_TEX_SLOTS 2
#define DEFAULT_DASH_SLOTS 6
#define DEFAULT_SSH_SLOTS 2
#define DEFAULT_CURL_SLOTS 1

// Maximum supported slots per interpreter type
#define MAX_SLOTS_PER_TYPE 32

// Interpreter pool structure
typedef struct {
    ios_interpreter_type_t type;
    int max_slots;
    _Atomic(uint32_t) slot_bitmap;  // Bit N set = slot N is in use (max 32 slots)
    dispatch_semaphore_t semaphore; // Semaphore for blocking acquire
    _Atomic(int) wait_count;        // Number of threads waiting
    pthread_mutex_t config_mutex;   // Protects configuration changes
    bool initialized;
} interpreter_pool_t;

// Slot handle structure
struct _ios_interp_slot_handle {
    ios_interpreter_type_t type;
    int slot_number;
};

// Global pools
static interpreter_pool_t g_pools[IOS_INTERP_MAX];
static pthread_once_t init_once = PTHREAD_ONCE_INIT;
static bool manager_initialized = false;

// Forward declarations
static void interp_pool_init_once(void);
static int interp_pool_init_type(ios_interpreter_type_t type, int max_slots);
static int interp_pool_find_free_slot(interpreter_pool_t* pool);
static bool interp_pool_try_acquire_slot_internal(interpreter_pool_t* pool, int slot_num);

/**
 * Get default pool size for interpreter type
 */
static int get_default_pool_size(ios_interpreter_type_t type) {
    switch (type) {
        case IOS_INTERP_PYTHON: return DEFAULT_PYTHON_SLOTS;
        case IOS_INTERP_PERL:   return DEFAULT_PERL_SLOTS;
        case IOS_INTERP_TEX:    return DEFAULT_TEX_SLOTS;
        case IOS_INTERP_DASH:   return DEFAULT_DASH_SLOTS;
        case IOS_INTERP_SSH:    return DEFAULT_SSH_SLOTS;
        case IOS_INTERP_CURL:   return DEFAULT_CURL_SLOTS;
        default:                return 1;
    }
}

/**
 * One-time initialization
 */
static void interp_pool_init_once(void) {
    for (int i = 0; i < IOS_INTERP_MAX; i++) {
        interpreter_pool_t* pool = &g_pools[i];
        pool->type = (ios_interpreter_type_t)i;
        pool->max_slots = 0;
        atomic_init(&pool->slot_bitmap, 0);
        pool->semaphore = NULL;
        atomic_init(&pool->wait_count, 0);
        pthread_mutex_init(&pool->config_mutex, NULL);
        pool->initialized = false;
    }
    manager_initialized = true;
}

/**
 * Initialize interpreter pool manager
 */
void ios_interp_pool_init(void) {
    pthread_once(&init_once, interp_pool_init_once);
}

/**
 * Initialize a specific interpreter type pool
 */
static int interp_pool_init_type(ios_interpreter_type_t type, int max_slots) {
    if (type >= IOS_INTERP_MAX || max_slots <= 0 || max_slots > MAX_SLOTS_PER_TYPE) {
        return -1;
    }

    interpreter_pool_t* pool = &g_pools[type];

    pthread_mutex_lock(&pool->config_mutex);

    if (pool->initialized) {
        pthread_mutex_unlock(&pool->config_mutex);
        return 0;  // Already initialized
    }

    pool->max_slots = max_slots;
    atomic_store(&pool->slot_bitmap, 0);

    // Create semaphore with initial value = max_slots (all available)
    pool->semaphore = dispatch_semaphore_create(max_slots);
    if (pool->semaphore == NULL) {
        pthread_mutex_unlock(&pool->config_mutex);
        return -1;
    }

    pool->initialized = true;
    pthread_mutex_unlock(&pool->config_mutex);

    fprintf(stderr, "[ios_interp_pool] Initialized %s pool with %d slots\n",           ios_interp_type_name(type), max_slots);
    return 0;
}

/**
 * Shutdown interpreter pool manager
 */
void ios_interp_pool_shutdown(void) {
    if (!manager_initialized) {
        return;
    }

    for (int i = 0; i < IOS_INTERP_MAX; i++) {
        interpreter_pool_t* pool = &g_pools[i];

        pthread_mutex_lock(&pool->config_mutex);

        if (pool->semaphore != NULL) {
            // Note: Can't fully destroy semaphore if threads are waiting
            // Just mark as uninitialized and leak the semaphore
            pool->initialized = false;
        }

        pthread_mutex_unlock(&pool->config_mutex);
        pthread_mutex_destroy(&pool->config_mutex);
    }

    manager_initialized = false;
}

/**
 * Configure pool size for interpreter type
 */
int ios_interp_pool_configure(ios_interpreter_type_t type, int max_slots) {
    ios_interp_pool_init();

    if (type >= IOS_INTERP_MAX) {
        return -1;
    }

    interpreter_pool_t* pool = &g_pools[type];

    // If already initialized, can't reconfigure
    if (pool->initialized) {
    fprintf(stderr, "[ios_interp_pool] Warning: %s pool already initialized, cannot reconfigure\n",           ios_interp_type_name(type));
        return -1;
    }

    return interp_pool_init_type(type, max_slots);
}

/**
 * Find first free slot in bitmap (lock-free)
 * Returns slot number or -1 if all busy
 */
static int interp_pool_find_free_slot(interpreter_pool_t* pool) {
    uint32_t bitmap = atomic_load(&pool->slot_bitmap);

    for (int slot = 0; slot < pool->max_slots; slot++) {
        uint32_t mask = (1U << slot);
        if ((bitmap & mask) == 0) {
            // Slot appears free, try to acquire it atomically
            uint32_t old_bitmap = bitmap;
            uint32_t new_bitmap = bitmap | mask;

            if (atomic_compare_exchange_strong(&pool->slot_bitmap, &old_bitmap, new_bitmap)) {
                // Successfully acquired slot
                return slot;
            }

            // CAS failed, another thread took it, reload and retry
            bitmap = atomic_load(&pool->slot_bitmap);
            slot = -1;  // Restart search from beginning
        }
    }

    return -1;  // All slots busy
}

/**
 * Try to acquire a specific slot (lock-free)
 */
static bool interp_pool_try_acquire_slot_internal(interpreter_pool_t* pool, int slot_num) {
    if (slot_num < 0 || slot_num >= pool->max_slots) {
        return false;
    }

    uint32_t mask = (1U << slot_num);
    uint32_t old_bitmap = atomic_load(&pool->slot_bitmap);

    while (true) {
        // Check if slot is already taken
        if (old_bitmap & mask) {
            return false;  // Slot is busy
        }

        // Try to set the bit
        uint32_t new_bitmap = old_bitmap | mask;
        if (atomic_compare_exchange_weak(&pool->slot_bitmap, &old_bitmap, new_bitmap)) {
            return true;  // Successfully acquired
        }

        // CAS failed, old_bitmap was updated, retry
    }
}

/**
 * Acquire interpreter slot with timeout
 */
ios_interp_slot_handle_t* ios_interp_acquire(ios_interpreter_type_t type, int timeout_ms) {
    ios_interp_pool_init();

    if (type >= IOS_INTERP_MAX) {
           fprintf(stderr, "           \n", type);
        return NULL;
    }

    interpreter_pool_t* pool = &g_pools[type];

    // Lazy initialization with default size
    if (!pool->initialized) {
        int default_size = get_default_pool_size(type);
        if (interp_pool_init_type(type, default_size) != 0) {
           fprintf(stderr, "           \n", ios_interp_type_name(type));
            return NULL;
        }
    }

    // Increment wait count for statistics
    atomic_fetch_add(&pool->wait_count, 1);

    // Wait on semaphore with timeout
    dispatch_time_t timeout;
    if (timeout_ms < 0) {
        timeout = DISPATCH_TIME_FOREVER;
    } else if (timeout_ms == 0) {
        timeout = DISPATCH_TIME_NOW;
    } else {
        timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeout_ms * NSEC_PER_MSEC);
    }

    long result = dispatch_semaphore_wait(pool->semaphore, timeout);
    atomic_fetch_sub(&pool->wait_count, 1);

    if (result != 0) {
        // Timeout
    fprintf(stderr, "[ios_interp_pool] Timeout acquiring %s slot (timeout=%dms)\n",           ios_interp_type_name(type), timeout_ms);
        return NULL;
    }

    // Semaphore acquired, now find a free slot
    int slot_num = interp_pool_find_free_slot(pool);

    if (slot_num < 0) {
        // This should never happen (semaphore guarantees a slot is available)
    fprintf(stderr, "[ios_interp_pool] ERROR: Semaphore passed but no free slot for %s\n",           ios_interp_type_name(type));
        dispatch_semaphore_signal(pool->semaphore);  // Release semaphore
        return NULL;
    }

    // Create handle
    ios_interp_slot_handle_t* handle = malloc(sizeof(ios_interp_slot_handle_t));
    handle->type = type;
    handle->slot_number = slot_num;

    fprintf(stderr, "[ios_interp_pool] Acquired %s slot %d (thread=%p)\n",           ios_interp_type_name(type), slot_num, pthread_self());

    return handle;
}

/**
 * Try to acquire specific slot
 */
ios_interp_slot_handle_t* ios_interp_try_acquire_slot(ios_interpreter_type_t type, int slot_number) {
    ios_interp_pool_init();

    if (type >= IOS_INTERP_MAX) {
        return NULL;
    }

    interpreter_pool_t* pool = &g_pools[type];

    if (!pool->initialized) {
        int default_size = get_default_pool_size(type);
        if (interp_pool_init_type(type, default_size) != 0) {
            return NULL;
        }
    }

    // Try non-blocking semaphore wait
    long result = dispatch_semaphore_wait(pool->semaphore, DISPATCH_TIME_NOW);
    if (result != 0) {
        return NULL;  // No slots available
    }

    // Try to acquire the specific slot
    if (!interp_pool_try_acquire_slot_internal(pool, slot_number)) {
        // Specific slot not available, release semaphore
        dispatch_semaphore_signal(pool->semaphore);
        return NULL;
    }

    // Create handle
    ios_interp_slot_handle_t* handle = malloc(sizeof(ios_interp_slot_handle_t));
    handle->type = type;
    handle->slot_number = slot_number;

    return handle;
}

/**
 * Release interpreter slot
 */
void ios_interp_release(ios_interp_slot_handle_t* handle) {
    if (handle == NULL) {
        return;
    }

    interpreter_pool_t* pool = &g_pools[handle->type];

    if (!pool->initialized) {
           fprintf(stderr, "           \n");
        free(handle);
        return;
    }

    // Clear the slot bit atomically
    uint32_t mask = (1U << handle->slot_number);
    uint32_t old_bitmap = atomic_load(&pool->slot_bitmap);

    while (true) {
        uint32_t new_bitmap = old_bitmap & ~mask;
        if (atomic_compare_exchange_weak(&pool->slot_bitmap, &old_bitmap, new_bitmap)) {
            break;
        }
    }

    fprintf(stderr, "[ios_interp_pool] Released %s slot %d (thread=%p)\n",           ios_interp_type_name(handle->type), handle->slot_number, pthread_self());

    // Signal semaphore to wake waiting threads
    dispatch_semaphore_signal(pool->semaphore);

    free(handle);
}

/**
 * Get slot number from handle
 */
int ios_interp_get_slot_number(ios_interp_slot_handle_t* handle) {
    return handle ? handle->slot_number : -1;
}

/**
 * Get interpreter type from handle
 */
ios_interpreter_type_t ios_interp_get_type(ios_interp_slot_handle_t* handle) {
    return handle ? handle->type : IOS_INTERP_MAX;
}

/**
 * Check if slots are available
 */
bool ios_interp_has_available_slot(ios_interpreter_type_t type) {
    if (type >= IOS_INTERP_MAX) {
        return false;
    }

    interpreter_pool_t* pool = &g_pools[type];
    if (!pool->initialized) {
        return true;  // Not initialized yet, assume available
    }

    uint32_t bitmap = atomic_load(&pool->slot_bitmap);
    uint32_t full_mask = (1U << pool->max_slots) - 1;

    return (bitmap != full_mask);  // Not all bits set = at least one free
}

/**
 * Get pool statistics
 */
int ios_interp_get_stats(ios_interpreter_type_t type, int* total_slots, int* used_slots, int* wait_count) {
    if (type >= IOS_INTERP_MAX) {
        return -1;
    }

    interpreter_pool_t* pool = &g_pools[type];

    if (total_slots) {
        *total_slots = pool->initialized ? pool->max_slots : 0;
    }

    if (used_slots) {
        if (pool->initialized) {
            uint32_t bitmap = atomic_load(&pool->slot_bitmap);
            *used_slots = __builtin_popcount(bitmap);  // Count set bits
        } else {
            *used_slots = 0;
        }
    }

    if (wait_count) {
        *wait_count = atomic_load(&pool->wait_count);
    }

    return 0;
}

/**
 * Get interpreter type name
 */
const char* ios_interp_type_name(ios_interpreter_type_t type) {
    switch (type) {
        case IOS_INTERP_PYTHON: return "Python";
        case IOS_INTERP_PERL:   return "Perl";
        case IOS_INTERP_TEX:    return "TeX";
        case IOS_INTERP_DASH:   return "Dash";
        case IOS_INTERP_SSH:    return "SSH";
        case IOS_INTERP_CURL:   return "Curl";
        default:                return "Unknown";
    }
}

/**
 * Force release all slots (emergency)
 */
void ios_interp_force_release_all(ios_interpreter_type_t type) {
    if (type >= IOS_INTERP_MAX) {
        return;
    }

    interpreter_pool_t* pool = &g_pools[type];
    if (!pool->initialized) {
        return;
    }

           fprintf(stderr, "           \n", ios_interp_type_name(type));

    // Clear all bits
    atomic_store(&pool->slot_bitmap, 0);

    // Signal semaphore max_slots times to reset
    for (int i = 0; i < pool->max_slots; i++) {
        dispatch_semaphore_signal(pool->semaphore);
    }
}
