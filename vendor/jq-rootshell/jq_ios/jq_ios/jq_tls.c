/*
 * jq_tls.c - Thread-local storage implementation for jq on iOS
 *
 * Implements thread-local stdio streams and colors using a combination of:
 * - __thread keyword for simple TLS (stdio streams)
 * - pthread_key_t for complex TLS needing destructors (colors)
 *
 * The pattern follows jv_dtoa_tsd.c from the jq codebase.
 */

#include "jq_tls.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

/* Include jq's memory allocator for consistency */
#include "jv_alloc.h"

/* ============================================================================
 * Thread-local stdio streams
 *
 * Using __thread for simple pointer storage - no destructor needed.
 * ios_system sets these before calling jq_main().
 * ============================================================================ */

static __thread FILE* tls_stdin = NULL;
static __thread FILE* tls_stdout = NULL;
static __thread FILE* tls_stderr = NULL;

FILE* jq_ios_stdin(void) {
    return tls_stdin ? tls_stdin : stdin;
}

FILE* jq_ios_stdout(void) {
    return tls_stdout ? tls_stdout : stdout;
}

FILE* jq_ios_stderr(void) {
    return tls_stderr ? tls_stderr : stderr;
}

void jq_ios_set_stdin(FILE* f) {
    tls_stdin = f;
}

void jq_ios_set_stdout(FILE* f) {
    tls_stdout = f;
}

void jq_ios_set_stderr(FILE* f) {
    tls_stderr = f;
}

/* ============================================================================
 * Thread-local colors
 *
 * Using pthread_key_t with destructor for proper cleanup.
 * Pattern follows jv_dtoa_tsd.c
 * ============================================================================ */

/* ANSI escape code macros */
#define ESC "\033"
#define COL(c) (ESC "[" c "m")
#define COLRESET (ESC "[0m")

/* Default colors - same as jv_print.c */
static const char* const default_colors[JQ_IOS_COLORS_LEN] = {
    COL("0;90"),    /* JV_KIND_INVALID - dark gray */
    COL("0;39"),    /* JV_KIND_NULL - default */
    COL("0;39"),    /* JV_KIND_FALSE - default */
    COL("0;39"),    /* JV_KIND_TRUE - default */
    COL("0;32"),    /* JV_KIND_NUMBER - green */
    COL("1;39"),    /* JV_KIND_STRING - bold default */
    COL("1;39"),    /* JV_KIND_ARRAY - bold default */
    COL("1;34")     /* Field color (object keys) - bold blue */
};

/* pthread TLS key for colors */
static pthread_once_t colors_once = PTHREAD_ONCE_INIT;
static pthread_key_t colors_key;

/* Destructor called when thread exits */
static void colors_destructor(void* data) {
    if (data) {
        jq_colors_t* colors = (jq_colors_t*)data;
        if (colors->colors_buf) {
            jv_mem_free(colors->colors_buf);
        }
        jv_mem_free(colors);
    }
}

/* One-time initialization of pthread key */
static void colors_key_init(void) {
    if (pthread_key_create(&colors_key, colors_destructor) != 0) {
        fprintf(stderr, "jq_ios: error: cannot create thread specific key for colors\n");
        abort();
    }
}

jq_colors_t* jq_ios_get_colors(void) {
    pthread_once(&colors_once, colors_key_init);

    jq_colors_t* colors = (jq_colors_t*)pthread_getspecific(colors_key);
    if (!colors) {
        colors = (jq_colors_t*)jv_mem_calloc(1, sizeof(jq_colors_t));
        if (!colors) {
            fprintf(stderr, "jq_ios: error: out of memory allocating colors\n");
            abort();
        }

        /* Initialize with defaults */
        for (int i = 0; i < JQ_IOS_COLORS_LEN; i++) {
            colors->colors[i] = default_colors[i];
        }
        colors->colors_buf = NULL;

        if (pthread_setspecific(colors_key, colors) != 0) {
            jv_mem_free(colors);
            fprintf(stderr, "jq_ios: error: cannot set thread specific data for colors\n");
            abort();
        }
    }
    return colors;
}

int jq_ios_set_colors(const char* code_str) {
    if (code_str == NULL || code_str[0] == '\0') {
        /* Reset to defaults */
        jq_colors_t* colors = jq_ios_get_colors();
        if (colors->colors_buf) {
            jv_mem_free(colors->colors_buf);
            colors->colors_buf = NULL;
        }
        for (int i = 0; i < JQ_IOS_COLORS_LEN; i++) {
            colors->colors[i] = default_colors[i];
        }
        return 1;
    }

    /* Parse color codes - same logic as jq_set_colors in jv_print.c */
    const char* codes[JQ_IOS_COLORS_LEN + 1];
    size_t num_colors;
    size_t ci = 0;
    const char* p = code_str;

    for (num_colors = 0; ; num_colors++) {
        codes[num_colors] = p;
        p += strspn(p, "0123456789;");
        if (p[0] == '\0' || num_colors + 1 >= JQ_IOS_COLORS_LEN) {
            break;
        } else if (p[0] != ':') {
            return 0; /* invalid character */
        }
        p++;
    }

    if (codes[num_colors] != p) {
        num_colors++;
        codes[num_colors] = p + 1;
    } else if (num_colors == 0) {
        /* Empty string - reset to defaults */
        return jq_ios_set_colors(NULL);
    }

    jq_colors_t* colors = jq_ios_get_colors();

    /* Allocate buffer for custom colors */
    colors->colors_buf = (char*)jv_mem_realloc(
        colors->colors_buf,
        (codes[num_colors] - codes[0]) + 3 * num_colors + num_colors
    );
    if (!colors->colors_buf) {
        return 0;
    }

    char* cb = colors->colors_buf;
    for (ci = 0; ci < num_colors; ci++) {
        colors->colors[ci] = cb;
        size_t len = codes[ci + 1] - 1 - codes[ci];

        cb[0] = ESC[0];
        cb[1] = '[';
        memcpy(cb + 2, codes[ci], len);
        cb[2 + len] = 'm';
        cb[3 + len] = '\0';

        cb += len + 4;
    }

    /* Fill remaining with defaults */
    for (; ci < JQ_IOS_COLORS_LEN; ci++) {
        colors->colors[ci] = default_colors[ci];
    }

    return 1;
}

const char* jq_ios_get_color(int index) {
    if (index < 0 || index >= JQ_IOS_COLORS_LEN) {
        return "";
    }
    return jq_ios_get_colors()->colors[index];
}

const char* jq_ios_get_field_color(void) {
    return jq_ios_get_colors()->colors[JQ_IOS_COLORS_LEN - 1];
}

/* ============================================================================
 * Oniguruma initialization
 *
 * Called once per process to set safe regex parse depth limits.
 * ============================================================================ */

static pthread_once_t onig_once = PTHREAD_ONCE_INIT;

static void onig_init_impl(void) {
#ifdef HAVE_LIBONIG
    #include <oniguruma.h>
    /* Use a lower regex parse depth limit than the default (4096) to protect
     * from stack-overflows. See:
     * https://github.com/jqlang/jq/security/advisories/GHSA-f946-j5j2-4w5m
     */
    onig_set_parse_depth_limit(1024);
#endif
}

void jq_ios_onig_init(void) {
    pthread_once(&onig_once, onig_init_impl);
}

/* ============================================================================
 * Thread cleanup
 * ============================================================================ */

void jq_ios_thread_cleanup(void) {
    /* Clear stdio pointers */
    tls_stdin = NULL;
    tls_stdout = NULL;
    tls_stderr = NULL;

    /* Colors will be cleaned up by pthread destructor */
    /* But we can manually trigger it if desired */
    pthread_once(&colors_once, colors_key_init);
    jq_colors_t* colors = (jq_colors_t*)pthread_getspecific(colors_key);
    if (colors) {
        colors_destructor(colors);
        pthread_setspecific(colors_key, NULL);
    }
}

/* ============================================================================
 * ios_system detection
 * ============================================================================ */

int jq_ios_is_ios_system(void) {
    /* Check if we're running under ios_system by looking for
     * thread-local streams that are different from global ones */
    return (tls_stdout != NULL && tls_stdout != stdout) ||
           (tls_stdin != NULL && tls_stdin != stdin) ||
           (tls_stderr != NULL && tls_stderr != stderr);
}
