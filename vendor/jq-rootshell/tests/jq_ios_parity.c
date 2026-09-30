#include <jq_ios/jq_ios.h>
#include <jq_ios/jq_tls.h>

#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
    thread_count = 12,
    iterations_per_thread = 40,
};

static _Thread_local FILE *thread_input;
static _Thread_local FILE *thread_output;
static _Thread_local FILE *thread_error;
static _Thread_local int thread_is_tty;

typedef struct test_barrier {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    unsigned int participant_count;
    unsigned int waiting_count;
    unsigned int generation;
} test_barrier_t;

static test_barrier_t start_barrier;
static atomic_int failure_count;

static int test_barrier_init(test_barrier_t *barrier, unsigned int participant_count) {
    memset(barrier, 0, sizeof(*barrier));
    barrier->participant_count = participant_count;
    if (pthread_mutex_init(&barrier->mutex, NULL) != 0) {
        return -1;
    }
    if (pthread_cond_init(&barrier->condition, NULL) != 0) {
        pthread_mutex_destroy(&barrier->mutex);
        return -1;
    }
    return 0;
}

static void test_barrier_wait(test_barrier_t *barrier) {
    pthread_mutex_lock(&barrier->mutex);
    unsigned int generation = barrier->generation;
    barrier->waiting_count++;
    if (barrier->waiting_count == barrier->participant_count) {
        barrier->waiting_count = 0;
        barrier->generation++;
        pthread_cond_broadcast(&barrier->condition);
    } else {
        while (generation == barrier->generation) {
            pthread_cond_wait(&barrier->condition, &barrier->mutex);
        }
    }
    pthread_mutex_unlock(&barrier->mutex);
}

static void test_barrier_destroy(test_barrier_t *barrier) {
    pthread_cond_destroy(&barrier->condition);
    pthread_mutex_destroy(&barrier->mutex);
}

FILE *ios_stdin(void) {
    return thread_input != NULL ? thread_input : stdin;
}

FILE *ios_stdout(void) {
    return thread_output != NULL ? thread_output : stdout;
}

FILE *ios_stderr(void) {
    return thread_error != NULL ? thread_error : stderr;
}

int ios_isatty(int descriptor) {
    (void)descriptor;
    return thread_is_tty;
}

static void fail(int thread_index, int iteration, const char *message) {
    atomic_fetch_add_explicit(&failure_count, 1, memory_order_relaxed);
    flockfile(stderr);
    fprintf(stderr, "thread %d iteration %d: %s\n", thread_index, iteration, message);
    funlockfile(stderr);
}

static char *read_stream(FILE *stream) {
    if (fflush(stream) != 0 || fseek(stream, 0, SEEK_END) != 0) {
        return NULL;
    }

    long length = ftell(stream);
    if (length < 0 || fseek(stream, 0, SEEK_SET) != 0) {
        return NULL;
    }

    char *contents = calloc((size_t)length + 1, 1);
    if (contents == NULL) {
        return NULL;
    }

    if (length > 0 && fread(contents, 1, (size_t)length, stream) != (size_t)length) {
        free(contents);
        return NULL;
    }
    return contents;
}

static int contains_escape(const char *text) {
    return text != NULL && strstr(text, "\033[") != NULL;
}

static void configure_streams(FILE *input, FILE *output, FILE *error, int is_tty) {
    thread_input = input;
    thread_output = output;
    thread_error = error;
    thread_is_tty = is_tty;
}

static void run_stream_case(int thread_index, int iteration) {
    char token[64];
    char json[128];
    char expected[80];
    snprintf(token, sizeof(token), "thread-%d-value-%d", thread_index, iteration);
    snprintf(json, sizeof(json), "{\"value\":\"%s\"}\n", token);
    snprintf(expected, sizeof(expected), "%s\n", token);

    FILE *input = tmpfile();
    FILE *output = tmpfile();
    FILE *error_stream = tmpfile();
    if (input == NULL || output == NULL || error_stream == NULL) {
        fail(thread_index, iteration, "tmpfile failed");
        return;
    }

    fwrite(json, 1, strlen(json), input);
    rewind(input);
    configure_streams(input, output, error_stream, 0);

    char *arguments[] = {"jq", "-r", ".value", NULL};
    int status = jq_main(3, arguments);
    char *standard_output = read_stream(output);
    char *standard_error = read_stream(error_stream);

    if (status != 0) {
        fail(thread_index, iteration, "jq_main returned a failure for valid input");
    }
    if (standard_output == NULL || strcmp(standard_output, expected) != 0) {
        fail(thread_index, iteration, "stdout was routed to the wrong thread");
    }
    if (standard_error == NULL || standard_error[0] != '\0') {
        fail(thread_index, iteration, "unexpected stderr for valid input");
    }

    char *processed_output = NULL;
    char *processed_error = NULL;
    status = jq_process_string(".value", json, &processed_output, &processed_error);
    char quoted_expected[80];
    snprintf(quoted_expected, sizeof(quoted_expected), "\"%s\"", token);
    if (status != 0 || processed_output == NULL || strcmp(processed_output, quoted_expected) != 0 || processed_error != NULL) {
        fail(thread_index, iteration, "jq_process_string parity failure");
    }

    free(processed_output);
    free(processed_error);
    free(standard_output);
    free(standard_error);
    fclose(input);
    fclose(output);
    fclose(error_stream);
}

static void run_color_case(int thread_index, int iteration) {
    FILE *input = tmpfile();
    FILE *output = tmpfile();
    FILE *error_stream = tmpfile();
    if (input == NULL || output == NULL || error_stream == NULL) {
        fail(thread_index, iteration, "tmpfile failed in color case");
        return;
    }

    fputs("{\"number\":1}\n", input);
    rewind(input);
    configure_streams(input, output, error_stream, thread_index % 2 == 0);

    int wants_color = (thread_index + iteration) % 2 == 0;
    char *arguments_with_color[] = {"jq", "-C", "-c", ".", NULL};
    char *arguments_without_color[] = {"jq", "-M", "-c", ".", NULL};
    int status = jq_main(4, wants_color ? arguments_with_color : arguments_without_color);
    char *standard_output = read_stream(output);
    char *standard_error = read_stream(error_stream);

    if (status != 0) {
        fail(thread_index, iteration, "jq_main returned a failure in color case");
    }
    if (standard_output == NULL || contains_escape(standard_output) != wants_color) {
        fail(thread_index, iteration, "color state leaked between threads");
    }
    if (standard_error == NULL || standard_error[0] != '\0') {
        fail(thread_index, iteration, "unexpected stderr in color case");
    }

    const char *custom_colors = wants_color ? "31:31:31:31:31:31:31:31" : "32:32:32:32:32:32:32:32";
    if (!jq_ios_set_colors(custom_colors)) {
        fail(thread_index, iteration, "failed to set thread-local colors");
    } else if (strstr(jq_ios_get_color(0), wants_color ? "[31m" : "[32m") == NULL) {
        fail(thread_index, iteration, "thread-local color table was contaminated");
    }

    free(standard_output);
    free(standard_error);
    fclose(input);
    fclose(output);
    fclose(error_stream);
}

static void run_error_case(int thread_index, int iteration) {
    char token[64];
    char filter[96];
    snprintf(token, sizeof(token), "thread-%d-error-%d", thread_index, iteration);
    snprintf(filter, sizeof(filter), "error(\"%s\")", token);

    FILE *input = tmpfile();
    FILE *output = tmpfile();
    FILE *error_stream = tmpfile();
    if (input == NULL || output == NULL || error_stream == NULL) {
        fail(thread_index, iteration, "tmpfile failed in error case");
        return;
    }

    configure_streams(input, output, error_stream, 0);
    char *arguments[] = {"jq", "-n", filter, NULL};
    int status = jq_main(3, arguments);
    char *standard_output = read_stream(output);
    char *standard_error = read_stream(error_stream);

    if (status == 0) {
        fail(thread_index, iteration, "runtime error unexpectedly succeeded");
    }
    if (standard_output == NULL || standard_output[0] != '\0') {
        fail(thread_index, iteration, "runtime error produced stdout");
    }
    if (standard_error == NULL || strstr(standard_error, token) == NULL) {
        fail(thread_index, iteration, "stderr was routed to the wrong thread");
    }

    free(standard_output);
    free(standard_error);
    fclose(input);
    fclose(output);
    fclose(error_stream);
}

static void *worker(void *context) {
    int thread_index = *(int *)context;
    test_barrier_wait(&start_barrier);

    for (int iteration = 0; iteration < iterations_per_thread; iteration++) {
        run_stream_case(thread_index, iteration);
        run_color_case(thread_index, iteration);
        if (iteration % 5 == 0) {
            run_error_case(thread_index, iteration);
        }
    }

    jq_ios_thread_cleanup();
    return NULL;
}

int main(void) {
    unsetenv("JQ_COLORS");
    unsetenv("NO_COLOR");
    atomic_init(&failure_count, 0);

    if (test_barrier_init(&start_barrier, thread_count) != 0) {
        fprintf(stderr, "failed to initialize start barrier\n");
        return 1;
    }

    pthread_t threads[thread_count];
    int thread_indices[thread_count];
    for (int index = 0; index < thread_count; index++) {
        thread_indices[index] = index;
        if (pthread_create(&threads[index], NULL, worker, &thread_indices[index]) != 0) {
            fprintf(stderr, "failed to create thread %d\n", index);
            return 1;
        }
    }

    for (int index = 0; index < thread_count; index++) {
        pthread_join(threads[index], NULL);
    }
    test_barrier_destroy(&start_barrier);

    int failures = atomic_load_explicit(&failure_count, memory_order_relaxed);
    if (failures != 0) {
        fprintf(stderr, "jq_ios parity test failed with %d assertion(s)\n", failures);
        return 1;
    }

    printf("jq_ios parity test passed: %d threads, %d iterations each\n", thread_count, iterations_per_thread);
    return 0;
}
