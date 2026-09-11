/*
 * ios_buffered_pipe.c
 * Lock-free buffered pipe implementation with ring buffer
 */

#include "ios_buffered_pipe.h"
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <pthread.h>
#include <time.h>
#include <stdatomic.h>

// Default configuration
#define DEFAULT_BUFFER_SIZE (64 * 1024)  // 64KB
#define DEFAULT_TIMEOUT_MS -1             // Infinite

// Pipe structure
struct _ios_buffered_pipe {
    // Ring buffer
    uint8_t* buffer;
    size_t capacity;
    _Atomic(size_t) head;  // Read position
    _Atomic(size_t) tail;  // Write position

    // Synchronization
    pthread_mutex_t mutex;
    pthread_cond_t data_available;   // Signaled when data written
    pthread_cond_t space_available;  // Signaled when data read

    // State
    _Atomic(bool) write_closed;
    _Atomic(bool) read_closed;
    bool suppress_sigpipe;

    // Timeouts
    int read_timeout_ms;
    int write_timeout_ms;

    // Statistics
    _Atomic(uint64_t) total_written;
    _Atomic(uint64_t) total_read;
    _Atomic(int) writer_waits;
    _Atomic(int) reader_waits;
};

// Forward declarations
static size_t ring_buffer_available(ios_buffered_pipe_t* pipe);
static size_t ring_buffer_space(ios_buffered_pipe_t* pipe);
static size_t ring_buffer_write(ios_buffered_pipe_t* pipe, const void* data, size_t size);
static size_t ring_buffer_read(ios_buffered_pipe_t* pipe, void* buffer, size_t size);
static int wait_with_timeout(pthread_cond_t* cond, pthread_mutex_t* mutex, int timeout_ms);

/**
 * Calculate available data in ring buffer
 * head <= tail: data = tail - head
 * head > tail: data = (capacity - head) + tail
 */
static size_t ring_buffer_available(ios_buffered_pipe_t* pipe) {
    size_t h = atomic_load(&pipe->head);
    size_t t = atomic_load(&pipe->tail);

    if (t >= h) {
        return t - h;
    } else {
        return (pipe->capacity - h) + t;
    }
}

/**
 * Calculate available space in ring buffer
 */
static size_t ring_buffer_space(ios_buffered_pipe_t* pipe) {
    return pipe->capacity - ring_buffer_available(pipe) - 1;  // -1 to distinguish full from empty
}

/**
 * Write to ring buffer (caller must hold mutex)
 */
static size_t ring_buffer_write(ios_buffered_pipe_t* pipe, const void* data, size_t size) {
    size_t space = ring_buffer_space(pipe);
    size_t to_write = size < space ? size : space;

    if (to_write == 0) {
        return 0;
    }

    size_t t = atomic_load(&pipe->tail);
    const uint8_t* src = (const uint8_t*)data;

    // Write in two parts if wrapping around
    size_t first_part = pipe->capacity - t;
    if (first_part > to_write) {
        first_part = to_write;
    }

    memcpy(pipe->buffer + t, src, first_part);

    if (to_write > first_part) {
        // Wrap around
        memcpy(pipe->buffer, src + first_part, to_write - first_part);
    }

    // Update tail atomically
    atomic_store(&pipe->tail, (t + to_write) % pipe->capacity);

    return to_write;
}

/**
 * Read from ring buffer (caller must hold mutex)
 */
static size_t ring_buffer_read(ios_buffered_pipe_t* pipe, void* buffer, size_t size) {
    size_t available = ring_buffer_available(pipe);
    size_t to_read = size < available ? size : available;

    if (to_read == 0) {
        return 0;
    }

    size_t h = atomic_load(&pipe->head);
    uint8_t* dest = (uint8_t*)buffer;

    // Read in two parts if wrapping around
    size_t first_part = pipe->capacity - h;
    if (first_part > to_read) {
        first_part = to_read;
    }

    memcpy(dest, pipe->buffer + h, first_part);

    if (to_read > first_part) {
        // Wrap around
        memcpy(dest + first_part, pipe->buffer, to_read - first_part);
    }

    // Update head atomically
    atomic_store(&pipe->head, (h + to_read) % pipe->capacity);

    return to_read;
}

/**
 * Wait on condition variable with timeout
 */
static int wait_with_timeout(pthread_cond_t* cond, pthread_mutex_t* mutex, int timeout_ms) {
    if (timeout_ms < 0) {
        // Infinite wait
        return pthread_cond_wait(cond, mutex);
    } else if (timeout_ms == 0) {
        // Non-blocking
        return ETIMEDOUT;
    } else {
        // Timed wait
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);

        ts.tv_sec += timeout_ms / 1000;
        ts.tv_nsec += (timeout_ms % 1000) * 1000000;

        if (ts.tv_nsec >= 1000000000) {
            ts.tv_sec++;
            ts.tv_nsec -= 1000000000;
        }

        return pthread_cond_timedwait(cond, mutex, &ts);
    }
}

/**
 * Create buffered pipe with default configuration
 */
ios_buffered_pipe_t* ios_pipe_create_default(void) {
    ios_pipe_config_t config = {
        .buffer_size = DEFAULT_BUFFER_SIZE,
        .read_timeout_ms = DEFAULT_TIMEOUT_MS,
        .write_timeout_ms = DEFAULT_TIMEOUT_MS,
        .suppress_sigpipe = true
    };

    return ios_pipe_create(&config);
}

/**
 * Create buffered pipe with custom configuration
 */
ios_buffered_pipe_t* ios_pipe_create(const ios_pipe_config_t* config) {
    ios_buffered_pipe_t* pipe = calloc(1, sizeof(ios_buffered_pipe_t));
    if (pipe == NULL) {
        return NULL;
    }

    pipe->capacity = config->buffer_size > 0 ? config->buffer_size : DEFAULT_BUFFER_SIZE;
    pipe->buffer = malloc(pipe->capacity);
    if (pipe->buffer == NULL) {
        free(pipe);
        return NULL;
    }

    atomic_init(&pipe->head, 0);
    atomic_init(&pipe->tail, 0);

    pthread_mutex_init(&pipe->mutex, NULL);
    pthread_cond_init(&pipe->data_available, NULL);
    pthread_cond_init(&pipe->space_available, NULL);

    atomic_init(&pipe->write_closed, false);
    atomic_init(&pipe->read_closed, false);
    pipe->suppress_sigpipe = config->suppress_sigpipe;

    pipe->read_timeout_ms = config->read_timeout_ms;
    pipe->write_timeout_ms = config->write_timeout_ms;

    atomic_init(&pipe->total_written, 0);
    atomic_init(&pipe->total_read, 0);
    atomic_init(&pipe->writer_waits, 0);
    atomic_init(&pipe->reader_waits, 0);

    return pipe;
}

/**
 * Write data to pipe
 */
ssize_t ios_pipe_write(ios_buffered_pipe_t* pipe, const void* data, size_t size) {
    return ios_pipe_write_timeout(pipe, data, size, pipe->write_timeout_ms);
}

/**
 * Write data with timeout
 */
ssize_t ios_pipe_write_timeout(ios_buffered_pipe_t* pipe, const void* data,
                                size_t size, int timeout_ms) {
    if (pipe == NULL || data == NULL) {
        errno = EINVAL;
        return -1;
    }

    if (atomic_load(&pipe->write_closed)) {
        errno = EPIPE;
        return -1;
    }

    if (atomic_load(&pipe->read_closed)) {
        errno = EPIPE;
        return 0;  // Reader closed, pretend success
    }

    pthread_mutex_lock(&pipe->mutex);

    size_t total_written = 0;
    const uint8_t* src = (const uint8_t*)data;

    while (total_written < size) {
        // Check if still open
        if (atomic_load(&pipe->read_closed)) {
            pthread_mutex_unlock(&pipe->mutex);
            errno = EPIPE;
            return total_written > 0 ? (ssize_t)total_written : -1;
        }

        // Try to write
        size_t written = ring_buffer_write(pipe, src + total_written, size - total_written);

        if (written > 0) {
            total_written += written;
            atomic_fetch_add(&pipe->total_written, written);

            // Signal readers
            pthread_cond_signal(&pipe->data_available);

            if (total_written >= size) {
                break;  // Done
            }
        }

        // Buffer full, need to wait
        atomic_fetch_add(&pipe->writer_waits, 1);

        int wait_result = wait_with_timeout(&pipe->space_available, &pipe->mutex, timeout_ms);

        if (wait_result == ETIMEDOUT) {
            pthread_mutex_unlock(&pipe->mutex);
            errno = ETIMEDOUT;
            return total_written > 0 ? (ssize_t)total_written : -1;
        }
    }

    pthread_mutex_unlock(&pipe->mutex);
    return (ssize_t)total_written;
}

/**
 * Read data from pipe
 */
ssize_t ios_pipe_read(ios_buffered_pipe_t* pipe, void* buffer, size_t size) {
    return ios_pipe_read_timeout(pipe, buffer, size, pipe->read_timeout_ms);
}

/**
 * Read data with timeout
 */
ssize_t ios_pipe_read_timeout(ios_buffered_pipe_t* pipe, void* buffer,
                               size_t size, int timeout_ms) {
    if (pipe == NULL || buffer == NULL) {
        errno = EINVAL;
        return -1;
    }

    if (atomic_load(&pipe->read_closed)) {
        return 0;  // EOF
    }

    pthread_mutex_lock(&pipe->mutex);

    size_t total_read = 0;
    uint8_t* dest = (uint8_t*)buffer;

    while (total_read < size) {
        // Try to read
        size_t bytes_read = ring_buffer_read(pipe, dest + total_read, size - total_read);

        if (bytes_read > 0) {
            total_read += bytes_read;
            atomic_fetch_add(&pipe->total_read, bytes_read);

            // Signal writers
            pthread_cond_signal(&pipe->space_available);

            // Return what we have (don't wait for full size)
            break;
        }

        // Buffer empty
        if (atomic_load(&pipe->write_closed)) {
            // Writer closed and buffer empty = EOF
            pthread_mutex_unlock(&pipe->mutex);
            return (ssize_t)total_read;  // 0 if nothing read = EOF
        }

        // Wait for data
        atomic_fetch_add(&pipe->reader_waits, 1);

        int wait_result = wait_with_timeout(&pipe->data_available, &pipe->mutex, timeout_ms);

        if (wait_result == ETIMEDOUT) {
            pthread_mutex_unlock(&pipe->mutex);
            errno = ETIMEDOUT;
            return total_read > 0 ? (ssize_t)total_read : -1;
        }
    }

    pthread_mutex_unlock(&pipe->mutex);
    return (ssize_t)total_read;
}

/**
 * Close pipe for writing
 */
int ios_pipe_close_write(ios_buffered_pipe_t* pipe) {
    if (pipe == NULL) {
        errno = EINVAL;
        return -1;
    }

    atomic_store(&pipe->write_closed, true);

    // Wake up any blocked readers
    pthread_mutex_lock(&pipe->mutex);
    pthread_cond_broadcast(&pipe->data_available);
    pthread_mutex_unlock(&pipe->mutex);

    return 0;
}

/**
 * Close pipe for reading
 */
int ios_pipe_close_read(ios_buffered_pipe_t* pipe) {
    if (pipe == NULL) {
        errno = EINVAL;
        return -1;
    }

    atomic_store(&pipe->read_closed, true);

    // Wake up any blocked writers
    pthread_mutex_lock(&pipe->mutex);
    pthread_cond_broadcast(&pipe->space_available);
    pthread_mutex_unlock(&pipe->mutex);

    return 0;
}

/**
 * Destroy pipe
 */
void ios_pipe_destroy(ios_buffered_pipe_t* pipe) {
    if (pipe == NULL) {
        return;
    }

    ios_pipe_close_write(pipe);
    ios_pipe_close_read(pipe);

    pthread_mutex_destroy(&pipe->mutex);
    pthread_cond_destroy(&pipe->data_available);
    pthread_cond_destroy(&pipe->space_available);

    free(pipe->buffer);
    free(pipe);
}

/**
 * Check if readable
 */
bool ios_pipe_poll_readable(ios_buffered_pipe_t* pipe) {
    if (pipe == NULL) {
        return false;
    }

    return (ring_buffer_available(pipe) > 0) || atomic_load(&pipe->write_closed);
}

/**
 * Check if writable
 */
bool ios_pipe_poll_writable(ios_buffered_pipe_t* pipe) {
    if (pipe == NULL) {
        return false;
    }

    return (ring_buffer_space(pipe) > 0) && !atomic_load(&pipe->write_closed) && !atomic_load(&pipe->read_closed);
}

/**
 * Get statistics
 */
int ios_pipe_get_stats(ios_buffered_pipe_t* pipe, ios_pipe_stats_t* stats) {
    if (pipe == NULL || stats == NULL) {
        errno = EINVAL;
        return -1;
    }

    stats->bytes_written = atomic_load(&pipe->total_written);
    stats->bytes_read = atomic_load(&pipe->total_read);
    stats->buffer_used = ring_buffer_available(pipe);
    stats->buffer_size = pipe->capacity;
    stats->writer_waits = atomic_load(&pipe->writer_waits);
    stats->reader_waits = atomic_load(&pipe->reader_waits);
    stats->is_closed = atomic_load(&pipe->write_closed);
    stats->is_eof = atomic_load(&pipe->write_closed) && (stats->buffer_used == 0);

    return 0;
}

/**
 * Flush pipe
 */
int ios_pipe_flush(ios_buffered_pipe_t* pipe, int timeout_ms) {
    if (pipe == NULL) {
        errno = EINVAL;
        return -1;
    }

    struct timespec start, now;
    clock_gettime(CLOCK_MONOTONIC, &start);

    pthread_mutex_lock(&pipe->mutex);

    while (ring_buffer_available(pipe) > 0) {
        pthread_mutex_unlock(&pipe->mutex);

        // Check timeout
        if (timeout_ms >= 0) {
            clock_gettime(CLOCK_MONOTONIC, &now);
            long elapsed_ms = (now.tv_sec - start.tv_sec) * 1000 +
                             (now.tv_nsec - start.tv_nsec) / 1000000;

            if (elapsed_ms >= timeout_ms) {
                errno = ETIMEDOUT;
                return -1;
            }
        }

        usleep(1000);  // 1ms
        pthread_mutex_lock(&pipe->mutex);
    }

    pthread_mutex_unlock(&pipe->mutex);
    return 0;
}

/**
 * Get available bytes
 */
size_t ios_pipe_available(ios_buffered_pipe_t* pipe) {
    if (pipe == NULL) {
        return 0;
    }

    return ring_buffer_available(pipe);
}

/**
 * Get space available
 */
size_t ios_pipe_space_available(ios_buffered_pipe_t* pipe) {
    if (pipe == NULL) {
        return 0;
    }

    return ring_buffer_space(pipe);
}

/**
 * Get read/write FDs (not supported for buffered pipes)
 */
int ios_pipe_get_read_fd(ios_buffered_pipe_t* pipe) {
    return -1;  // Not supported
}

int ios_pipe_get_write_fd(ios_buffered_pipe_t* pipe) {
    return -1;  // Not supported
}

/**
 * FILE* wrappers using funopen() (macOS/iOS)
 */

// Read callback for funopen
static int pipe_read_fn(void* cookie, char* buf, int size) {
    ios_buffered_pipe_t* pipe = (ios_buffered_pipe_t*)cookie;
    ssize_t result = ios_pipe_read(pipe, buf, size);
    if (result < 0) {
        return -1;  // Error
    }
    return (int)result;
}

// Write callback for funopen
static int pipe_write_fn(void* cookie, const char* buf, int size) {
    ios_buffered_pipe_t* pipe = (ios_buffered_pipe_t*)cookie;
    ssize_t result = ios_pipe_write(pipe, buf, size);
    if (result < 0) {
        return -1;  // Error
    }
    return (int)result;
}

// Close callback for funopen (for read end)
static int pipe_close_read_fn(void* cookie) {
    ios_buffered_pipe_t* pipe = (ios_buffered_pipe_t*)cookie;
    return ios_pipe_close_read(pipe);
}

// Close callback for funopen (for write end)
static int pipe_close_write_fn(void* cookie) {
    ios_buffered_pipe_t* pipe = (ios_buffered_pipe_t*)cookie;
    return ios_pipe_close_write(pipe);
}

FILE* ios_pipe_fdopen_read(ios_buffered_pipe_t* pipe) {
    if (pipe == NULL) {
        errno = EINVAL;
        return NULL;
    }

    // funopen(cookie, read_fn, write_fn, seek_fn, close_fn)
    // For read: provide read_fn and close_fn, NULL for write and seek
    FILE* fp = funopen(pipe, pipe_read_fn, NULL, NULL, pipe_close_read_fn);
    if (fp == NULL) {
        return NULL;
    }

    // Disable buffering for more responsive pipe behavior
    setvbuf(fp, NULL, _IONBF, 0);

    return fp;
}

FILE* ios_pipe_fdopen_write(ios_buffered_pipe_t* pipe) {
    if (pipe == NULL) {
        errno = EINVAL;
        return NULL;
    }

    // funopen(cookie, read_fn, write_fn, seek_fn, close_fn)
    // For write: provide write_fn and close_fn, NULL for read and seek
    FILE* fp = funopen(pipe, NULL, pipe_write_fn, NULL, pipe_close_write_fn);
    if (fp == NULL) {
        return NULL;
    }

    // Disable buffering for more responsive pipe behavior
    setvbuf(fp, NULL, _IONBF, 0);

    return fp;
}
