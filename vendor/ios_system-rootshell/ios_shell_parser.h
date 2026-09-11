/*
 * ios_shell_parser.h
 * Shell parsing for sequential, conditional, and command substitution execution
 *
 * Adds support for:
 *   - Semicolons (;) - sequential execution
 *   - && and || - conditional execution with short-circuit
 *   - $(cmd) and `cmd` - command substitution
 *
 * Uses existing strstrquoted() for quote-aware parsing.
 */

#ifndef IOS_SHELL_PARSER_H
#define IOS_SHELL_PARSER_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Operator type for command chaining
typedef enum {
    IOS_OP_NONE = 0,      // No operator (last command in chain)
    IOS_OP_SEMICOLON,     // ; - always continue
    IOS_OP_AND,           // && - continue only if previous succeeded
    IOS_OP_OR             // || - continue only if previous failed
} ios_shell_operator_t;

// Command node for linked list of chained commands
typedef struct _ios_cmd_node {
    char* command;                      // The command string (owned, must be freed)
    struct _ios_cmd_node* next;         // Next command in chain
    ios_shell_operator_t next_op;       // Operator connecting to next command
} ios_cmd_node_t;

/**
 * Expand command substitutions in input string
 *
 * Handles both $(cmd) and `cmd` syntax.
 * $(cmd) can be nested, backticks cannot.
 *
 * @param input The input string to expand
 * @return New string with substitutions expanded (caller must free if != input),
 *         or the original input pointer if no substitutions found
 *
 * Thread-safe: Uses thread-local streams
 */
char* ios_expand_substitutions(const char* input);

/**
 * Execute commands separated by semicolons
 *
 * @param command The full command string with semicolons
 * @return Exit code of the last executed command
 *
 * Note: Unlocks ios_system_mutex during recursive ios_system() calls
 */
int ios_execute_sequential(const char* command);

/**
 * Execute commands with && and || operators
 *
 * @param command The command string with conditional operators
 * @return Exit code of the last executed command
 *
 * Short-circuit logic:
 *   - && stops chain if command fails (non-zero exit)
 *   - || stops chain if command succeeds (zero exit)
 *
 * Note: Unlocks ios_system_mutex during recursive ios_system() calls
 */
int ios_execute_conditional(const char* command);

/**
 * Free a linked list of command nodes
 *
 * @param head The head of the linked list
 */
void ios_free_cmd_nodes(ios_cmd_node_t* head);

/**
 * Check if a command string contains shell operators
 *
 * @param command The command string to check
 * @param has_semicolon Output: true if ; found outside quotes
 * @param has_and Output: true if && found outside quotes
 * @param has_or Output: true if || found outside quotes
 *
 * Uses strstrquoted() for quote-aware detection
 */
void ios_check_shell_operators(const char* command,
                                bool* has_semicolon,
                                bool* has_and,
                                bool* has_or);

#ifdef __cplusplus
}
#endif

#endif /* IOS_SHELL_PARSER_H */
