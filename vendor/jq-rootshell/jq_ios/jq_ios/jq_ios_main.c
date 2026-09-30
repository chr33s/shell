/*
 * jq_ios_main.c - iOS entry point for jq
 *
 * This file provides:
 * - jq_main(): The main entry point called by ios_system
 * - jq_process_string(): Simple string-based API
 * - jq_process_to_stream(): Stream-based API
 *
 * Based on src/main.c from jq, adapted for thread-safe iOS usage.
 */

#include <assert.h>
#include <ctype.h>
#include <errno.h>
#include <libgen.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#ifdef HAVE_SETLOCALE
#include <locale.h>
#endif

#include "jv.h"
#include "jq.h"
#include "jq_tls.h"
#include "util.h"
#include "version.h"

/* Framework version */
const double jq_iosVersionNumber = 1.0;
const unsigned char jq_iosVersionString[] = "jq_ios 1.0 (jq " JQ_VERSION ")";

/* Exit codes - same as main.c */
enum {
    JQ_OK              =  0,
    JQ_OK_NULL_KIND    = -1,
    JQ_ERROR_SYSTEM    =  2,
    JQ_ERROR_COMPILE   =  3,
    JQ_OK_NO_OUTPUT    = -4,
    JQ_ERROR_UNKNOWN   =  5,
};

/* Option flags */
enum {
    SLURP                 = 1,
    RAW_INPUT             = 2,
    PROVIDE_NULL          = 4,
    RAW_OUTPUT            = 8,
    RAW_OUTPUT0           = 16,
    ASCII_OUTPUT          = 32,
    COLOR_OUTPUT          = 64,
    NO_COLOR_OUTPUT       = 128,
    SORTED_OUTPUT         = 256,
    FROM_FILE             = 512,
    RAW_NO_LF             = 1024,
    UNBUFFERED_OUTPUT     = 2048,
    EXIT_STATUS           = 4096,
    SEQ                   = 16384,
    DUMP_DISASM           = 32768,
};

/* Helper to check if arg looks like an option */
static int isoptish(const char* text) {
    return text[0] == '-' && (text[1] == '-' || isalpha((unsigned char)text[1]));
}

/* Helper to check for specific option */
static int isoption(const char** text, char shortopt, const char* longopt, int is_short) {
    if (is_short) {
        if (shortopt && **text == shortopt) {
            (*text)++;
            if (!**text) *text = NULL;
            return 1;
        }
    } else {
        if (!strcmp(*text, longopt)) {
            *text = NULL;
            return 1;
        }
    }
    return 0;
}

/* Print usage to thread-local stderr */
static void usage(int code, int keep_it_short) {
    FILE *f = jq_ios_stderr();
    if (code == 0) f = jq_ios_stdout();

    fprintf(f,
        "jq - commandline JSON processor [version %s]\n"
        "\nUsage:\tjq [options] <jq filter> [file...]\n"
        "\tjq [options] --args <jq filter> [strings...]\n"
        "\tjq [options] --jsonargs <jq filter> [JSON_TEXTS...]\n\n"
        "jq is a tool for processing JSON inputs, applying the given filter to\n"
        "its JSON text inputs and producing the filter's results as JSON on\n"
        "standard output.\n\n"
        "The simplest filter is ., which copies jq's input to its output\n"
        "unmodified except for formatting. For more advanced filters see\n"
        "the jq(1) manpage (\"man jq\") and/or https://jqlang.org/.\n\n"
        "Example:\n\n\t$ echo '{\"foo\": 0}' | jq .\n"
        "\t{\n\t  \"foo\": 0\n\t}\n\n", JQ_VERSION);

    if (keep_it_short) {
        fprintf(f, "For listing the command options, use jq --help.\n");
    } else {
        fprintf(f,
            "Command options:\n"
            "  -n, --null-input          use `null` as the single input value;\n"
            "  -R, --raw-input           read each line as string instead of JSON;\n"
            "  -s, --slurp               read all inputs into an array;\n"
            "  -c, --compact-output      compact instead of pretty-printed output;\n"
            "  -r, --raw-output          output strings without escapes and quotes;\n"
            "      --raw-output0         implies -r and output NUL after each output;\n"
            "  -j, --join-output         implies -r and output without newline;\n"
            "  -a, --ascii-output        output strings by only ASCII characters;\n"
            "  -S, --sort-keys           sort keys of each object on output;\n"
            "  -C, --color-output        colorize JSON output;\n"
            "  -M, --monochrome-output   disable colored output;\n"
            "      --tab                 use tabs for indentation;\n"
            "      --indent n            use n spaces for indentation (max 7);\n"
            "      --unbuffered          flush output stream after each output;\n"
            "      --stream              parse the input value in streaming fashion;\n"
            "  -f, --from-file           load the filter from a file;\n"
            "  -L dir                    search modules from the directory;\n"
            "      --arg name value      set $name to the string value;\n"
            "      --argjson name value  set $name to the JSON value;\n"
            "      --slurpfile name file set $name to array of JSON from file;\n"
            "      --rawfile name file   set $name to string contents of file;\n"
            "      --args                consume remaining args as strings;\n"
            "      --jsonargs            consume remaining args as JSON;\n"
            "  -e, --exit-status         set exit status based on output;\n"
            "  -V, --version             show the version;\n"
            "  -h, --help                show this help;\n"
            "  --                        terminates argument processing;\n");
    }
}

/* Error helper */
static void die(void) {
    fprintf(jq_ios_stderr(), "Use jq --help for help with command-line options,\n");
    fprintf(jq_ios_stderr(), "or see the jq manpage, or online docs at https://jqlang.org\n");
}

/* Debug callback */
static void debug_cb(void *data, jv input) {
    int dumpopts = *(int *)data;
    jv_dumpf(JV_ARRAY(jv_string("DEBUG:"), input), jq_ios_stderr(), dumpopts & ~(JV_PRINT_PRETTY));
    fprintf(jq_ios_stderr(), "\n");
}

/* Stderr callback for jq's stderr builtin */
static void stderr_cb(void *data, jv input) {
    int dumpopts = *(int *)data;
    FILE* err = jq_ios_stderr();
    if (jv_get_kind(input) == JV_KIND_STRING) {
        priv_fwrite(jv_string_value(input), jv_string_length_bytes(jv_copy(input)),
            err, dumpopts & JV_PRINT_ISATTY);
    } else {
        input = jv_dump_string(input, 0);
        fprintf(err, "%s", jv_string_value(input));
    }
    jv_free(input);
}

/* Process a single input value through jq */
static int process(jq_state *jq, jv value, int flags, int dumpopts, int options) {
    FILE* out = jq_ios_stdout();
    FILE* err = jq_ios_stderr();
    int ret = JQ_OK_NO_OUTPUT;

    jq_start(jq, value, flags);
    jv result;
    while (jv_is_valid(result = jq_next(jq))) {
        if ((options & RAW_OUTPUT) && jv_get_kind(result) == JV_KIND_STRING) {
            if (options & ASCII_OUTPUT) {
                jv_dumpf(jv_copy(result), out, JV_PRINT_ASCII);
            } else if ((options & RAW_OUTPUT0) &&
                       strlen(jv_string_value(result)) != (size_t)jv_string_length_bytes(jv_copy(result))) {
                jv_free(result);
                result = jv_invalid_with_msg(jv_string(
                    "Cannot dump a string containing NUL with --raw-output0 option"));
                break;
            } else {
                priv_fwrite(jv_string_value(result), jv_string_length_bytes(jv_copy(result)),
                    out, dumpopts & JV_PRINT_ISATTY);
            }
            ret = JQ_OK;
            jv_free(result);
        } else {
            if (jv_get_kind(result) == JV_KIND_FALSE || jv_get_kind(result) == JV_KIND_NULL)
                ret = JQ_OK_NULL_KIND;
            else
                ret = JQ_OK;
            if (options & SEQ)
                priv_fwrite("\036", 1, out, dumpopts & JV_PRINT_ISATTY);
            jv_dumpf(result, out, dumpopts);
        }
        if (!(options & RAW_NO_LF))
            priv_fwrite("\n", 1, out, dumpopts & JV_PRINT_ISATTY);
        if (options & RAW_OUTPUT0)
            priv_fwrite("\0", 1, out, dumpopts & JV_PRINT_ISATTY);
        if (options & UNBUFFERED_OUTPUT)
            fflush(out);
    }

    if (jq_halted(jq)) {
        jv exit_code = jq_get_exit_code(jq);
        if (!jv_is_valid(exit_code))
            ret = JQ_OK;
        else if (jv_get_kind(exit_code) == JV_KIND_NUMBER)
            ret = jv_number_value(exit_code);
        else
            ret = JQ_ERROR_UNKNOWN;
        jv_free(exit_code);

        jv error_message = jq_get_error_message(jq);
        if (jv_get_kind(error_message) == JV_KIND_STRING) {
            priv_fwrite(jv_string_value(error_message),
                jv_string_length_bytes(jv_copy(error_message)),
                err, dumpopts & JV_PRINT_ISATTY);
        } else if (jv_is_valid(error_message) && jv_get_kind(error_message) != JV_KIND_NULL) {
            error_message = jv_dump_string(error_message, 0);
            fprintf(err, "%s\n", jv_string_value(error_message));
        }
        fflush(err);
        jv_free(error_message);
    } else if (jv_invalid_has_msg(jv_copy(result))) {
        jv msg = jv_invalid_get_msg(jv_copy(result));
        jv input_pos = jq_util_input_get_position(jq);
        if (jv_get_kind(msg) == JV_KIND_STRING) {
            fprintf(err, "jq: error (at %s): %s\n",
                    jv_string_value(input_pos), jv_string_value(msg));
        } else {
            msg = jv_dump_string(msg, 0);
            fprintf(err, "jq: error (at %s) (not a string): %s\n",
                    jv_string_value(input_pos), jv_string_value(msg));
        }
        ret = JQ_ERROR_UNKNOWN;
        jv_free(input_pos);
        jv_free(msg);
    }
    jv_free(result);
    return ret;
}

/*
 * ios_system thread-local stream integration
 *
 * ios_system provides thread-local FILE* variables for per-session I/O.
 * TLS variables don't resolve correctly across dynamic library boundaries
 * with -undefined dynamic_lookup, so we use accessor functions instead.
 */
#ifdef __APPLE__
extern FILE* ios_stdin(void);
extern FILE* ios_stdout(void);
extern FILE* ios_stderr(void);
extern int ios_isatty(int fd);

static void jq_ios_bridge_ios_system_streams(void) {
    FILE* in = ios_stdin();
    FILE* out = ios_stdout();
    FILE* err = ios_stderr();

    if (out) {
        jq_ios_set_stdout(out);
    }
    if (err) {
        jq_ios_set_stderr(err);
    }
    if (in) {
        jq_ios_set_stdin(in);
    }
}
#else
static void jq_ios_bridge_ios_system_streams(void) {
    /* No-op on non-Apple platforms */
}
#endif

/*
 * Main entry point for ios_system
 */
int jq_main(int argc, char* argv[]) {
    jq_state *jq = NULL;
    jq_util_input_state *input_state = NULL;
    int ret = JQ_OK_NO_OUTPUT;
    int compiled = 0;
    int parser_flags = 0;
    int nfiles = 0;
    int last_result = -1;
    int options = 0;

    /* Bridge ios_system's TLS to jq_ios's TLS before accessing streams */
    jq_ios_bridge_ios_system_streams();

    FILE* out = jq_ios_stdout();
    FILE* err = jq_ios_stderr();

#ifdef HAVE_SETLOCALE
    (void) setlocale(LC_ALL, "");
#endif

    /* Initialize oniguruma (thread-safe, idempotent) */
    jq_ios_onig_init();

    /* Set up colors from environment */
    const char* colors_env = getenv("JQ_COLORS");
    if (colors_env) {
        if (!jq_ios_set_colors(colors_env)) {
            fprintf(err, "jq: warning: failed to set $JQ_COLORS\n");
        }
    }

    jv ARGS = jv_array();
    jv program_arguments = jv_object();

    jq = jq_init();
    if (jq == NULL) {
        fprintf(err, "jq: error: jq_init failed\n");
        ret = JQ_ERROR_SYSTEM;
        goto out;
    }

    int dumpopts = JV_PRINT_INDENT_FLAGS(2);
    const char* program = NULL;

    input_state = jq_util_input_init(NULL, NULL);

    int further_args_are_strings = 0;
    int further_args_are_json = 0;
    int args_done = 0;
    int jq_flags = 0;
    jv lib_search_paths = jv_null();

    /* Parse command line arguments */
    for (int i = 1; i < argc; i++) {
        if (args_done || !isoptish(argv[i])) {
            if (!program) {
                program = argv[i];
            } else if (further_args_are_strings) {
                ARGS = jv_array_append(ARGS, jv_string(argv[i]));
            } else if (further_args_are_json) {
                jv v = jv_parse(argv[i]);
                if (!jv_is_valid(v)) {
                    fprintf(err, "jq: invalid JSON text passed to --jsonargs\n");
                    die();
                    ret = JQ_ERROR_COMPILE;
                    goto out;
                }
                ARGS = jv_array_append(ARGS, v);
            } else {
                jq_util_input_add_input(input_state, argv[i]);
                nfiles++;
            }
        } else if (!strcmp(argv[i], "--")) {
            args_done = 1;
        } else {
            const char* text = argv[i];
            int is_short;
            if (text[1] == '-') {
                text += 2;
                is_short = 0;
            } else {
                text++;
                is_short = 1;
            }
            int raw;

            while (text != NULL) {
                if (isoption(&text, 's', "slurp", is_short)) {
                    options |= SLURP;
                } else if (isoption(&text, 'r', "raw-output", is_short)) {
                    options |= RAW_OUTPUT;
                } else if (isoption(&text, 0, "raw-output0", is_short)) {
                    options |= RAW_OUTPUT | RAW_NO_LF | RAW_OUTPUT0;
                } else if (isoption(&text, 'j', "join-output", is_short)) {
                    options |= RAW_OUTPUT | RAW_NO_LF;
                } else if (isoption(&text, 'c', "compact-output", is_short)) {
                    dumpopts &= ~(JV_PRINT_TAB | JV_PRINT_INDENT_FLAGS(7));
                } else if (isoption(&text, 'C', "color-output", is_short)) {
                    options |= COLOR_OUTPUT;
                } else if (isoption(&text, 'M', "monochrome-output", is_short)) {
                    options |= NO_COLOR_OUTPUT;
                } else if (isoption(&text, 'a', "ascii-output", is_short)) {
                    options |= ASCII_OUTPUT;
                } else if (isoption(&text, 0, "unbuffered", is_short)) {
                    options |= UNBUFFERED_OUTPUT;
                } else if (isoption(&text, 'S', "sort-keys", is_short)) {
                    options |= SORTED_OUTPUT;
                } else if (isoption(&text, 'R', "raw-input", is_short)) {
                    options |= RAW_INPUT;
                } else if (isoption(&text, 'n', "null-input", is_short)) {
                    options |= PROVIDE_NULL;
                } else if (isoption(&text, 'f', "from-file", is_short)) {
                    options |= FROM_FILE;
                } else if (isoption(&text, 'L', "library-path", is_short)) {
                    if (jv_get_kind(lib_search_paths) == JV_KIND_NULL)
                        lib_search_paths = jv_array();
                    if (text != NULL) {
                        lib_search_paths = jv_array_append(lib_search_paths, jq_realpath(jv_string(text)));
                        text = NULL;
                    } else if (i >= argc - 1) {
                        fprintf(err, "-L takes a parameter\n");
                        die();
                        ret = JQ_ERROR_COMPILE;
                        goto out;
                    } else {
                        lib_search_paths = jv_array_append(lib_search_paths, jq_realpath(jv_string(argv[i+1])));
                        i++;
                    }
                } else if (isoption(&text, 0, "tab", is_short)) {
                    dumpopts &= ~JV_PRINT_INDENT_FLAGS(7);
                    dumpopts |= JV_PRINT_TAB | JV_PRINT_PRETTY;
                } else if (isoption(&text, 0, "indent", is_short)) {
                    if (i >= argc - 1) {
                        fprintf(err, "jq: --indent takes one parameter\n");
                        die();
                        ret = JQ_ERROR_COMPILE;
                        goto out;
                    }
                    char* end = NULL;
                    errno = 0;
                    long indent = strtol(argv[i+1], &end, 10);
                    if (errno || indent < -1 || indent > 7 ||
                        isspace((unsigned char)*argv[i+1]) || end == argv[i+1] || *end) {
                        fprintf(err, "jq: --indent takes a number between -1 and 7\n");
                        die();
                        ret = JQ_ERROR_COMPILE;
                        goto out;
                    }
                    dumpopts &= ~(JV_PRINT_TAB | JV_PRINT_INDENT_FLAGS(7));
                    dumpopts |= JV_PRINT_INDENT_FLAGS(indent);
                    i++;
                } else if (isoption(&text, 0, "seq", is_short)) {
                    options |= SEQ;
                } else if (isoption(&text, 0, "stream", is_short)) {
                    parser_flags |= JV_PARSE_STREAMING;
                } else if (isoption(&text, 0, "stream-errors", is_short)) {
                    parser_flags |= JV_PARSE_STREAMING | JV_PARSE_STREAM_ERRORS;
                } else if (isoption(&text, 'e', "exit-status", is_short)) {
                    options |= EXIT_STATUS;
                } else if (isoption(&text, 0, "args", is_short)) {
                    further_args_are_strings = 1;
                    further_args_are_json = 0;
                } else if (isoption(&text, 0, "jsonargs", is_short)) {
                    further_args_are_strings = 0;
                    further_args_are_json = 1;
                } else if (isoption(&text, 0, "arg", is_short)) {
                    if (i >= argc - 2) {
                        fprintf(err, "jq: --arg takes two parameters\n");
                        die();
                        ret = JQ_ERROR_COMPILE;
                        goto out;
                    }
                    if (!jv_object_has(jv_copy(program_arguments), jv_string(argv[i+1])))
                        program_arguments = jv_object_set(program_arguments, jv_string(argv[i+1]), jv_string(argv[i+2]));
                    i += 2;
                } else if (isoption(&text, 0, "argjson", is_short)) {
                    if (i >= argc - 2) {
                        fprintf(err, "jq: --argjson takes two parameters\n");
                        die();
                        ret = JQ_ERROR_COMPILE;
                        goto out;
                    }
                    if (!jv_object_has(jv_copy(program_arguments), jv_string(argv[i+1]))) {
                        jv v = jv_parse(argv[i+2]);
                        if (!jv_is_valid(v)) {
                            fprintf(err, "jq: invalid JSON text passed to --argjson\n");
                            die();
                            ret = JQ_ERROR_COMPILE;
                            goto out;
                        }
                        program_arguments = jv_object_set(program_arguments, jv_string(argv[i+1]), v);
                    }
                    i += 2;
                } else if ((raw = isoption(&text, 0, "rawfile", is_short)) ||
                           isoption(&text, 0, "slurpfile", is_short)) {
                    const char *which = raw ? "rawfile" : "slurpfile";
                    if (i >= argc - 2) {
                        fprintf(err, "jq: --%s takes two parameters\n", which);
                        die();
                        ret = JQ_ERROR_COMPILE;
                        goto out;
                    }
                    if (!jv_object_has(jv_copy(program_arguments), jv_string(argv[i+1]))) {
                        jv data = jv_load_file(argv[i+2], raw);
                        if (!jv_is_valid(data)) {
                            data = jv_invalid_get_msg(data);
                            fprintf(err, "jq: Bad JSON in --%s %s %s: %s\n", which,
                                    argv[i+1], argv[i+2], jv_string_value(data));
                            jv_free(data);
                            ret = JQ_ERROR_SYSTEM;
                            goto out;
                        }
                        program_arguments = jv_object_set(program_arguments, jv_string(argv[i+1]), data);
                    }
                    i += 2;
                } else if (isoption(&text, 0, "debug-dump-disasm", is_short)) {
                    options |= DUMP_DISASM;
                } else if (isoption(&text, 0, "debug-trace=all", is_short)) {
                    jq_flags |= JQ_DEBUG_TRACE_ALL;
                } else if (isoption(&text, 0, "debug-trace", is_short)) {
                    jq_flags |= JQ_DEBUG_TRACE;
                } else if (isoption(&text, 'h', "help", is_short)) {
                    usage(0, 0);
                    ret = JQ_OK;
                    goto out;
                } else if (isoption(&text, 'V', "version", is_short)) {
                    fprintf(out, "jq-%s (jq_ios)\n", JQ_VERSION);
                    ret = JQ_OK;
                    goto out;
                } else {
                    if (is_short) {
                        fprintf(err, "jq: Unknown option -%c\n", text[0]);
                    } else {
                        fprintf(err, "jq: Unknown option --%s\n", text);
                    }
                    die();
                    ret = JQ_ERROR_COMPILE;
                    goto out;
                }
            }
        }
    }

    /* Set up output options */
    /* Auto-enable colors if stdout is a TTY */
    if (ios_isatty(fileno(jq_ios_stdout()))) {
        dumpopts |= JV_PRINT_ISATTY | JV_PRINT_COLOR;
        /* Respect NO_COLOR environment variable */
        const char *no_color = getenv("NO_COLOR");
        if (no_color != NULL && no_color[0] != '\0') {
            dumpopts &= ~JV_PRINT_COLOR;
        }
    }
    if (options & SORTED_OUTPUT) dumpopts |= JV_PRINT_SORTED;
    if (options & ASCII_OUTPUT) dumpopts |= JV_PRINT_ASCII;
    /* Explicit -C and -M flags override auto-detection */
    if (options & COLOR_OUTPUT) dumpopts |= JV_PRINT_COLOR;
    if (options & NO_COLOR_OUTPUT) dumpopts &= ~JV_PRINT_COLOR;

    /* Set library search paths */
    if (jv_get_kind(lib_search_paths) == JV_KIND_NULL) {
        lib_search_paths = JV_ARRAY(jv_string("~/.jq"),
                                    jv_string("$ORIGIN/../lib/jq"),
                                    jv_string("$ORIGIN/../lib"));
    }
    jq_set_attr(jq, jv_string("JQ_LIBRARY_PATH"), lib_search_paths);

    if (argc > 0) {
        char *origin = strdup(argv[0]);
        if (origin) {
            jq_set_attr(jq, jv_string("JQ_ORIGIN"), jv_string(dirname(origin)));
            free(origin);
        }
    }

    /* Default to identity filter if no program given and stdin/stdout is not a TTY
     * (i.e., we're in a pipeline). If both are TTYs, show usage instead. */
    if (!program && !(options & FROM_FILE)) {
        if (!ios_isatty(fileno(jq_ios_stdout())) || !ios_isatty(fileno(jq_ios_stdin()))) {
            program = ".";
        }
    }

    if (!program) {
        usage(2, 1);
        ret = JQ_OK;  /* Not an error - user just ran jq with no args */
        goto out;
    }

    /* Compile the filter */
    if (options & FROM_FILE) {
        char *program_origin = strdup(program);
        if (!program_origin) {
            fprintf(err, "jq: out of memory\n");
            ret = JQ_ERROR_SYSTEM;
            goto out;
        }

        jv data = jv_load_file(program, 1);
        if (!jv_is_valid(data)) {
            data = jv_invalid_get_msg(data);
            fprintf(err, "jq: %s\n", jv_string_value(data));
            jv_free(data);
            free(program_origin);
            ret = JQ_ERROR_SYSTEM;
            goto out;
        }
        jq_set_attr(jq, jv_string("PROGRAM_ORIGIN"), jq_realpath(jv_string(dirname(program_origin))));
        ARGS = JV_OBJECT(jv_string("positional"), ARGS,
                         jv_string("named"), jv_copy(program_arguments));
        program_arguments = jv_object_set(program_arguments, jv_string("ARGS"), jv_copy(ARGS));
        compiled = jq_compile_args(jq, jv_string_value(data), jv_copy(program_arguments));
        free(program_origin);
        jv_free(data);
    } else {
        jq_set_attr(jq, jv_string("PROGRAM_ORIGIN"), jq_realpath(jv_string(".")));
        ARGS = JV_OBJECT(jv_string("positional"), ARGS,
                         jv_string("named"), jv_copy(program_arguments));
        program_arguments = jv_object_set(program_arguments, jv_string("ARGS"), jv_copy(ARGS));
        compiled = jq_compile_args(jq, program, jv_copy(program_arguments));
    }

    if (!compiled) {
        ret = JQ_ERROR_COMPILE;
        goto out;
    }

    if (options & DUMP_DISASM) {
        jq_dump_disassembly(jq, 0);
        fprintf(out, "\n");
    }

    /* Set up parser */
    if (options & SEQ)
        parser_flags |= JV_PARSE_SEQ;

    if (options & RAW_INPUT)
        jq_util_input_set_parser(input_state, NULL, (options & SLURP) ? 1 : 0);
    else
        jq_util_input_set_parser(input_state, jv_parser_new(parser_flags), (options & SLURP) ? 1 : 0);

    /* Set up callbacks */
    jq_set_input_cb(jq, jq_util_input_next_input_cb, input_state);
    jq_set_debug_cb(jq, debug_cb, &dumpopts);
    jq_set_stderr_cb(jq, stderr_cb, &dumpopts);

    /* Default to stdin if no files specified */
    if (nfiles == 0)
        jq_util_input_add_input(input_state, "-");

    /* Process inputs */
    if (options & PROVIDE_NULL) {
        ret = process(jq, jv_null(), jq_flags, dumpopts, options);
    } else {
        jv value;
        while (jq_util_input_errors(input_state) == 0 &&
               (jv_is_valid((value = jq_util_input_next_input(input_state))) ||
                jv_invalid_has_msg(jv_copy(value)))) {
            if (jv_is_valid(value)) {
                ret = process(jq, value, jq_flags, dumpopts, options);
                if (ret <= 0 && ret != JQ_OK_NO_OUTPUT)
                    last_result = (ret != JQ_OK_NULL_KIND);
                if (jq_halted(jq))
                    break;
                continue;
            }

            /* Parse error */
            jv msg = jv_invalid_get_msg(value);
            if (!(options & SEQ)) {
                ret = JQ_ERROR_UNKNOWN;
                fprintf(err, "jq: parse error: %s\n", jv_string_value(msg));
                jv_free(msg);
                break;
            }
            fprintf(err, "jq: ignoring parse error: %s\n", jv_string_value(msg));
            jv_free(msg);
        }
    }

    if (jq_util_input_errors(input_state) != 0)
        ret = JQ_ERROR_SYSTEM;

out:
    /* Flush output */
    fflush(out);

    /* Cleanup */
    jv_free(ARGS);
    jv_free(program_arguments);
    jq_util_input_free(&input_state);
    jq_teardown(&jq);

    /* Handle exit status option */
    if (options & EXIT_STATUS) {
        if (ret != JQ_OK_NO_OUTPUT)
            return abs(ret);
        else
            switch (last_result) {
                case -1: return abs(JQ_OK_NO_OUTPUT);
                case  0: return abs(JQ_OK_NULL_KIND);
                default: return JQ_OK;
            }
    }

    return ret > 0 ? ret : 0;
}

/*
 * Simple string-based API
 */
int jq_process_string(const char* filter, const char* input_json,
                      char** output, char** error) {
    *output = NULL;
    *error = NULL;

    jq_state* jq = jq_init();
    if (!jq) {
        *error = strdup("Failed to initialize jq");
        return -1;
    }

    /* Initialize oniguruma */
    jq_ios_onig_init();

    /* Compile filter */
    if (!jq_compile(jq, filter)) {
        *error = strdup("Failed to compile jq filter");
        jq_teardown(&jq);
        return -1;
    }

    /* Parse input */
    jv input = jv_parse(input_json);
    if (!jv_is_valid(input)) {
        jv msg = jv_invalid_get_msg(input);
        if (jv_get_kind(msg) == JV_KIND_STRING) {
            *error = strdup(jv_string_value(msg));
        } else {
            *error = strdup("Failed to parse input JSON");
        }
        jv_free(msg);
        jq_teardown(&jq);
        return -1;
    }

    /* Execute and collect results */
    jq_start(jq, input, 0);
    jv result;
    jv output_parts = jv_array();
    int first = 1;

    while (jv_is_valid(result = jq_next(jq))) {
        jv str = jv_dump_string(result, 0);
        if (!first) {
            output_parts = jv_array_append(output_parts, jv_string("\n"));
        }
        output_parts = jv_array_append(output_parts, str);
        first = 0;
    }

    /* Check for errors */
    if (jv_invalid_has_msg(jv_copy(result))) {
        jv msg = jv_invalid_get_msg(result);
        if (jv_get_kind(msg) == JV_KIND_STRING) {
            *error = strdup(jv_string_value(msg));
        } else {
            *error = strdup("jq execution error");
        }
        jv_free(msg);
        jv_free(output_parts);
        jq_teardown(&jq);
        return -1;
    }
    jv_free(result);

    /* Join output parts */
    jv joined = jv_string("");
    jv_array_foreach(output_parts, i, part) {
        joined = jv_string_concat(joined, part);
    }
    jv_free(output_parts);

    *output = strdup(jv_string_value(joined));
    jv_free(joined);

    jq_teardown(&jq);
    return 0;
}

/*
 * Stream-based API
 */
int jq_process_to_stream(const char* filter, const char* input_json,
                         FILE* out, FILE* err, int flags) {
    jq_state* jq = jq_init();
    if (!jq) {
        if (err) fprintf(err, "Failed to initialize jq\n");
        return -1;
    }

    jq_ios_onig_init();

    if (!jq_compile(jq, filter)) {
        if (err) fprintf(err, "Failed to compile jq filter\n");
        jq_teardown(&jq);
        return -1;
    }

    jv input = jv_parse(input_json);
    if (!jv_is_valid(input)) {
        jv msg = jv_invalid_get_msg(input);
        if (err) {
            if (jv_get_kind(msg) == JV_KIND_STRING) {
                fprintf(err, "Parse error: %s\n", jv_string_value(msg));
            } else {
                fprintf(err, "Failed to parse input JSON\n");
            }
        }
        jv_free(msg);
        jq_teardown(&jq);
        return -1;
    }

    jq_start(jq, input, 0);
    jv result;
    int ret = 0;

    while (jv_is_valid(result = jq_next(jq))) {
        if (out) {
            jv_dumpf(result, out, flags);
            fprintf(out, "\n");
        } else {
            jv_free(result);
        }
    }

    if (jv_invalid_has_msg(jv_copy(result))) {
        jv msg = jv_invalid_get_msg(result);
        if (err && jv_get_kind(msg) == JV_KIND_STRING) {
            fprintf(err, "Error: %s\n", jv_string_value(msg));
        }
        jv_free(msg);
        ret = -1;
    }
    jv_free(result);

    jq_teardown(&jq);
    return ret;
}
