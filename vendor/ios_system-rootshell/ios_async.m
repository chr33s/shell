/*
 * ios_async.c
 * Asynchronous command execution implementation
 */

#include "ios_async.h"
#include "ios_system.h"
#include "ios_pid_allocator.h"
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include <pthread.h>
#include <signal.h>
#include <errno.h>
#include <sys/time.h>
#include <stdio.h>

// Command handle structure
struct _ios_command_handle {
    char* command;                          // Command string
    pid_t pid;                              // Process ID
    pthread_t thread_id;                    // Execution thread

    // I/O streams
    FILE* input;
    FILE* output;
    FILE* error;
    void* session;
    bool owns_session;

    // Status tracking
    _Atomic(ios_command_status_t) status;   // Current status
    _Atomic(int) exit_code;                 // Exit code when done
    _Atomic(bool) kill_requested;           // Cooperative kill requested

    // Synchronization
    pthread_mutex_t mutex;                  // Protects mutable state
    pthread_cond_t done;                    // Signaled when command completes

    // Completion callback
    ios_command_callback_t callback;
    void* callback_data;
    bool callback_invoked;

    // Timeout support
    int timeout_ms;
    struct timeval start_time;

    // Reference counting for safe cleanup
    _Atomic(int) ref_count;
};

// Forward declarations
static void* command_thread_func(void* arg);
static void invoke_callback_if_set(ios_command_t* cmd, int exit_code);
static bool check_timeout(ios_command_t* cmd);

/**
 * Get default async options
 */
ios_async_options_t ios_async_default_options(void) {
    ios_async_options_t opts = {
        .input = NULL,
        .output = NULL,
        .error = NULL,
        .session = NULL,
        .callback = NULL,
        .callback_data = NULL,
        .timeout_ms = -1
    };
    return opts;
}

/**
 * Command execution thread
 */
static void* command_thread_func(void* arg) {
    ios_command_t* cmd = (ios_command_t*)arg;

    // Increment ref count to prevent early free while thread is still running.
    // The caller may call ios_command_release() after ios_command_wait() returns,
    // but we're still executing (about to call invoke_callback_if_set).
    atomic_fetch_add(&cmd->ref_count, 1);

    // Update status to running
    atomic_store(&cmd->status, IOS_CMD_RUNNING);

    // Switch to the correct session context BEFORE setting up streams
    // This is critical for ios_kill_session() to find the right thread
    if (cmd->session != NULL) {
        extern void ios_switchSession(const void* sessionId);
        ios_switchSession(cmd->session);
    }

    // Set up thread-local I/O streams
    extern __thread FILE* thread_stdin;
    extern __thread FILE* thread_stdout;
    extern __thread FILE* thread_stderr;

    thread_stdin = cmd->input ? cmd->input : stdin;
    thread_stdout = cmd->output ? cmd->output : stdout;
    thread_stderr = cmd->error ? cmd->error : stderr;

    // Execute the command
    int result = ios_system(cmd->command);

    pthread_mutex_lock(&cmd->mutex);

    // Store exit code
    atomic_store(&cmd->exit_code, result);

    // Check if timed out
    if (check_timeout(cmd)) {
        atomic_store(&cmd->status, IOS_CMD_TIMEOUT);
    } else if (atomic_load(&cmd->kill_requested)) {
        atomic_store(&cmd->status, IOS_CMD_KILLED);
    } else if (result == 0) {
        atomic_store(&cmd->status, IOS_CMD_COMPLETED);
    } else {
        atomic_store(&cmd->status, IOS_CMD_FAILED);
    }

    // Signal completion
    pthread_cond_broadcast(&cmd->done);

    pthread_mutex_unlock(&cmd->mutex);

    // Invoke callback if set
    invoke_callback_if_set(cmd, result);

    if (cmd->owns_session && cmd->session != NULL) {
        ios_closeSession(cmd->session);
    }

    // Release the reference we took at the start of this function.
    // This ensures cmd stays valid until we're completely done.
    ios_command_release(cmd);

    return NULL;
}

/**
 * Check if command has timed out
 */
static bool check_timeout(ios_command_t* cmd) {
    if (cmd->timeout_ms < 0) {
        return false;  // No timeout set
    }

    struct timeval now;
    gettimeofday(&now, NULL);

    long elapsed_ms = ((now.tv_sec - cmd->start_time.tv_sec) * 1000) +
                      ((now.tv_usec - cmd->start_time.tv_usec) / 1000);

    return elapsed_ms >= cmd->timeout_ms;
}

/**
 * Invoke completion callback if set
 */
static void invoke_callback_if_set(ios_command_t* cmd, int exit_code) {
    pthread_mutex_lock(&cmd->mutex);

    if (cmd->callback && !cmd->callback_invoked) {
        cmd->callback_invoked = true;
        pthread_mutex_unlock(&cmd->mutex);

        // Invoke callback without holding mutex (avoid deadlock)
        cmd->callback(cmd, exit_code, cmd->callback_data);
    } else {
        pthread_mutex_unlock(&cmd->mutex);
    }
}

/**
 * Execute command asynchronously
 */
ios_command_t* ios_system_async(const char* command, const ios_async_options_t* options) {
    if (!command) {
        return NULL;
    }

    // Allocate command handle
    ios_command_t* cmd = calloc(1, sizeof(ios_command_t));
    if (!cmd) {
        return NULL;
    }

    // Copy command string
    cmd->command = strdup(command);
    if (!cmd->command) {
        free(cmd);
        return NULL;
    }

    // Initialize I/O streams
    const void* session_id = ios_getContext();
    bool owns_session = false;
    if (options) {
        cmd->input = options->input;
        cmd->output = options->output;
        cmd->error = options->error;
        if (options->session != NULL) {
            session_id = options->session;
        }
        if (session_id == NULL) {
            session_id = cmd;
            owns_session = true;
        }
        cmd->session = (void*)session_id;
        cmd->callback = options->callback;
        cmd->callback_data = options->callback_data;
        cmd->timeout_ms = options->timeout_ms;
    } else {
        cmd->input = NULL;
        cmd->output = NULL;
        cmd->error = NULL;
        if (session_id == NULL) {
            session_id = cmd;
            owns_session = true;
        }
        cmd->session = (void*)session_id;
        cmd->callback = NULL;
        cmd->callback_data = NULL;
        cmd->timeout_ms = -1;
    }

    // Initialize synchronization
    pthread_mutex_init(&cmd->mutex, NULL);
    pthread_cond_init(&cmd->done, NULL);
    cmd->callback_invoked = false;
    cmd->owns_session = owns_session;

    // Initialize status
    atomic_init(&cmd->status, IOS_CMD_PENDING);
    atomic_init(&cmd->exit_code, -1);
    atomic_init(&cmd->kill_requested, false);
    atomic_init(&cmd->ref_count, 1);  // Initial reference

    // Record start time for timeout checking
    gettimeofday(&cmd->start_time, NULL);

    // Create execution thread
    if (pthread_create(&cmd->thread_id, NULL, command_thread_func, cmd) != 0) {
        // Only log errors, not routine operations
        NSLog(@"[ios_async] Failed to create thread for command: %s", command);
        free(cmd->command);
        pthread_mutex_destroy(&cmd->mutex);
        pthread_cond_destroy(&cmd->done);
        free(cmd);
        return NULL;
    }

    // Detach thread (we'll join manually in wait/release)
    pthread_detach(cmd->thread_id);

    return cmd;
}

/**
 * Wait for command to complete
 */
int ios_command_wait(ios_command_t* cmd) {
    if (!cmd) {
        return -1;
    }

    pthread_mutex_lock(&cmd->mutex);

    // Wait for completion
    while (atomic_load(&cmd->status) == IOS_CMD_PENDING ||
           atomic_load(&cmd->status) == IOS_CMD_RUNNING) {

        // Check for timeout
        if (cmd->timeout_ms >= 0 && check_timeout(cmd)) {
            atomic_store(&cmd->status, IOS_CMD_TIMEOUT);
            pthread_cond_broadcast(&cmd->done);
            break;
        }

        pthread_cond_wait(&cmd->done, &cmd->mutex);
    }

    int exit_code = atomic_load(&cmd->exit_code);
    pthread_mutex_unlock(&cmd->mutex);

    return exit_code;
}

/**
 * Try to wait for command (non-blocking)
 */
bool ios_command_try_wait(ios_command_t* cmd, int* exit_code) {
    if (!cmd) {
        return false;
    }

    ios_command_status_t status = atomic_load(&cmd->status);

    if (status == IOS_CMD_PENDING || status == IOS_CMD_RUNNING) {
        return false;  // Still running
    }

    // Command is done
    if (exit_code) {
        *exit_code = atomic_load(&cmd->exit_code);
    }

    return true;
}

/**
 * Get current command status
 */
ios_command_status_t ios_command_get_status(ios_command_t* cmd) {
    if (!cmd) {
        return IOS_CMD_FAILED;
    }

    return atomic_load(&cmd->status);
}

/**
 * Get command exit code (if completed)
 */
int ios_command_get_exit_code(ios_command_t* cmd) {
    if (!cmd) {
        return -1;
    }

    ios_command_status_t status = atomic_load(&cmd->status);

    if (status == IOS_CMD_PENDING || status == IOS_CMD_RUNNING) {
        return -1;  // Not finished yet
    }

    return atomic_load(&cmd->exit_code);
}

/**
 * Get command PID
 */
pid_t ios_command_get_pid(ios_command_t* cmd) {
    return cmd ? cmd->pid : -1;
}

/**
 * Get command string
 */
const char* ios_command_get_string(ios_command_t* cmd) {
    return cmd ? cmd->command : NULL;
}

/**
 * Kill running command
 */
int ios_command_kill(ios_command_t* cmd) {
    if (!cmd) {
        return -1;
    }

    pthread_mutex_lock(&cmd->mutex);

    ios_command_status_t status = atomic_load(&cmd->status);

    if (status != IOS_CMD_RUNNING) {
        pthread_mutex_unlock(&cmd->mutex);
        return 0;  // Already finished
    }

    atomic_store(&cmd->kill_requested, true);

    int result = ios_kill_session(cmd->session);

    pthread_mutex_unlock(&cmd->mutex);

    return result;
}

/**
 * Release command handle
 */
void ios_command_release(ios_command_t* cmd) {
    if (!cmd) {
        return;
    }

    // Decrement reference count
    int prev_count = atomic_fetch_sub(&cmd->ref_count, 1);
    if (prev_count > 1) {
        return;  // Still has references
    }

    // Wait for command to complete if still running
    ios_command_status_t status = atomic_load(&cmd->status);
    if (status == IOS_CMD_PENDING || status == IOS_CMD_RUNNING) {
        ios_command_wait(cmd);
    }

    // Free resources
    free(cmd->command);
    pthread_mutex_destroy(&cmd->mutex);
    pthread_cond_destroy(&cmd->done);
    free(cmd);
}

/**
 * Set completion callback
 */
int ios_command_set_callback(ios_command_t* cmd, ios_command_callback_t callback, void* user_data) {
    if (!cmd) {
        return -1;
    }

    pthread_mutex_lock(&cmd->mutex);

    cmd->callback = callback;
    cmd->callback_data = user_data;

    // If command already finished and callback not yet invoked, invoke it now
    ios_command_status_t status = atomic_load(&cmd->status);
    bool already_done = (status != IOS_CMD_PENDING && status != IOS_CMD_RUNNING);
    bool not_invoked = !cmd->callback_invoked;

    pthread_mutex_unlock(&cmd->mutex);

    if (already_done && not_invoked && callback) {
        int exit_code = atomic_load(&cmd->exit_code);
        invoke_callback_if_set(cmd, exit_code);
    }

    return 0;
}

/**
 * Execute command and wait for completion (synchronous wrapper)
 */
int ios_system_sync(const char* command, const ios_async_options_t* options) {
    ios_command_t* cmd = ios_system_async(command, options);
    if (!cmd) {
        return -1;
    }

    int result = ios_command_wait(cmd);
    ios_command_release(cmd);

    return result;
}

/**
 * Execute command with timeout
 */
int ios_system_timeout(const char* command, const ios_async_options_t* options, int timeout_ms) {
    ios_async_options_t opts = options ? *options : ios_async_default_options();
    opts.timeout_ms = timeout_ms;

    ios_command_t* cmd = ios_system_async(command, &opts);
    if (!cmd) {
        return -1;
    }

    int result = ios_command_wait(cmd);

    // Check if timed out
    if (ios_command_get_status(cmd) == IOS_CMD_TIMEOUT) {
        ios_command_kill(cmd);
        result = -1;
    }

    ios_command_release(cmd);

    return result;
}
