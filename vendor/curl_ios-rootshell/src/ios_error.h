#ifndef IOS_ERROR_H
#define IOS_ERROR_H

#include <stdio.h>
#include <stdbool.h>
#include <sys/signal.h>

extern __thread FILE* thread_stdin;
extern __thread FILE* thread_stdout;
extern __thread FILE* thread_stderr;

/* ios_system cooperative cancellation API */
extern bool ios_sessionCancelRequested(void);
extern int ios_sessionCancelFD(void);
extern sig_t ios_signal(int signal, sig_t function);

#endif /* IOS_ERROR_H */
