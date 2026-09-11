/*
 * ios_pipeline.h
 * Pipeline scheduler for parallel command execution
 *
 * Enables true pipeline parallelism by launching all stages concurrently
 * and connecting them with buffered pipes. Replaces the recursive ios_popen()
 * approach which executed stages sequentially.
 */

#ifndef IOS_PIPELINE_H
#define IOS_PIPELINE_H

#include <stdio.h>
#include <stdbool.h>
#include <pthread.h>
#include "ios_buffered_pipe.h"

#ifdef __cplusplus
extern "C" {
#endif

// Forward declarations
typedef struct _ios_pipeline ios_pipeline_t;
typedef struct _ios_pipeline_stage ios_pipeline_stage_t;

// Pipeline execution options
typedef struct {
    bool share_stderr;      // If true, all stages share stderr (|&)
    FILE* input;            // Initial input (or NULL for stdin)
    FILE* output;           // Final output (or NULL for stdout)
    FILE* error;            // Error output (or NULL for stderr)
    void* session;          // Session context
} ios_pipeline_options_t;

// Pipeline stage status
typedef enum {
    IOS_STAGE_PENDING,      // Not yet started
    IOS_STAGE_RUNNING,      // Currently executing
    IOS_STAGE_COMPLETED,    // Finished successfully
    IOS_STAGE_FAILED,       // Finished with error
    IOS_STAGE_KILLED        // Terminated by signal
} ios_pipeline_stage_status_t;

// Pipeline statistics
typedef struct {
    int num_stages;         // Total number of stages
    int running_stages;     // Currently executing
    int completed_stages;   // Successfully finished
    int failed_stages;      // Failed or killed
    bool all_started;       // All stages have been launched
    bool all_completed;     // All stages have finished
} ios_pipeline_stats_t;

/**
 * Parse and execute a pipeline command
 *
 * Parses the command string into pipeline stages, creates buffered pipes
 * between them, and launches all stages concurrently for parallel execution.
 *
 * @param command Pipeline command string (e.g., "cat file | grep foo | wc -l")
 * @param options Execution options (I/O streams, session context)
 * @return Pipeline handle or NULL on error
 *
 * Example:
 *   ios_pipeline_options_t opts = {
 *       .share_stderr = false,
 *       .input = stdin,
 *       .output = stdout,
 *       .error = stderr,
 *       .session = currentSession
 *   };
 *   ios_pipeline_t* pipeline = ios_pipeline_execute("cmd1 | cmd2 | cmd3", &opts);
 *   int result = ios_pipeline_wait(pipeline, -1);
 *   ios_pipeline_destroy(pipeline);
 */
ios_pipeline_t* ios_pipeline_execute(const char* command, const ios_pipeline_options_t* options);

/**
 * Wait for pipeline to complete
 *
 * Blocks until all stages finish or timeout expires.
 *
 * @param pipeline Pipeline handle
 * @param timeout_ms Timeout in milliseconds (-1 = infinite)
 * @return Exit code of last stage, or -1 on timeout/error
 *
 * Returns the exit code of the last stage in the pipeline (rightmost command).
 * If any stage fails early, may return that stage's exit code.
 */
int ios_pipeline_wait(ios_pipeline_t* pipeline, int timeout_ms);

/**
 * Check if pipeline has completed
 *
 * @param pipeline Pipeline handle
 * @return true if all stages finished, false otherwise
 */
bool ios_pipeline_is_complete(ios_pipeline_t* pipeline);

/**
 * Get pipeline statistics
 *
 * @param pipeline Pipeline handle
 * @param stats Output: statistics structure
 * @return 0 on success, -1 on error
 */
int ios_pipeline_get_stats(ios_pipeline_t* pipeline, ios_pipeline_stats_t* stats);

/**
 * Kill pipeline
 *
 * Sends termination signal to all running stages.
 *
 * @param pipeline Pipeline handle
 * @return 0 on success, -1 on error
 */
int ios_pipeline_kill(ios_pipeline_t* pipeline);

/**
 * Destroy pipeline and free resources
 *
 * Waits for stages to complete if still running, then frees all resources.
 *
 * @param pipeline Pipeline handle
 */
void ios_pipeline_destroy(ios_pipeline_t* pipeline);

/**
 * Get stage information
 *
 * @param pipeline Pipeline handle
 * @param stage_index Stage index (0-based)
 * @param command Output: command string (or NULL)
 * @param status Output: stage status (or NULL)
 * @param exit_code Output: exit code if completed (or NULL)
 * @return 0 on success, -1 if stage_index out of range
 */
int ios_pipeline_get_stage_info(ios_pipeline_t* pipeline, int stage_index,
                                  const char** command, ios_pipeline_stage_status_t* status,
                                  int* exit_code);

#ifdef __cplusplus
}
#endif

#endif /* IOS_PIPELINE_H */
