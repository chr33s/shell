/*
 * jq_ios.h - jq JSON processor framework for iOS/visionOS/Mac Catalyst
 *
 * This framework provides the jq JSON processor as a thread-safe library
 * for use in iOS applications, particularly with ios_system for terminal
 * emulators.
 *
 * Features:
 * - Thread-safe execution of multiple jq instances concurrently
 * - Compatible with ios_system's per-thread I/O redirection
 * - Full jq functionality including regex (oniguruma)
 *
 * Usage as ios_system command:
 *   The jq_main() function is the entry point called by ios_system.
 *   ios_system handles setting up thread-local stdin/stdout/stderr.
 *
 * Usage as library:
 *   Use jq_init(), jq_compile(), jq_start(), jq_next(), jq_teardown()
 *   from jq.h for fine-grained control.
 *   Or use jq_process_string() for simple one-shot processing.
 */

#ifndef JQ_IOS_H
#define JQ_IOS_H

#include <stdio.h>

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#endif

/* Framework version info */
extern const double jq_iosVersionNumber;
extern const unsigned char jq_iosVersionString[];

/*
 * Main entry point for ios_system integration.
 *
 * This is the function called by ios_system when the user runs "jq".
 * It processes command-line arguments and executes the jq filter.
 *
 * Before calling this function, ios_system sets up thread-local
 * stdin/stdout/stderr streams which jq_ios automatically uses.
 *
 * Parameters:
 *   argc - Number of command-line arguments
 *   argv - Array of argument strings (argv[0] is typically "jq")
 *
 * Returns:
 *   0 on success
 *   1 if --exit-status is set and the last output was false/null
 *   2 on system error (file not found, etc.)
 *   3 on compile error (invalid jq filter)
 *   4 if --exit-status is set and no valid results were produced
 *   5 on unknown/uncaught error
 */
#ifdef __cplusplus
extern "C"
#endif
int jq_main(int argc, char* argv[]);

/*
 * Simple string-based jq processing API.
 *
 * This provides a convenient way to run a jq filter on a JSON string
 * and get the results back as strings, without dealing with the
 * lower-level jq_state API.
 *
 * Parameters:
 *   filter     - The jq filter expression (e.g., ".foo", ".[0]", "select(.x > 5)")
 *   input_json - The input JSON as a string
 *   output     - Pointer to receive allocated output string (caller must free)
 *   error      - Pointer to receive allocated error string if any (caller must free)
 *
 * Returns:
 *   0 on success (*output contains result, *error is NULL)
 *   Non-zero on error (*error contains message, *output may be NULL)
 *
 * Example:
 *   char *output = NULL, *error = NULL;
 *   if (jq_process_string(".foo", "{\"foo\": 42}", &output, &error) == 0) {
 *       printf("Result: %s\n", output);  // Prints: Result: 42
 *       free(output);
 *   } else {
 *       fprintf(stderr, "Error: %s\n", error);
 *       free(error);
 *   }
 */
#ifdef __cplusplus
extern "C"
#endif
int jq_process_string(const char* filter, const char* input_json,
                      char** output, char** error);

/*
 * Process JSON with a jq filter, writing to a FILE stream.
 *
 * Similar to jq_process_string but writes output directly to a stream,
 * useful for large outputs or streaming scenarios.
 *
 * Parameters:
 *   filter     - The jq filter expression
 *   input_json - The input JSON as a string
 *   out        - Output stream (use jq_ios_stdout() for thread-local stdout)
 *   err        - Error stream (use jq_ios_stderr() for thread-local stderr)
 *   flags      - Output flags (JV_PRINT_PRETTY, JV_PRINT_COLOR, etc.)
 *
 * Returns:
 *   0 on success
 *   Non-zero on error
 */
#ifdef __cplusplus
extern "C"
#endif
int jq_process_to_stream(const char* filter, const char* input_json,
                         FILE* out, FILE* err, int flags);

#endif /* JQ_IOS_H */
