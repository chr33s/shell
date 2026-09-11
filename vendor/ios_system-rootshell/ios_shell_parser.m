/*
 * ios_shell_parser.m
 * Shell parsing for sequential, conditional, and command substitution execution
 */

#import <Foundation/Foundation.h>
#include "ios_shell_parser.h"
#include "ios_system.h"
#include "ios_buffered_pipe.h"
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

// External declarations from ios_system.m
extern char* strstrquoted(char* str1, char* str2);
extern __thread FILE* thread_stdin;
extern __thread FILE* thread_stdout;
extern __thread FILE* thread_stderr;
extern void ios_setChildStreams(FILE* _stdin, FILE* _stdout, FILE* _stderr);
extern pid_t ios_fork(void);
extern void ios_waitpid(pid_t pid);
extern void ios_storeThreadId(pthread_t thread);
extern pid_t ios_currentPid(void);
extern void ios_setCurrentPid(pid_t pid);
extern bool joinMainThread;

// Consume the outer ios_fork() sentinel for this thread, mirroring what
// run_function/cleanup_function would do for an asynchronous dispatch:
// restore current_pid to the parent and clear the slot. No-op when no
// outer fork is active (sentinel != -1).
//
// Used by the synchronous-recursive wrappers ios_execute_sequential(),
// ios_execute_conditional(), and ios_pipeline_execute() — they fully
// consume their command synchronously, so by the time they return, the
// outer caller's ios_waitpid() should observe the slot as freed.
//
// Substitution (capture_command_output) does NOT use this — substitution
// is only an intermediate step inside ios_system, and post-substitution
// work may still need to dispatch under the outer pid. capture_command_output
// preserves the outer pid via save/restore of current_pid instead.
static inline void release_outer_fork_sentinel(void) {
    ios_storeThreadId(0);
}

#pragma mark - Helper Functions

/**
 * Trim leading and trailing whitespace from a string in place
 */
static char* trim_whitespace(char* str) {
    if (str == NULL) return NULL;

    // Trim leading
    while (*str == ' ' || *str == '\t') str++;

    if (*str == '\0') return str;

    // Trim trailing
    char* end = str + strlen(str) - 1;
    while (end > str && (*end == ' ' || *end == '\t')) {
        *end = '\0';
        end--;
    }

    return str;
}

/**
 * Find matching closing parenthesis for $(, handling nesting
 */
static char* find_matching_paren(const char* start) {
    if (start == NULL) return NULL;

    int depth = 1;
    bool in_single_quote = false;
    bool in_double_quote = false;
    const char* ptr = start;

    while (*ptr != '\0' && depth > 0) {
        char ch = *ptr;

        // Handle quotes
        if (!in_single_quote && ch == '"') {
            in_double_quote = !in_double_quote;
        } else if (!in_double_quote && ch == '\'') {
            in_single_quote = !in_single_quote;
        }
        // Handle parentheses (only outside quotes)
        else if (!in_single_quote && !in_double_quote) {
            if (ch == '(') {
                depth++;
            } else if (ch == ')') {
                depth--;
                if (depth == 0) {
                    return (char*)ptr;
                }
            }
        }

        ptr++;
    }

    return NULL;  // Unmatched
}

/**
 * Find next unquoted backtick
 */
static char* find_backtick(const char* start) {
    if (start == NULL) return NULL;

    bool in_single_quote = false;
    bool in_double_quote = false;
    const char* ptr = start;

    while (*ptr != '\0') {
        char ch = *ptr;

        if (!in_single_quote && ch == '"') {
            in_double_quote = !in_double_quote;
        } else if (!in_double_quote && ch == '\'') {
            in_single_quote = !in_single_quote;
        } else if (!in_single_quote && !in_double_quote && ch == '`') {
            return (char*)ptr;
        }

        ptr++;
    }

    return NULL;
}

/**
 * Replace a range in a string with new content
 * Returns newly allocated string
 */
static char* string_replace_range(const char* original,
                                   const char* range_start,
                                   const char* range_end,
                                   const char* replacement) {
    if (original == NULL || range_start == NULL || range_end == NULL) {
        return original ? strdup(original) : NULL;
    }

    size_t prefix_len = range_start - original;
    size_t suffix_len = strlen(range_end);
    size_t replacement_len = replacement ? strlen(replacement) : 0;

    size_t new_len = prefix_len + replacement_len + suffix_len + 1;
    char* result = malloc(new_len);
    if (result == NULL) return NULL;

    // Copy prefix
    memcpy(result, original, prefix_len);

    // Copy replacement
    if (replacement && replacement_len > 0) {
        memcpy(result + prefix_len, replacement, replacement_len);
    }

    // Copy suffix
    strcpy(result + prefix_len + replacement_len, range_end);

    return result;
}

#pragma mark - Command Output Capture

/**
 * Capture stdout from executing a command (for substitution)
 * Note: Mutex is already unlocked by ios_system.m before calling
 */
static char* capture_command_output(const char* command) {
    if (command == NULL || strlen(command) == 0) {
        return strdup("");
    }

    // Save current_pid so we can restore it after our synchronous ios_fork+
    // ios_system+ios_waitpid sequence below. Without restoration, the outer
    // ios_system's subsequent dispatch (pthread_create) would inherit the
    // already-released inner pid as params->pid — and any further sentinel
    // bookkeeping for the post-substitution work would land on the wrong
    // slot, causing the outer caller's ios_waitpid to either hang on a stale
    // -1 sentinel, or — worse — return prematurely while async work is still
    // running. We deliberately do NOT release the outer sentinel here:
    // substitution is intermediate; the post-substitution work in ios_system
    // still needs the outer pid to be in flight so the wrapping caller's
    // ios_waitpid blocks correctly.
    pid_t saved_outer_pid = ios_currentPid();

    NSLog(@"[ios_shell_parser] Capturing output of: %s", command);

    // Create pipe for capturing output
    int pipefd[2];
    if (pipe(pipefd) != 0) {
        NSLog(@"[ios_shell_parser] Failed to create pipe for substitution");
        return strdup("");
    }

    // Create FILE* for write end
    FILE* write_stream = fdopen(pipefd[1], "w");
    if (write_stream == NULL) {
        close(pipefd[0]);
        close(pipefd[1]);
        return strdup("");
    }

    // Set child streams to redirect stdout to our pipe
    ios_setChildStreams(NULL, write_stream, NULL);

    bool saved_join = joinMainThread;
    joinMainThread = true;  // Force synchronous execution

    pid_t pid = ios_fork();
    (void)ios_system(command);  // Execute command, output goes to pipe
    ios_waitpid(pid);

    // Restore the outer pid so the post-substitution work in the calling
    // ios_system continues to dispatch under the wrapping caller's pid.
    // ios_fork above advanced current_pid to a fresh inner pid; ios_waitpid
    // doesn't restore it (the cleanup runs on the worker thread's TLS, not
    // ours). Without this, params->pid for any subsequent pthread_create in
    // the outer ios_system would land on the released inner slot.
    ios_setCurrentPid(saved_outer_pid);

    joinMainThread = saved_join;

    // Clear child streams
    ios_setChildStreams(NULL, NULL, NULL);

    // Close write end to signal EOF
    fflush(write_stream);
    fclose(write_stream);
    // Note: fclose closes the underlying fd (pipefd[1])

    // Read all output from pipe
    size_t capacity = 4096;
    size_t total = 0;
    char* buffer = malloc(capacity);
    if (buffer == NULL) {
        close(pipefd[0]);
        return strdup("");
    }

    ssize_t n;
    while ((n = read(pipefd[0], buffer + total, capacity - total - 1)) > 0) {
        total += n;
        if (total >= capacity - 1) {
            capacity *= 2;
            char* new_buffer = realloc(buffer, capacity);
            if (new_buffer == NULL) {
                buffer[total] = '\0';
                break;
            }
            buffer = new_buffer;
        }
    }
    buffer[total] = '\0';

    close(pipefd[0]);

    // Strip trailing newlines (standard shell behavior)
    while (total > 0 && (buffer[total-1] == '\n' || buffer[total-1] == '\r')) {
        buffer[--total] = '\0';
    }

    NSLog(@"[ios_shell_parser] Captured %zu bytes: '%s'", total, buffer);

    return buffer;
}

#pragma mark - Command Substitution

char* ios_expand_substitutions(const char* input) {
    if (input == NULL) return NULL;

    // Quick check: any substitution markers?
    if (strstr(input, "$(") == NULL && strchr(input, '`') == NULL) {
        return (char*)input;  // No substitutions
    }

    char* result = strdup(input);
    if (result == NULL) return (char*)input;

    bool modified = false;

    // Handle $() syntax (can be nested, so process from innermost)
    while (true) {
        // Find $( - we need to find the innermost one first
        // So scan for $( and check for nesting
        char* dollar_paren = strstr(result, "$(");
        if (dollar_paren == NULL) break;

        // Check if inside quotes using strstrquoted
        char* quoted_check = strstrquoted(result, "$(");
        if (quoted_check == NULL) break;  // Inside quotes, skip

        dollar_paren = quoted_check;

        // Find matching )
        char* close_paren = find_matching_paren(dollar_paren + 2);
        if (close_paren == NULL) {
            // Unmatched, leave as literal
            NSLog(@"[ios_shell_parser] Unmatched $( in: %s", input);
            break;
        }

        // Extract inner command
        size_t cmd_len = close_paren - (dollar_paren + 2);
        char* inner_cmd = strndup(dollar_paren + 2, cmd_len);
        if (inner_cmd == NULL) break;

        // Recursively expand any nested substitutions in inner command
        char* expanded_inner = ios_expand_substitutions(inner_cmd);
        if (expanded_inner != inner_cmd) {
            free(inner_cmd);
            inner_cmd = expanded_inner;
        }

        // Execute and capture output
        char* output = capture_command_output(inner_cmd);
        free(inner_cmd);

        // Replace $(cmd) with output
        char* new_result = string_replace_range(result, dollar_paren, close_paren + 1, output);
        free(output);

        if (new_result != NULL) {
            free(result);
            result = new_result;
            modified = true;
        } else {
            break;
        }
    }

    // Handle backtick syntax (cannot be nested)
    while (true) {
        char* backtick1 = find_backtick(result);
        if (backtick1 == NULL) break;

        char* backtick2 = find_backtick(backtick1 + 1);
        if (backtick2 == NULL) {
            // Unmatched backtick
            NSLog(@"[ios_shell_parser] Unmatched backtick in: %s", input);
            break;
        }

        // Extract inner command
        size_t cmd_len = backtick2 - (backtick1 + 1);
        char* inner_cmd = strndup(backtick1 + 1, cmd_len);
        if (inner_cmd == NULL) break;

        // Execute and capture output
        char* output = capture_command_output(inner_cmd);
        free(inner_cmd);

        // Replace `cmd` with output
        char* new_result = string_replace_range(result, backtick1, backtick2 + 1, output);
        free(output);

        if (new_result != NULL) {
            free(result);
            result = new_result;
            modified = true;
        } else {
            break;
        }
    }

    if (!modified) {
        free(result);
        return (char*)input;
    }

    return result;
}

#pragma mark - Sequential Execution (;)

/**
 * Parse command string into segments separated by semicolons
 */
static char** parse_semicolons(const char* input, int* count) {
    *count = 0;
    if (input == NULL || strlen(input) == 0) return NULL;

    // Count semicolons to allocate array
    char* temp = strdup(input);
    if (temp == NULL) return NULL;

    int max_segments = 1;
    char* ptr = temp;
    while ((ptr = strstrquoted(ptr, ";")) != NULL) {
        max_segments++;
        ptr++;
    }
    free(temp);

    char** segments = calloc(max_segments + 1, sizeof(char*));
    if (segments == NULL) return NULL;

    temp = strdup(input);
    if (temp == NULL) {
        free(segments);
        return NULL;
    }

    char* segment_start = temp;
    int segment_count = 0;

    while (true) {
        char* semicolon = strstrquoted(segment_start, ";");

        if (semicolon != NULL) {
            *semicolon = '\0';  // Terminate segment
        }

        // Trim and save segment if non-empty
        char* trimmed = trim_whitespace(segment_start);
        if (strlen(trimmed) > 0) {
            segments[segment_count++] = strdup(trimmed);
        }

        if (semicolon == NULL) break;  // No more segments

        segment_start = semicolon + 1;
    }

    free(temp);
    *count = segment_count;
    return segments;
}

int ios_execute_sequential(const char* command) {
    release_outer_fork_sentinel();

    NSLog(@"[ios_shell_parser] Sequential execution: %s", command);

    int count = 0;
    char** segments = parse_semicolons(command, &count);

    if (segments == NULL || count == 0) {
        return 0;
    }

    int last_result = 0;

    for (int i = 0; i < count; i++) {
        if (segments[i] == NULL || strlen(segments[i]) == 0) continue;

        NSLog(@"[ios_shell_parser] Executing segment %d/%d: %s", i+1, count, segments[i]);

        // Note: Mutex is unlocked by ios_system.m before calling this function
        pid_t pid = ios_fork();
        last_result = ios_system(segments[i]);
        ios_waitpid(pid);

        // Semicolon always continues regardless of exit code
    }

    // Cleanup
    for (int i = 0; i < count; i++) {
        free(segments[i]);
    }
    free(segments);

    return last_result;
}

#pragma mark - Conditional Execution (&& and ||)

/**
 * Parse command into linked list with && and || operators
 */
static ios_cmd_node_t* parse_conditionals(const char* input) {
    if (input == NULL || strlen(input) == 0) return NULL;

    char* temp = strdup(input);
    if (temp == NULL) return NULL;

    ios_cmd_node_t* head = NULL;
    ios_cmd_node_t* tail = NULL;

    char* segment_start = temp;

    while (true) {
        // Find next && or ||
        char* and_pos = strstrquoted(segment_start, "&&");
        char* or_pos = strstrquoted(segment_start, "||");

        char* next_op = NULL;
        ios_shell_operator_t op_type = IOS_OP_NONE;
        int op_len = 0;

        if (and_pos != NULL && (or_pos == NULL || and_pos < or_pos)) {
            next_op = and_pos;
            op_type = IOS_OP_AND;
            op_len = 2;
        } else if (or_pos != NULL) {
            next_op = or_pos;
            op_type = IOS_OP_OR;
            op_len = 2;
        }

        // Create node for current segment
        if (next_op != NULL) {
            *next_op = '\0';  // Terminate segment
        }

        char* trimmed = trim_whitespace(segment_start);
        if (strlen(trimmed) > 0) {
            ios_cmd_node_t* node = calloc(1, sizeof(ios_cmd_node_t));
            if (node != NULL) {
                node->command = strdup(trimmed);
                node->next = NULL;
                node->next_op = op_type;

                if (tail == NULL) {
                    head = tail = node;
                } else {
                    tail->next = node;
                    tail = node;
                }
            }
        }

        if (next_op == NULL) break;  // No more operators

        segment_start = next_op + op_len;
    }

    free(temp);
    return head;
}

void ios_free_cmd_nodes(ios_cmd_node_t* head) {
    while (head != NULL) {
        ios_cmd_node_t* next = head->next;
        free(head->command);
        free(head);
        head = next;
    }
}

int ios_execute_conditional(const char* command) {
    release_outer_fork_sentinel();

    NSLog(@"[ios_shell_parser] Conditional execution: %s", command);

    ios_cmd_node_t* nodes = parse_conditionals(command);
    if (nodes == NULL) return 0;

    int result = 0;

    for (ios_cmd_node_t* node = nodes; node != NULL; node = node->next) {
        if (node->command == NULL || strlen(node->command) == 0) continue;

        NSLog(@"[ios_shell_parser] Executing: %s (next_op=%d)",
              node->command, node->next_op);

        // Note: Mutex is unlocked by ios_system.m before calling this function
        pid_t pid = ios_fork();
        result = ios_system(node->command);
        ios_waitpid(pid);

        // Short-circuit logic
        if (node->next != NULL) {
            if (node->next_op == IOS_OP_AND && result != 0) {
                // && failed, stop chain
                NSLog(@"[ios_shell_parser] && short-circuit: command failed with %d", result);
                break;
            } else if (node->next_op == IOS_OP_OR && result == 0) {
                // || succeeded, stop chain
                NSLog(@"[ios_shell_parser] || short-circuit: command succeeded");
                break;
            }
        }
    }

    ios_free_cmd_nodes(nodes);
    return result;
}

#pragma mark - Operator Detection

void ios_check_shell_operators(const char* command,
                                bool* has_semicolon,
                                bool* has_and,
                                bool* has_or) {
    if (has_semicolon) *has_semicolon = (strstrquoted((char*)command, ";") != NULL);
    if (has_and) *has_and = (strstrquoted((char*)command, "&&") != NULL);
    if (has_or) *has_or = (strstrquoted((char*)command, "||") != NULL);
}
