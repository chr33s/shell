// libarchive_ios_globals.c — Thread-local global definitions for iOS exit interception

#include <setjmp.h>

__thread jmp_buf libarchive_ios_exit_jmpbuf;
__thread int libarchive_ios_exit_status;
