#ifndef SHELL_PTY_SPAWN_H
#define SHELL_PTY_SPAWN_H
#include <sys/types.h>
/// All allocations and argument construction happen before fork. The child uses
/// only C system calls before exec; it never enters Swift or Objective-C.
int shell_spawn_pty(const char *executable, char *const argv[], char *const envp[],
                    const char *directory, unsigned short rows, unsigned short columns,
                    int *master, pid_t *child);
#endif
