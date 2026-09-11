/*
 * ios_interpreter_pool.h
 * Thread-safe interpreter resource pool management
 *
 * Provides lock-free slot allocation for interpreters (Python, Perl, TeX, etc.)
 * Eliminates race conditions when multiple threads try to acquire interpreter slots
 */

#ifndef IOS_INTERPRETER_POOL_H
#define IOS_INTERPRETER_POOL_H

#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Interpreter types
typedef enum {
    IOS_INTERP_PYTHON = 0,
    IOS_INTERP_PERL,
    IOS_INTERP_TEX,
    IOS_INTERP_DASH,
    IOS_INTERP_SSH,
    IOS_INTERP_CURL,
    IOS_INTERP_MAX  // Sentinel value
} ios_interpreter_type_t;

// Opaque handle for an acquired interpreter slot
typedef struct _ios_interp_slot_handle ios_interp_slot_handle_t;

/**
 * Initialize the interpreter pool manager
 * Must be called before any other interpreter pool functions
 * Thread-safe: Can be called multiple times (idempotent)
 */
void ios_interp_pool_init(void);

/**
 * Shutdown the interpreter pool manager
 * Thread-safe: Can be called multiple times (idempotent)
 */
void ios_interp_pool_shutdown(void);

/**
 * Configure pool size for a specific interpreter type
 * Must be called before any acquire operations for that interpreter
 * Default sizes: Python=6, Perl=4, TeX=2, Dash=6, SSH=2, Curl=1
 *
 * @param type Interpreter type
 * @param max_slots Maximum number of concurrent instances
 * @return 0 on success, -1 on error
 *
 * Thread-safe: Can be called from any thread
 */
int ios_interp_pool_configure(ios_interpreter_type_t type, int max_slots);

/**
 * Acquire an interpreter slot (blocking with timeout)
 * Returns a handle containing the allocated slot number
 *
 * @param type Interpreter type
 * @param timeout_ms Timeout in milliseconds (0 = non-blocking, -1 = infinite)
 * @return Handle with slot number, or NULL if timeout/error
 *
 * Thread-safe: Multiple threads can acquire concurrently
 * Caller must call ios_interp_release() when done
 *
 * Example:
 *   ios_interp_slot_handle_t* handle = ios_interp_acquire(IOS_INTERP_PYTHON, 1000);
 *   if (handle) {
 *       int slot = ios_interp_get_slot_number(handle);
 *       // Use Python interpreter in slot 'slot'
 *       ios_interp_release(handle);
 *   }
 */
ios_interp_slot_handle_t* ios_interp_acquire(ios_interpreter_type_t type, int timeout_ms);

/**
 * Try to acquire a specific slot number (non-blocking)
 * Useful when code wants to reuse the same slot
 *
 * @param type Interpreter type
 * @param slot_number Specific slot to acquire
 * @return Handle if slot was free, NULL otherwise
 *
 * Thread-safe: Multiple threads can try concurrently
 */
ios_interp_slot_handle_t* ios_interp_try_acquire_slot(ios_interpreter_type_t type, int slot_number);

/**
 * Release an interpreter slot
 * Makes the slot available for other threads
 *
 * @param handle Handle returned by ios_interp_acquire()
 *
 * Thread-safe: Can be called from any thread
 */
void ios_interp_release(ios_interp_slot_handle_t* handle);

/**
 * Get slot number from handle
 *
 * @param handle Handle returned by ios_interp_acquire()
 * @return Slot number (0-based), or -1 if handle is NULL
 */
int ios_interp_get_slot_number(ios_interp_slot_handle_t* handle);

/**
 * Get interpreter type from handle
 *
 * @param handle Handle returned by ios_interp_acquire()
 * @return Interpreter type, or IOS_INTERP_MAX if handle is NULL
 */
ios_interpreter_type_t ios_interp_get_type(ios_interp_slot_handle_t* handle);

/**
 * Check if any slots are available without blocking
 *
 * @param type Interpreter type
 * @return true if at least one slot is available, false otherwise
 */
bool ios_interp_has_available_slot(ios_interpreter_type_t type);

/**
 * Get pool statistics for an interpreter type
 *
 * @param type Interpreter type
 * @param total_slots Output: total number of slots
 * @param used_slots Output: number of slots currently in use
 * @param wait_count Output: number of threads currently waiting
 * @return 0 on success, -1 on error
 */
int ios_interp_get_stats(ios_interpreter_type_t type, int* total_slots, int* used_slots, int* wait_count);

/**
 * Get interpreter type name as string (for logging)
 *
 * @param type Interpreter type
 * @return String name (e.g., "Python", "Perl", "TeX")
 */
const char* ios_interp_type_name(ios_interpreter_type_t type);

/**
 * Force release all slots for a specific interpreter (emergency cleanup)
 * WARNING: Only use in recovery scenarios, may cause undefined behavior
 *
 * @param type Interpreter type
 */
void ios_interp_force_release_all(ios_interpreter_type_t type);

#ifdef __cplusplus
}
#endif

#endif /* IOS_INTERPRETER_POOL_H */
