// config.h for libarchive_ios — iOS/Darwin feature definitions
// This replaces the CMake-generated config.h for the tool sources

#ifndef LIBARCHIVE_IOS_CONFIG_H
#define LIBARCHIVE_IOS_CONFIG_H

// Standard C headers available on iOS/Darwin
#define HAVE_CTYPE_H 1
#define HAVE_DIRENT_H 1
#define HAVE_ERRNO_H 1
#define HAVE_FCNTL_H 1
#define HAVE_GRP_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_LANGINFO_H 1
#define HAVE_LIMITS_H 1
#define HAVE_LOCALE_H 1
#define HAVE_MEMORY_H 1
#define HAVE_PATHS_H 1
#define HAVE_PWD_H 1
#define HAVE_SIGNAL_H 1
#define HAVE_STDARG_H 1
#define HAVE_STDBOOL_H 1
#define HAVE_STDINT_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_STRINGS_H 1
#define HAVE_SYS_PARAM_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TIME_H 1
#define HAVE_TIME_H 1
#define HAVE_UNISTD_H 1

// POSIX features available on iOS/Darwin
#define HAVE_DIRENT_D_NAMLEN 1
#define HAVE_FNMATCH 1
#define HAVE_FNMATCH_H 1
#define HAVE_FUTIMENS 1
#define HAVE_FUTIMES 1
#define HAVE_GETOPT_OPTRESET 1
#define HAVE_LOCALTIME_R 1
#define HAVE_LUTIMES 1
#define HAVE_READPASSPHRASE 1
#define HAVE_READPASSPHRASE_H 1
#define HAVE_REGEX_H 1
// HAVE_SETLOCALE - disabled on iOS: env vars aren't set in ios_system,
// so setlocale(LC_ALL,"") always fails with a noisy warning. The C locale
// default is fine.
// #define HAVE_SETLOCALE 1
#define HAVE_SIGACTION 1
#define HAVE_STRUCT_STAT_ST_MTIMESPEC_TV_NSEC 1
#define HAVE_UTIMENSAT 1
#define HAVE_UTIMES 1

// Darwin-specific
#define HAVE_COPYFILE_H 1
#define HAVE_D_MD_ORDER 1
#define HAVE_NL_LANGINFO 1

// Version strings for libarchive tools
#define BSDTAR_VERSION_STRING "3.9.0"
#define BSDCAT_VERSION_STRING "3.9.0"
#define BSDCPIO_VERSION_STRING "3.9.0"
#define BSDUNZIP_VERSION_STRING "3.9.0"

// Not on iOS
// #define HAVE_LIBACL 1
// #define _PATH_DEFTAPE

// printf-like attribute for static analysis
#ifndef __LA_PRINTFLIKE
#if defined(__GNUC__) && (__GNUC__ > 2 || \
                          (__GNUC__ == 2 && __GNUC_MINOR__ >= 5))
#define __LA_PRINTFLIKE(f, a) __attribute__((__format__(__printf__, f, a)))
#else
#define __LA_PRINTFLIKE(f, a)
#endif
#endif

#endif // LIBARCHIVE_IOS_CONFIG_H
