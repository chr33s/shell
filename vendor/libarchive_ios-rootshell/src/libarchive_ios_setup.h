// libarchive_ios_setup.h — Central iOS adaptation header for libarchive tools
// Included from each tool's *_platform.h on iOS, so it takes effect in all sources.
//
// IMPORTANT: We must include system headers BEFORE our macro overrides,
// because exit()/stdin/stdout/stderr/STDIN_FILENO etc. appear in system
// header declarations.  Once the macros are defined, subsequent includes
// of these headers are no-ops (include guards), so source files that
// include <stdlib.h> later won't hit conflicts.

#ifndef LIBARCHIVE_IOS_SETUP_H
#define LIBARCHIVE_IOS_SETUP_H

// Pull in system headers first, before overriding their symbols
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <setjmp.h>
#include <string.h>
#include <stdarg.h>
#include <signal.h>

#include "ios_error.h"

// Thread-local longjmp buffer for intercepting exit() calls
extern __thread jmp_buf libarchive_ios_exit_jmpbuf;
extern __thread int libarchive_ios_exit_status;

// Override exit() with longjmp back to *_main().
// fflush(NULL) flushes ALL open streams — critical because longjmp would
// skip the normal C runtime flush that a real exit() performs.
#undef exit
#define exit(status) \
    do { fflush(NULL); libarchive_ios_exit_status = (status); longjmp(libarchive_ios_exit_jmpbuf, 1); } while(0)

// Redirect stdio FILE* to ios_system's per-thread streams
#undef stdin
#define stdin thread_stdin
#undef stdout
#define stdout thread_stdout
#undef stderr
#define stderr thread_stderr

// Redirect STDIN_FILENO/STDOUT_FILENO/STDERR_FILENO to the fds behind
// the thread-local FILE* streams.  ios_system sets up per-thread pipes
// whose fds differ from the process-wide 0/1/2.
#undef STDIN_FILENO
#define STDIN_FILENO  (fileno(thread_stdin))
#undef STDOUT_FILENO
#define STDOUT_FILENO (fileno(thread_stdout))
#undef STDERR_FILENO
#define STDERR_FILENO (fileno(thread_stderr))

// Override printf/putchar/puts/putc so they route through thread_stdout
// instead of libc's internal stdout FILE*.  printf() etc. are compiled
// into libc and reference the process-wide stdout — our #define stdout
// only affects source code that literally spells "stdout", not libc
// functions.  These macros ensure ALL output goes to the right pipe.
static inline int libarchive_ios_printf(const char *fmt, ...)
    __attribute__((__format__(__printf__, 1, 2)));
static inline int libarchive_ios_printf(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int r = vfprintf(thread_stdout, fmt, ap);
    va_end(ap);
    return r;
}
#undef printf
#define printf(...) libarchive_ios_printf(__VA_ARGS__)

#undef putchar
#define putchar(c) fputc(c, thread_stdout)

#undef puts
#define puts(s) (fputs(s, thread_stdout), fputc('\n', thread_stdout))

#undef getchar
#define getchar() fgetc(thread_stdin)

// Route signal() through ios_system's cooperative signal handler
// so CTRL-C cancellation is delivered to the running tool.
#undef signal
#define signal(sig, func) ios_signal(sig, func)

// iOS reset function declarations (defined in patched tool sources)
extern void cpio_cmdline_ios_reset(void);

#endif // LIBARCHIVE_IOS_SETUP_H
