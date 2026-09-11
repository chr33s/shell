/*
 * ios_pipeline.c
 * Pipeline scheduler implementation
 */

#include "ios_pipeline.h"
#include "ios_system.h"
#include "ios_thread_pool.h"
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include <pthread.h>
#include <stdio.h>
#include <signal.h>
#include <unistd.h>

// Maximum stages in a pipeline
#define MAX_PIPELINE_STAGES 32

// Pipeline stage structure
struct _ios_pipeline_stage {
    char* command;                          // Command string
    FILE* stdin_stream;                     // Input stream
    FILE* stdout_stream;                    // Output stream
    FILE* stderr_stream;                    // Error stream
    int pipe_to_next[2];                    // POSIX pipe to next stage [read_fd, write_fd]
    pthread_t thread_id;                    // Thread ID
    _Atomic(ios_pipeline_stage_status_t) status;  // Current status
    _Atomic(int) exit_code;                 // Exit code when completed
    void* session;                          // Session context
    bool stdin_is_external;                 // true if provided by caller, don't close
    bool stdout_is_external;                // true if provided by caller, don't close
    bool stderr_is_external;                // true if provided by caller, don't close
};

// Pipeline structure
struct _ios_pipeline {
    ios_pipeline_stage_t stages[MAX_PIPELINE_STAGES];
    int num_stages;
    bool share_stderr;

    // Synchronization
    pthread_mutex_t mutex;
    pthread_cond_t all_complete;

    // Statistics
    _Atomic(int) running_count;
    _Atomic(int) completed_count;
    _Atomic(bool) all_started;
};

// Helper: Execute a single pipeline stage
static void* pipeline_stage_thread(void* arg) {
    ios_pipeline_stage_t* stage = (ios_pipeline_stage_t*)arg;

    // Mark as running
    atomic_store(&stage->status, IOS_STAGE_RUNNING);

    // Execute the command with redirected I/O
    // ios_system uses both child_* and thread_* variables:
    // - child_* are used to set up params->stdin/stdout/stderr (primary)
    // - thread_* are fallbacks and used during command execution
    extern __thread FILE* thread_stdin;
    extern __thread FILE* thread_stdout;
    extern __thread FILE* thread_stderr;

    // Switch to the correct session context so ios_system picks up
    // session-level state (tty fd, window size, environment, etc.)
    if (stage->session) {
        ios_switchSession(stage->session);
    }

    // Set child streams (for params setup) via the exported function
    extern void ios_setChildStreams(FILE*, FILE*, FILE*);
    ios_setChildStreams(stage->stdin_stream, stage->stdout_stream, stage->stderr_stream);

    // Also set thread streams (for execution fallback)
    thread_stdin = stage->stdin_stream;
    thread_stdout = stage->stdout_stream;
    thread_stderr = stage->stderr_stream;

    // Force ios_system to wait for command completion (otherwise it creates a detached
    // thread and returns immediately, but we need the command to finish before we can
    // clean up streams)
    extern bool joinMainThread;
    bool savedJoinMainThread = joinMainThread;
    joinMainThread = true;

    int result = ios_system(stage->command);

    joinMainThread = savedJoinMainThread;

    // Clear child streams after command completes (ios_system may have already done this)
    ios_setChildStreams(NULL, NULL, NULL);

    // Flush all output streams first to ensure data is written
    if (stage->stdout_stream) {
        fflush(stage->stdout_stream);
    }
    if (stage->stderr_stream && stage->stderr_stream != stage->stdout_stream) {
        fflush(stage->stderr_stream);
    }

    // Close only internally-created streams (buffered pipes between stages)
    // External streams (provided by caller) must NOT be closed here
    if (stage->stdout_stream && !stage->stdout_is_external &&
        stage->stdout_stream != stdout) {
        fclose(stage->stdout_stream);
        stage->stdout_stream = NULL;
    }

    if (stage->stderr_stream && !stage->stderr_is_external &&
        stage->stderr_stream != stderr &&
        stage->stderr_stream != stage->stdout_stream) {
        fclose(stage->stderr_stream);
        stage->stderr_stream = NULL;
    }

    // Close stdin if it was created internally (read end of previous stage's pipe)
    if (stage->stdin_stream && !stage->stdin_is_external &&
        stage->stdin_stream != stdin) {
        fclose(stage->stdin_stream);
        stage->stdin_stream = NULL;
    }

    // Update status and exit code
    atomic_store(&stage->exit_code, result);
    if (result == 0) {
        atomic_store(&stage->status, IOS_STAGE_COMPLETED);
    } else {
        atomic_store(&stage->status, IOS_STAGE_FAILED);
    }

    return NULL;
}

// Helper: Parse command into pipeline stages
static int parse_pipeline(const char* command, char** stages, int max_stages, bool* share_stderr) {
    int num_stages = 0;
    *share_stderr = false;

    // Make a copy we can modify
    char* cmd_copy = strdup(command);
    char* ptr = cmd_copy;
    char* stage_start = ptr;

    // Simple pipeline parsing (doesn't handle quotes properly yet - TODO)
    while (*ptr && num_stages < max_stages) {
        if (*ptr == '|') {
            // Check for &| or |&
            if (ptr > cmd_copy && *(ptr-1) == '&') {
                *share_stderr = true;
                *(ptr-1) = '\0';
            } else if (*(ptr+1) == '&') {
                *share_stderr = true;
                *(ptr+1) = ' ';  // Replace & with space
            }

            *ptr = '\0';  // Terminate current stage

            // Trim spaces
            while (*stage_start == ' ') stage_start++;
            char* stage_end = ptr - 1;
            while (stage_end > stage_start && *stage_end == ' ') {
                *stage_end = '\0';
                stage_end--;
            }

            if (strlen(stage_start) > 0) {
                stages[num_stages++] = strdup(stage_start);
            }

            ptr++;
            stage_start = ptr;
        } else {
            ptr++;
        }
    }

    // Last stage
    if (*stage_start) {
        while (*stage_start == ' ') stage_start++;
        if (strlen(stage_start) > 0) {
            // Remove trailing spaces
            char* end = stage_start + strlen(stage_start) - 1;
            while (end > stage_start && *end == ' ') {
                *end = '\0';
                end--;
            }
            stages[num_stages++] = strdup(stage_start);
        }
    }

    free(cmd_copy);
    return num_stages;
}

/**
 * Execute a pipeline
 */
ios_pipeline_t* ios_pipeline_execute(const char* command, const ios_pipeline_options_t* options) {
    if (!command || !options) {
        return NULL;
    }

    // Release any outer ios_fork() sentinel before dispatching pipeline
    // stages. Each stage runs on its own pthread and may itself call
    // ios_fork() (via substitution, ;, &&, ||, etc. inside the stage's
    // ios_system call). Those forks would deadlock on pid_mtx if a wrapping
    // caller still holds it from its own outer ios_fork(). No-op when no
    // outer fork is active.
    extern void ios_storeThreadId(pthread_t thread);
    ios_storeThreadId(0);

    ios_pipeline_t* pipeline = calloc(1, sizeof(ios_pipeline_t));
    if (!pipeline) {
        return NULL;
    }

    pthread_mutex_init(&pipeline->mutex, NULL);
    pthread_cond_init(&pipeline->all_complete, NULL);
    atomic_init(&pipeline->running_count, 0);
    atomic_init(&pipeline->completed_count, 0);
    atomic_init(&pipeline->all_started, false);

    // Parse pipeline into stages
    char* stage_commands[MAX_PIPELINE_STAGES];
    pipeline->num_stages = parse_pipeline(command, stage_commands, MAX_PIPELINE_STAGES,
                                          &pipeline->share_stderr);

    if (pipeline->num_stages == 0) {
        free(pipeline);
        return NULL;
    }

    // Set up each stage
    for (int i = 0; i < pipeline->num_stages; i++) {
        ios_pipeline_stage_t* stage = &pipeline->stages[i];

        stage->command = stage_commands[i];
        stage->session = options->session;
        atomic_init(&stage->status, IOS_STAGE_PENDING);
        atomic_init(&stage->exit_code, 0);
        stage->pipe_to_next[0] = -1;
        stage->pipe_to_next[1] = -1;
        stage->thread_id = 0;

        // Set up stdin
        if (i == 0) {
            // First stage: use provided input or stdin
            stage->stdin_stream = options->input ? options->input : stdin;
            stage->stdin_is_external = true;  // Provided by caller, don't close
        } else {
            // Read from previous stage's POSIX pipe (read end)
            int prev_read_fd = pipeline->stages[i-1].pipe_to_next[0];
            stage->stdin_stream = fdopen(prev_read_fd, "r");
            if (!stage->stdin_stream) {
                fprintf(stderr, "[ios_pipeline] Failed to fdopen read end of pipe for stage %d\n", i);
            } else {
                // Mark FD as transferred to FILE* (fclose will close it)
                pipeline->stages[i-1].pipe_to_next[0] = -1;
            }
            stage->stdin_is_external = false;  // We created this, we close it
        }

        // Set up stdout
        if (i == pipeline->num_stages - 1) {
            // Last stage: use provided output or stdout
            stage->stdout_stream = options->output ? options->output : stdout;
            stage->stdout_is_external = true;  // Provided by caller, don't close
        } else {
            // Create POSIX pipe to next stage
            if (pipe(stage->pipe_to_next) != 0) {
                fprintf(stderr, "[ios_pipeline] Failed to create pipe for stage %d\n", i);
                // Cleanup and fail
                for (int j = 0; j < i; j++) {
                    free(pipeline->stages[j].command);
                    if (pipeline->stages[j].pipe_to_next[0] >= 0) {
                        close(pipeline->stages[j].pipe_to_next[0]);
                    }
                    if (pipeline->stages[j].pipe_to_next[1] >= 0) {
                        close(pipeline->stages[j].pipe_to_next[1]);
                    }
                }
                free(pipeline->stages[i].command);
                free(pipeline);
                return NULL;
            }
            // pipe_to_next[0] = read end (for next stage's stdin)
            // pipe_to_next[1] = write end (for this stage's stdout)
            stage->stdout_stream = fdopen(stage->pipe_to_next[1], "w");
            if (!stage->stdout_stream) {
                fprintf(stderr, "[ios_pipeline] Failed to fdopen write end of pipe for stage %d\n", i);
            } else {
                // Mark FD as transferred to FILE* (fclose will close it)
                stage->pipe_to_next[1] = -1;
            }
            stage->stdout_is_external = false;  // We created this, we close it
        }

        // Set up stderr
        if (pipeline->share_stderr || i == pipeline->num_stages - 1) {
            // Share stderr with stdout, or use provided error stream for last stage
            if (i == pipeline->num_stages - 1 && options->error) {
                stage->stderr_stream = options->error;
                stage->stderr_is_external = true;  // Provided by caller, don't close
            } else {
                stage->stderr_stream = stage->stdout_stream;
                stage->stderr_is_external = stage->stdout_is_external;  // Inherits from stdout
            }
        } else {
            // Each stage gets its own stderr (TODO: could be optimized)
            stage->stderr_stream = options->error ? options->error : stderr;
            stage->stderr_is_external = (options->error != NULL);  // External if provided
        }
    }

    // Launch all stages in parallel
    for (int i = 0; i < pipeline->num_stages; i++) {
        ios_pipeline_stage_t* stage = &pipeline->stages[i];

        // Create thread for this stage
        if (pthread_create(&stage->thread_id, NULL, pipeline_stage_thread, stage) != 0) {
            fprintf(stderr, "[ios_pipeline] Failed to create thread for stage %d\n", i);
            atomic_store(&stage->status, IOS_STAGE_FAILED);
            atomic_store(&stage->exit_code, -1);
        } else {
            atomic_fetch_add(&pipeline->running_count, 1);
        }
    }

    atomic_store(&pipeline->all_started, true);

    return pipeline;
}

/**
 * Wait for pipeline to complete
 */
int ios_pipeline_wait(ios_pipeline_t* pipeline, int timeout_ms) {
    if (!pipeline) {
        return -1;
    }

    // Wait for all stages to complete
    for (int i = 0; i < pipeline->num_stages; i++) {
        ios_pipeline_stage_t* stage = &pipeline->stages[i];

        if (stage->thread_id != 0) {
            pthread_join(stage->thread_id, NULL);
            stage->thread_id = 0;

            atomic_fetch_sub(&pipeline->running_count, 1);
            atomic_fetch_add(&pipeline->completed_count, 1);
        }
    }

    // Signal completion
    pthread_mutex_lock(&pipeline->mutex);
    pthread_cond_broadcast(&pipeline->all_complete);
    pthread_mutex_unlock(&pipeline->mutex);

    // Return exit code of last stage
    if (pipeline->num_stages > 0) {
        return atomic_load(&pipeline->stages[pipeline->num_stages - 1].exit_code);
    }

    return 0;
}

/**
 * Check if pipeline is complete
 */
bool ios_pipeline_is_complete(ios_pipeline_t* pipeline) {
    if (!pipeline) {
        return true;
    }

    return atomic_load(&pipeline->completed_count) == pipeline->num_stages;
}

/**
 * Get pipeline statistics
 */
int ios_pipeline_get_stats(ios_pipeline_t* pipeline, ios_pipeline_stats_t* stats) {
    if (!pipeline || !stats) {
        return -1;
    }

    stats->num_stages = pipeline->num_stages;
    stats->running_stages = atomic_load(&pipeline->running_count);
    stats->completed_stages = atomic_load(&pipeline->completed_count);
    stats->failed_stages = 0;
    stats->all_started = atomic_load(&pipeline->all_started);
    stats->all_completed = ios_pipeline_is_complete(pipeline);

    // Count failed stages
    for (int i = 0; i < pipeline->num_stages; i++) {
        ios_pipeline_stage_status_t status = atomic_load(&pipeline->stages[i].status);
        if (status == IOS_STAGE_FAILED || status == IOS_STAGE_KILLED) {
            stats->failed_stages++;
        }
    }

    return 0;
}

/**
 * Kill pipeline
 */
int ios_pipeline_kill(ios_pipeline_t* pipeline) {
    if (!pipeline) {
        return -1;
    }

    // Send termination signal to all running stages
    for (int i = 0; i < pipeline->num_stages; i++) {
        ios_pipeline_stage_t* stage = &pipeline->stages[i];
        ios_pipeline_stage_status_t status = atomic_load(&stage->status);

        if (status == IOS_STAGE_RUNNING && stage->thread_id != 0) {
            pthread_kill(stage->thread_id, SIGINT);
            atomic_store(&stage->status, IOS_STAGE_KILLED);
        }
    }

    return 0;
}

/**
 * Destroy pipeline
 */
void ios_pipeline_destroy(ios_pipeline_t* pipeline) {
    if (!pipeline) {
        return;
    }

    // Wait for completion if still running
    if (!ios_pipeline_is_complete(pipeline)) {
        ios_pipeline_wait(pipeline, -1);
    }

    // Free resources
    for (int i = 0; i < pipeline->num_stages; i++) {
        ios_pipeline_stage_t* stage = &pipeline->stages[i];

        if (stage->command) {
            free(stage->command);
        }

        // Close any remaining pipe file descriptors
        // Note: fclose() in stage cleanup already closes the FDs via fdopen
        // but we close remaining unclaimed FDs here just in case
        if (stage->pipe_to_next[0] >= 0) {
            close(stage->pipe_to_next[0]);
            stage->pipe_to_next[0] = -1;
        }
        if (stage->pipe_to_next[1] >= 0) {
            close(stage->pipe_to_next[1]);
            stage->pipe_to_next[1] = -1;
        }
    }

    pthread_mutex_destroy(&pipeline->mutex);
    pthread_cond_destroy(&pipeline->all_complete);

    free(pipeline);
}

/**
 * Get stage information
 */
int ios_pipeline_get_stage_info(ios_pipeline_t* pipeline, int stage_index,
                                  const char** command, ios_pipeline_stage_status_t* status,
                                  int* exit_code) {
    if (!pipeline || stage_index < 0 || stage_index >= pipeline->num_stages) {
        return -1;
    }

    ios_pipeline_stage_t* stage = &pipeline->stages[stage_index];

    if (command) {
        *command = stage->command;
    }

    if (status) {
        *status = atomic_load(&stage->status);
    }

    if (exit_code) {
        *exit_code = atomic_load(&stage->exit_code);
    }

    return 0;
}
