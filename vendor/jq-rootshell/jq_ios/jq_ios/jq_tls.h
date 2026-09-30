/*
 * jq_tls.h - Thread-local storage for jq on iOS
 *
 * This header provides thread-local storage for stdio streams and colors,
 * enabling safe concurrent execution of multiple jq instances.
 * Compatible with ios_system's thread-local I/O redirection.
 */

#ifndef JQ_TLS_H
#define JQ_TLS_H

#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Thread-local stdio stream accessors.
 *
 * These functions return the thread's current stdin/stdout/stderr.
 * When running under ios_system, these will automatically be redirected
 * to the appropriate per-session streams.
 *
 * When not set, they fall back to the global stdin/stdout/stderr.
 */
FILE* jq_ios_stdin(void);
FILE* jq_ios_stdout(void);
FILE* jq_ios_stderr(void);

/*
 * Thread-local stdio stream setters.
 *
 * ios_system calls these before invoking jq_main() to set up
 * per-thread I/O streams. You can also call these directly
 * when using jq as a library.
 */
void jq_ios_set_stdin(FILE* f);
void jq_ios_set_stdout(FILE* f);
void jq_ios_set_stderr(FILE* f);

/*
 * Thread-local color configuration.
 *
 * The color table stores ANSI escape sequences for different JSON types.
 * Each thread can have its own color configuration.
 */

/* Number of color slots (matches jv_kind count + 1 for field color) */
#define JQ_IOS_COLORS_LEN 8

typedef struct jq_colors {
    const char* colors[JQ_IOS_COLORS_LEN];
    char* colors_buf;  /* Buffer for custom color strings */
} jq_colors_t;

/*
 * Get the current thread's color configuration.
 * Initializes with default colors if not already set.
 *
 * Returns: Pointer to thread-local color config (never NULL)
 */
jq_colors_t* jq_ios_get_colors(void);

/*
 * Set colors for the current thread from a colon-separated string.
 * Format: "code1:code2:code3:..." where each code is an ANSI color code.
 *
 * This is the same format as the JQ_COLORS environment variable.
 *
 * Parameters:
 *   code_str - Color codes string (e.g., "31:32:33:34:35:36:37:38")
 *              Pass NULL or empty string to reset to defaults.
 *
 * Returns: 1 on success, 0 on parse error
 */
int jq_ios_set_colors(const char* code_str);

/*
 * Get a specific color by index.
 *
 * Parameters:
 *   index - Color index (0 to JQ_IOS_COLORS_LEN-1)
 *
 * Returns: ANSI escape sequence string, or empty string if invalid index
 */
const char* jq_ios_get_color(int index);

/*
 * Get the field (object key) color.
 * This is the last color in the array, used for object keys.
 */
const char* jq_ios_get_field_color(void);

/*
 * Oniguruma regex library initialization.
 *
 * This is called once per process (thread-safe) to initialize oniguruma
 * with safe parse depth limits. Multiple calls are safe and idempotent.
 */
void jq_ios_onig_init(void);

/*
 * Thread cleanup.
 *
 * Call this when a thread is about to exit to free thread-local resources.
 * This is optional - resources will be freed automatically via pthread
 * destructors, but calling this explicitly can help with debugging.
 */
void jq_ios_thread_cleanup(void);

/*
 * Check if we're running under ios_system.
 *
 * Returns: 1 if ios_system environment detected, 0 otherwise
 */
int jq_ios_is_ios_system(void);

#ifdef __cplusplus
}
#endif

#endif /* JQ_TLS_H */
