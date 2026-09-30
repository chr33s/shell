#ifndef HEADER_CURL_TOOL_SETUP_H
#define HEADER_CURL_TOOL_SETUP_H
/***************************************************************************
 *                                  _   _ ____  _
 *  Project                     ___| | | |  _ \| |
 *                             / __| | | | |_) | |
 *                            | (__| |_| |  _ <| |___
 *                             \___|\___/|_| \_\_____|
 *
 * Copyright (C) Daniel Stenberg, <daniel@haxx.se>, et al.
 *
 * This software is licensed as described in the file COPYING, which
 * you should have received as part of this distribution. The terms
 * are also available at https://curl.se/docs/copyright.html.
 *
 * You may opt to use, copy, modify, merge, publish, distribute and/or sell
 * copies of the Software, and permit persons to whom the Software is
 * furnished to do so, under the terms of the COPYING file.
 *
 * This software is distributed on an "AS IS" basis, WITHOUT WARRANTY OF ANY
 * KIND, either express or implied.
 *
 * SPDX-License-Identifier: curl
 *
 ***************************************************************************/

#ifndef CURL_NO_OLDIES
#define CURL_NO_OLDIES
#endif

/*
 * curl_setup.h may define preprocessor macros such as _FILE_OFFSET_BITS and
 * _LARGE_FILES in order to support files larger than 2 GB. On platforms
 * where this happens it is mandatory that these macros are defined before
 * any system header file is included, otherwise file handling function
 * prototypes are misdeclared and curl tool may not build properly;
 * therefore we must include curl_setup.h before curl.h when building curl.
 */

#include "curl_setup.h" /* from the lib directory */

#include <TargetConditionals.h>

#if TARGET_OS_IPHONE
extern __thread FILE *tool_stderr;
#else
extern FILE *tool_stderr;
#endif

#if TARGET_OS_IPHONE
#include "ios_error.h"
#undef stderr
#define stderr thread_stderr
#undef stdout
#define stdout thread_stdout
#undef stdin
#define stdin thread_stdin
#undef printf
#define printf(...) fprintf(thread_stdout, ##__VA_ARGS__)
#undef STDIN_FILENO
#define STDIN_FILENO fileno(thread_stdin)
#undef STDOUT_FILENO
#define STDOUT_FILENO fileno(thread_stdout)
#undef STDERR_FILENO
#define STDERR_FILENO fileno(thread_stderr)
#endif

/*
 * curl tool certainly uses libcurl's external interface.
 */

#include "curlx/base64.h" /* for curlx_base64* */
#include "curlx/dynbuf.h" /* for curlx_dyn_*() */
#include "curlx/fopen.h" /* for curlx_f*() */
#include "curlx/multibyte.h" /* for curlx_convert_*() */
#include "curlx/strcopy.h" /* for curlx_strcopy() */
#include "curlx/strdup.h" /* for curlx_memdup*() */
#include "curlx/strerr.h" /* for curlx_strerror() */
#include "curlx/strparse.h" /* for curlx_str_* parsing functions */
#include "curlx/timediff.h" /* for timediff_t type and related functions */
#include "curlx/timeval.h" /* for curlx_now type and related functions */
#include "curlx/wait.h" /* for curlx_wait_ms() */

/*
 * Platform specific stuff.
 */

#if defined(macintosh) || (defined(__APPLE__) && TARGET_OS_IPHONE)
#  define main(x, y) curl_main(x, y)
#endif

#ifndef CURL_OS
#define CURL_OS "unknown"
#endif

/* define what to use for unprintable characters */
#define UNPRINTABLE_CHAR '.'

#ifndef tool_nop_stmt
#define tool_nop_stmt do {} while(0)
#endif

#ifdef _WIN32
#  define CURL_STRICMP(p1, p2)  _stricmp(p1, p2)
#elif defined(HAVE_STRCASECMP)
#  ifdef HAVE_STRINGS_H
#  include <strings.h>
#  endif
#  define CURL_STRICMP(p1, p2)  strcasecmp(p1, p2)
#elif defined(HAVE_STRCMPI)
#  define CURL_STRICMP(p1, p2)  strcmpi(p1, p2)
#elif defined(HAVE_STRICMP)
#  define CURL_STRICMP(p1, p2)  stricmp(p1, p2)
#else
#  define CURL_STRICMP(p1, p2)  strcmp(p1, p2)
#endif

#ifdef _WIN32
/* set in init_terminal() */
extern bool tool_term_has_bold;
#endif

#if defined(_WIN32) && !defined(__MINGW32__)
int toolx_ftruncate_win32(int fd, curl_off_t where);
#define toolx_ftruncate toolx_ftruncate_win32
#elif defined(__DJGPP__)
int toolx_ftruncate_djgpp(int fd, curl_off_t where);
#define toolx_ftruncate toolx_ftruncate_djgpp
#elif defined(__AMIGA__)
#define toolx_ftruncate(f, o) ftruncate(f, (off_t)(o))
#else
#define toolx_ftruncate ftruncate
#endif

#ifdef CURL_CA_EMBED
extern const unsigned char curl_ca_embed[];
#endif

#endif /* HEADER_CURL_TOOL_SETUP_H */
