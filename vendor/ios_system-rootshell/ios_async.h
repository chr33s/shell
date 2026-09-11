/*
 * ios_async.h
 * Asynchronous command execution API for ios_system
 *
 * Provides non-blocking command execution with status monitoring,
 * completion callbacks, and proper resource management.
 */

#ifndef IOS_ASYNC_H
#define IOS_ASYNC_H

#include <stdio.h>
#include <stdbool.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

// Forward declaration of command handle (opaque to callers)
typedef struct _ios_command_handle ios_command_t;

// Command execution status
typedef enum {
    IOS_CMD_PENDING,        // Not yet started
    IOS_CMD_RUNNING,        // Currently executing
    IOS_CMD_COMPLETED,      // Finished successfully (exit code 0)
    IOS_CMD_FAILED,         // Finished with error (exit code != 0)
    IOS_CMD_KILLED,         // Terminated by signal
    IOS_CMD_TIMEOUT         // Exceeded timeout (if applicable)
} ios_command_status_t;

// Completion callback function type
typedef void (*ios_command_callback_t)(ios_command_t* cmd, int exit_code, void* user_data);

// Asynchronous command execution options
typedef struct {
    FILE* input;                        // stdin for command (or NULL)
    FILE* output;                       // stdout for command (or NULL)
    FILE* error;                        // stderr for command (or NULL)
    void* session;                      // Session context (or NULL)
    ios_command_callback_t callback;    // Completion callback (or NULL)
    void* callback_data;                // User data passed to callback
    int timeout_ms;                     // Timeout in milliseconds (-1 = none)
} ios_async_options_t;

/**
 * Execute command asynchronously
 *
 * Launches the command in a background thread and returns immediately.
 * The returned handle can be used to query status, wait for completion,
 * or kill the command.
 *
 * @param command Command string to execute (e.g., "ls -la")
 * @param options Execution options (or NULL for defaults)
 * @return Command handle or NULL on error
 *
 * Example:
 *   ios_async_options_t opts = {
 *       .input = stdin,
 *       .output = stdout,
 *       .error = stderr,
 *       .session = currentSession,
 *       .callback = my_completion_handler,
 *       .callback_data = user_data,
 *       .timeout_ms = -1
 *   };
 *   ios_command_t* cmd = ios_system_async("grep pattern file.txt", &opts);
 *   // ... do other work ...
 *   int exit_code = ios_command_wait(cmd);
 *   ios_command_release(cmd);
 */
ios_command_t* ios_system_async(const char* command, const ios_async_options_t* options);

/**
 * Wait for command to complete
 *
 * Blocks until the command finishes executing and returns its exit code.
 * Safe to call multiple times on the same command.
 *
 * @param cmd Command handle
 * @return Exit code of command, or -1 if cmd is NULL or invalid
 */
int ios_command_wait(ios_command_t* cmd);

/**
 * Try to wait for command (non-blocking)
 *
 * Checks if command has completed without blocking.
 *
 * @param cmd Command handle
 * @param exit_code Output: exit code if command is done (or NULL)
 * @return true if command is done, false if still running
 */
bool ios_command_try_wait(ios_command_t* cmd, int* exit_code);

/**
 * Get current command status
 *
 * Returns the current execution status of the command.
 *
 * @param cmd Command handle
 * @return Current status
 */
ios_command_status_t ios_command_get_status(ios_command_t* cmd);

/**
 * Get command exit code (if completed)
 *
 * Returns the exit code if command has finished, or -1 if still running.
 *
 * @param cmd Command handle
 * @return Exit code or -1 if not yet finished
 */
int ios_command_get_exit_code(ios_command_t* cmd);

/**
 * Get command PID
 *
 * Returns the process ID associated with this command.
 *
 * @param cmd Command handle
 * @return PID or -1 if cmd is NULL
 */
pid_t ios_command_get_pid(ios_command_t* cmd);

/**
 * Get command string
 *
 * Returns the command string that was executed.
 *
 * @param cmd Command handle
 * @return Command string or NULL if cmd is NULL
 */
const char* ios_command_get_string(ios_command_t* cmd);

/**
 * Kill running command
 *
 * Requests command cancellation if it's still running.
 * The command is marked killed only after the worker thread actually exits.
 *
 * @param cmd Command handle
 * @return 0 on success, -1 on error
 */
int ios_command_kill(ios_command_t* cmd);

/**
 * Release command handle
 *
 * Frees resources associated with the command handle.
 * If command is still running, waits for it to complete first.
 * Always call this when done with a command handle.
 *
 * @param cmd Command handle to release
 */
void ios_command_release(ios_command_t* cmd);

/**
 * Set completion callback
 *
 * Registers a callback to be invoked when the command completes.
 * Can be called before or after the command starts.
 * If command has already finished, callback is invoked immediately.
 *
 * @param cmd Command handle
 * @param callback Callback function
 * @param user_data User data passed to callback
 * @return 0 on success, -1 on error
 */
int ios_command_set_callback(ios_command_t* cmd, ios_command_callback_t callback, void* user_data);

// Convenience functions

/**
 * Execute command and wait for completion (same as ios_system)
 *
 * Equivalent to:
 *   ios_command_t* cmd = ios_system_async(command, options);
 *   int result = ios_command_wait(cmd);
 *   ios_command_release(cmd);
 *
 * @param command Command string
 * @param options Execution options (or NULL)
 * @return Exit code
 */
int ios_system_sync(const char* command, const ios_async_options_t* options);

/**
 * Execute command with timeout
 *
 * Executes command and waits up to timeout_ms milliseconds.
 * Returns IOS_CMD_TIMEOUT if command doesn't finish in time.
 *
 * @param command Command string
 * @param options Execution options (or NULL)
 * @param timeout_ms Timeout in milliseconds
 * @return Exit code or -1 if timeout
 */
int ios_system_timeout(const char* command, const ios_async_options_t* options, int timeout_ms);

/**
 * Get default async options
 *
 * Returns a default-initialized options structure.
 * All fields set to NULL/0/-1.
 */
ios_async_options_t ios_async_default_options(void);

#ifdef __cplusplus
}
#endif

#endif /* IOS_ASYNC_H */
