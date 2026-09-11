/*
 * ios_env_manager.c
 * Thread-safe per-thread environment variable management implementation
 */

#include "ios_env_manager.h"
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>

// Per-thread environment structure
typedef struct _thread_env {
    pthread_t thread_id;
    char** environ_array;       // NULL-terminated array of "NAME=VALUE" strings
    int num_vars;               // Number of variables
    int capacity;               // Allocated capacity
    pthread_rwlock_t rwlock;    // Per-thread environment lock
    bool is_copy_on_write;      // True if this is a COW copy (not yet modified)
} thread_env_t;

// Global state
static pthread_key_t env_key;              // Thread-specific key for thread_env_t*
static pthread_once_t env_init_once = PTHREAD_ONCE_INIT;
static bool env_manager_initialized = false;
static _Atomic(int) total_thread_envs = 0;

// Hash table for mapping thread IDs to environment (for copy operations)
#define ENV_HASH_SIZE 128
typedef struct _env_hash_entry {
    pthread_t thread_id;
    thread_env_t* env;
    struct _env_hash_entry* next;
} env_hash_entry_t;

static env_hash_entry_t* env_hash_table[ENV_HASH_SIZE];
static pthread_rwlock_t env_hash_lock;

// Forward declarations
static void env_manager_init_once(void);
static void env_thread_destructor(void* arg);
static thread_env_t* env_get_current(void);
static thread_env_t* env_create_empty(void);
static thread_env_t* env_lookup_by_tid(pthread_t tid);
static void env_hash_insert(thread_env_t* env);
static void env_hash_remove(pthread_t tid);
static int env_find_var(thread_env_t* env, const char* name);
static void env_free(thread_env_t* env);

// Hash function for thread IDs
static inline size_t hash_tid(pthread_t tid) {
    return ((unsigned long)tid) % ENV_HASH_SIZE;
}

/**
 * Initialize the environment manager subsystem
 */
void ios_env_manager_init(void) {
    pthread_once(&env_init_once, env_manager_init_once);
}

/**
 * Internal: One-time initialization
 */
static void env_manager_init_once(void) {
    // Create thread-specific key
    int rc = pthread_key_create(&env_key, env_thread_destructor);
    if (rc != 0) {
        return;
    }

    // Initialize hash table
    for (int i = 0; i < ENV_HASH_SIZE; i++) {
        env_hash_table[i] = NULL;
    }
    pthread_rwlock_init(&env_hash_lock, NULL);

    atomic_init(&total_thread_envs, 0);
    env_manager_initialized = true;
}

/**
 * Shutdown the environment manager
 */
void ios_env_manager_shutdown(void) {
    if (!env_manager_initialized) {
        return;
    }

    // Cleanup hash table
    pthread_rwlock_wrlock(&env_hash_lock);
    for (int i = 0; i < ENV_HASH_SIZE; i++) {
        env_hash_entry_t* entry = env_hash_table[i];
        while (entry != NULL) {
            env_hash_entry_t* next = entry->next;
            env_free(entry->env);
            free(entry);
            entry = next;
        }
        env_hash_table[i] = NULL;
    }
    pthread_rwlock_unlock(&env_hash_lock);

    pthread_rwlock_destroy(&env_hash_lock);
    pthread_key_delete(env_key);
    env_manager_initialized = false;
}

/**
 * Thread destructor - called when thread exits
 */
static void env_thread_destructor(void* arg) {
    thread_env_t* env = (thread_env_t*)arg;
    if (env != NULL) {
        pthread_t tid = pthread_self();
        env_hash_remove(tid);
        env_free(env);
    }
}

/**
 * Get current thread's environment
 */
static thread_env_t* env_get_current(void) {
    // Return NULL if manager not initialized to avoid garbage from uninitialized env_key
    if (!env_manager_initialized) {
        return NULL;
    }
    return (thread_env_t*)pthread_getspecific(env_key);
}

/**
 * Create empty environment
 */
static thread_env_t* env_create_empty(void) {
    thread_env_t* env = calloc(1, sizeof(thread_env_t));
    if (env == NULL) {
        return NULL;
    }

    env->thread_id = pthread_self();
    env->capacity = 16;  // Initial capacity
    env->num_vars = 0;
    env->environ_array = calloc(env->capacity + 1, sizeof(char*));  // +1 for NULL terminator
    if (env->environ_array == NULL) {
        free(env);
        return NULL;
    }

    pthread_rwlock_init(&env->rwlock, NULL);
    env->is_copy_on_write = false;

    atomic_fetch_add(&total_thread_envs, 1);
    return env;
}

/**
 * Free environment
 */
static void env_free(thread_env_t* env) {
    if (env == NULL) {
        return;
    }

    pthread_rwlock_destroy(&env->rwlock);

    if (env->environ_array != NULL) {
        for (int i = 0; i < env->num_vars; i++) {
            free(env->environ_array[i]);
        }
        free(env->environ_array);
    }

    atomic_fetch_sub(&total_thread_envs, 1);
    free(env);
}

/**
 * Hash table operations
 */
static void env_hash_insert(thread_env_t* env) {
    size_t bucket = hash_tid(env->thread_id);

    pthread_rwlock_wrlock(&env_hash_lock);

    env_hash_entry_t* new_entry = malloc(sizeof(env_hash_entry_t));
    new_entry->thread_id = env->thread_id;
    new_entry->env = env;
    new_entry->next = env_hash_table[bucket];
    env_hash_table[bucket] = new_entry;

    pthread_rwlock_unlock(&env_hash_lock);
}

static void env_hash_remove(pthread_t tid) {
    size_t bucket = hash_tid(tid);

    pthread_rwlock_wrlock(&env_hash_lock);

    env_hash_entry_t** entry_ptr = &env_hash_table[bucket];
    while (*entry_ptr != NULL) {
        if (pthread_equal((*entry_ptr)->thread_id, tid)) {
            env_hash_entry_t* to_free = *entry_ptr;
            *entry_ptr = to_free->next;
            free(to_free);
            break;
        }
        entry_ptr = &(*entry_ptr)->next;
    }

    pthread_rwlock_unlock(&env_hash_lock);
}

static thread_env_t* env_lookup_by_tid(pthread_t tid) {
    size_t bucket = hash_tid(tid);
    thread_env_t* result = NULL;

    pthread_rwlock_rdlock(&env_hash_lock);

    env_hash_entry_t* entry = env_hash_table[bucket];
    while (entry != NULL) {
        if (pthread_equal(entry->thread_id, tid)) {
            result = entry->env;
            break;
        }
        entry = entry->next;
    }

    pthread_rwlock_unlock(&env_hash_lock);
    return result;
}

/**
 * Find variable index in environment array
 * Returns index if found, -1 otherwise
 * Caller must hold at least read lock
 */
static int env_find_var(thread_env_t* env, const char* name) {
    size_t name_len = strlen(name);

    for (int i = 0; i < env->num_vars; i++) {
        // Check if this entry matches "NAME="
        if (strncmp(env->environ_array[i], name, name_len) == 0 &&
            env->environ_array[i][name_len] == '=') {
            return i;
        }
    }

    return -1;
}

/**
 * Initialize environment for current thread
 */
void ios_env_init_thread(pthread_t parent_tid) {
    ios_env_manager_init();

    // Check if already initialized
    if (env_get_current() != NULL) {
        return;
    }

    thread_env_t* env = env_create_empty();
    if (env == NULL) {
        return;
    }

    // Copy from parent if specified
    if (parent_tid != 0) {
        thread_env_t* parent_env = env_lookup_by_tid(parent_tid);
        if (parent_env != NULL) {
            // Copy parent's environment
            pthread_rwlock_rdlock(&parent_env->rwlock);

            // Expand capacity if needed
            if (parent_env->num_vars > env->capacity) {
                env->capacity = parent_env->num_vars + 8;
                env->environ_array = realloc(env->environ_array, (env->capacity + 1) * sizeof(char*));
            }

            // Copy all variables
            for (int i = 0; i < parent_env->num_vars; i++) {
                env->environ_array[i] = strdup(parent_env->environ_array[i]);
            }
            env->num_vars = parent_env->num_vars;
            env->environ_array[env->num_vars] = NULL;

            pthread_rwlock_unlock(&parent_env->rwlock);
            env->is_copy_on_write = true;
        }
    } else {
        // Initialize from process environment (extern char** environ)
        extern char** environ;
        if (environ != NULL) {
            int count = 0;
            while (environ[count] != NULL) {
                count++;
            }

            if (count > env->capacity) {
                env->capacity = count + 8;
                env->environ_array = realloc(env->environ_array, (env->capacity + 1) * sizeof(char*));
            }

            for (int i = 0; i < count; i++) {
                env->environ_array[i] = strdup(environ[i]);
            }
            env->num_vars = count;
            env->environ_array[env->num_vars] = NULL;
        }
    }

    // Store in thread-local storage
    pthread_setspecific(env_key, env);

    // Add to hash table for parent-child copy operations
    env_hash_insert(env);
}

/**
 * Cleanup environment for current thread
 */
void ios_env_cleanup_thread(void) {
    thread_env_t* env = env_get_current();
    if (env != NULL) {
        pthread_setspecific(env_key, NULL);
        // env_thread_destructor will be called automatically
    }
}

/**
 * Get environment variable value
 */
char* ios_env_getenv(const char* name) {
    if (name == NULL || name[0] == '\0') {
        return NULL;
    }

    thread_env_t* env = env_get_current();
    if (env == NULL) {
        // Thread not initialized, try process environment
        return getenv(name);
    }

    pthread_rwlock_rdlock(&env->rwlock);

    int idx = env_find_var(env, name);
    char* result = NULL;

    if (idx >= 0) {
        // Return pointer to value (after "NAME=")
        size_t name_len = strlen(name);
        result = env->environ_array[idx] + name_len + 1;
    }

    pthread_rwlock_unlock(&env->rwlock);
    return result;
}

/**
 * Set environment variable
 */
int ios_env_setenv(const char* name, const char* value, int overwrite) {
    if (name == NULL || name[0] == '\0' || strchr(name, '=') != NULL) {
        errno = EINVAL;
        return -1;
    }

    if (value == NULL) {
        value = "";
    }

    thread_env_t* env = env_get_current();
    if (env == NULL) {
        // Thread not initialized, fallback to process environment
        return setenv(name, value, overwrite);
    }

    pthread_rwlock_wrlock(&env->rwlock);

    int idx = env_find_var(env, name);

    if (idx >= 0) {
        // Variable exists
        if (!overwrite) {
            pthread_rwlock_unlock(&env->rwlock);
            return 0;
        }

        // Replace existing value
        free(env->environ_array[idx]);

        size_t len = strlen(name) + 1 + strlen(value) + 1;
        env->environ_array[idx] = malloc(len);
        snprintf(env->environ_array[idx], len, "%s=%s", name, value);
    } else {
        // Variable doesn't exist, add it
        if (env->num_vars >= env->capacity) {
            // Expand capacity
            env->capacity = env->capacity * 2;
            env->environ_array = realloc(env->environ_array, (env->capacity + 1) * sizeof(char*));
            if (env->environ_array == NULL) {
                pthread_rwlock_unlock(&env->rwlock);
                errno = ENOMEM;
                return -1;
            }
        }

        size_t len = strlen(name) + 1 + strlen(value) + 1;
        env->environ_array[env->num_vars] = malloc(len);
        snprintf(env->environ_array[env->num_vars], len, "%s=%s", name, value);
        env->num_vars++;
        env->environ_array[env->num_vars] = NULL;
    }

    env->is_copy_on_write = false;  // Modified, no longer COW
    pthread_rwlock_unlock(&env->rwlock);
    return 0;
}

/**
 * Unset environment variable
 */
int ios_env_unsetenv(const char* name) {
    if (name == NULL || name[0] == '\0' || strchr(name, '=') != NULL) {
        errno = EINVAL;
        return -1;
    }

    thread_env_t* env = env_get_current();
    if (env == NULL) {
        // Thread not initialized, fallback to process environment
        return unsetenv(name);
    }

    pthread_rwlock_wrlock(&env->rwlock);

    int idx = env_find_var(env, name);

    if (idx >= 0) {
        // Variable exists, remove it
        free(env->environ_array[idx]);

        // Shift remaining variables down
        for (int i = idx; i < env->num_vars - 1; i++) {
            env->environ_array[i] = env->environ_array[i + 1];
        }

        env->num_vars--;
        env->environ_array[env->num_vars] = NULL;
        env->is_copy_on_write = false;
    }

    pthread_rwlock_unlock(&env->rwlock);
    return 0;
}

/**
 * Get entire environment array
 */
char** ios_env_get_environ(void) {
    thread_env_t* env = env_get_current();
    if (env == NULL) {
        // Thread not initialized, return process environment
        extern char** environ;
        return environ;
    }

    // Return pointer to environ array (caller should not modify)
    // In a production system, might want to return a copy for safety
    return env->environ_array;
}

/**
 * Copy environment from one thread to another
 */
int ios_env_copy_from_thread(pthread_t source_tid, pthread_t dest_tid) {
    thread_env_t* source_env = env_lookup_by_tid(source_tid);
    thread_env_t* dest_env = env_lookup_by_tid(dest_tid);

    if (source_env == NULL || dest_env == NULL) {
        errno = ESRCH;
        return -1;
    }

    pthread_rwlock_rdlock(&source_env->rwlock);
    pthread_rwlock_wrlock(&dest_env->rwlock);

    // Free destination's current environment
    for (int i = 0; i < dest_env->num_vars; i++) {
        free(dest_env->environ_array[i]);
    }

    // Expand capacity if needed
    if (source_env->num_vars > dest_env->capacity) {
        dest_env->capacity = source_env->num_vars + 8;
        dest_env->environ_array = realloc(dest_env->environ_array, (dest_env->capacity + 1) * sizeof(char*));
    }

    // Copy all variables
    for (int i = 0; i < source_env->num_vars; i++) {
        dest_env->environ_array[i] = strdup(source_env->environ_array[i]);
    }
    dest_env->num_vars = source_env->num_vars;
    dest_env->environ_array[dest_env->num_vars] = NULL;
    dest_env->is_copy_on_write = true;

    pthread_rwlock_unlock(&dest_env->rwlock);
    pthread_rwlock_unlock(&source_env->rwlock);

    return 0;
}

/**
 * Get environment manager statistics
 */
void ios_env_get_stats(int* total_threads, int* total_vars) {
    if (total_threads) {
        *total_threads = atomic_load(&total_thread_envs);
    }

    if (total_vars) {
        int count = 0;
        pthread_rwlock_rdlock(&env_hash_lock);

        for (int i = 0; i < ENV_HASH_SIZE; i++) {
            env_hash_entry_t* entry = env_hash_table[i];
            while (entry != NULL) {
                count += entry->env->num_vars;
                entry = entry->next;
            }
        }

        pthread_rwlock_unlock(&env_hash_lock);
        *total_vars = count;
    }
}
