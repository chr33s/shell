#include "PTYSpawn.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <util.h>

int shell_spawn_pty(const char *executable, char *const argv[], char *const envp[],
                    const char *directory, unsigned short rows, unsigned short columns,
                    int *master, pid_t *child) {
    int slave, failure[2];
    struct winsize size = {.ws_row = rows, .ws_col = columns};
    if (openpty(master, &slave, NULL, NULL, &size) < 0) return errno;
    if (pipe(failure) < 0) {
        int code = errno; close(*master); close(slave); return code;
    }
    fcntl(*master, F_SETFD, FD_CLOEXEC);
    fcntl(slave, F_SETFD, FD_CLOEXEC);
    fcntl(failure[0], F_SETFD, FD_CLOEXEC);
    fcntl(failure[1], F_SETFD, FD_CLOEXEC);
    int descriptor_limit = getdtablesize();
    *child = fork();
    if (*child == 0) {
        int code;
        close(failure[0]);
        if (setsid() < 0 || ioctl(slave, TIOCSCTTY, 0) < 0) goto failed;
        for (int fd = 0; fd < 3; fd++) if (dup2(slave, fd) < 0) goto failed;
        for (int fd = 3; fd < descriptor_limit; fd++) if (fd != failure[1]) close(fd);
        sigset_t empty;
        sigemptyset(&empty);
        sigprocmask(SIG_SETMASK, &empty, NULL);
        struct sigaction action;
        memset(&action, 0, sizeof(action));
        action.sa_handler = SIG_DFL;
        sigemptyset(&action.sa_mask);
        for (int sig = 1; sig < NSIG; sig++) {
            if (sig != SIGKILL && sig != SIGSTOP) sigaction(sig, &action, NULL);
        }
        if (chdir(directory) < 0) goto failed;
        execve(executable, argv, envp);
    failed:
        code = errno;
        (void)write(failure[1], &code, sizeof(code));
        _exit(127);
    }
    int fork_error = errno;
    close(slave);
    close(failure[1]);
    if (*child < 0) {
        close(failure[0]); close(*master); return fork_error;
    }
    int code = 0;
    ssize_t count;
    do { count = read(failure[0], &code, sizeof(code)); } while (count < 0 && errno == EINTR);
    close(failure[0]);
    if (count != 0) {
        if (count < 0) code = errno;
        kill(*child, SIGKILL);
        while (waitpid(*child, NULL, 0) < 0 && errno == EINTR) {}
        close(*master);
        return code ? code : EIO;
    }
    return 0;
}
