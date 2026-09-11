/*
 * ios_buffered_pipe.h
 * Lock-free buffered pipe system for parallel pipeline execution
 *
 * Provides high-performance ring buffer-based pipes that allow
 * producer and consumer to run in parallel with automatic backpressure.
 * Replaces direct pipe() calls to enable true pipeline parallelism.
 */

#ifndef IOS_BUFFERED_PIPE_H
#define IOS_BUFFERED_PIPE_H

#include <stdio.h>
#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque pipe handle
typedef struct _ios_buffered_pipe ios_buffered_pipe_t;

// Pipe configuration
typedef struct {
    size_t buffer_size;        // Ring buffer size in bytes (default: 64KB)
    int read_timeout_ms;       // Read timeout in milliseconds (-1 = infinite)
    int write_timeout_ms;      // Write timeout in milliseconds (-1 = infinite)
    bool suppress_sigpipe;     // Suppress SIGPIPE on write to closed pipe
} ios_pipe_config_t;

// Pipe statistics
typedef struct {
    uint64_t bytes_written;    // Total bytes written to pipe
    uint64_t bytes_read;       // Total bytes read from pipe
    size_t buffer_used;        // Current buffer utilization
    size_t buffer_size;        // Total buffer capacity
    int writer_waits;          // Number of times writer blocked
    int reader_waits;          // Number of times reader blocked
    bool is_closed;            // Pipe closed for writing
    bool is_eof;               // Pipe reached EOF
} ios_pipe_stats_t;

/**
 * Create buffered pipe with default configuration
 * Default: 64KB buffer, no timeouts, SIGPIPE suppressed
 *
 * @return Pipe handle or NULL on error
 *
 * Thread-safe: Can be called from any thread
 */
ios_buffered_pipe_t* ios_pipe_create_default(void);

/**
 * Create buffered pipe with custom configuration
 *
 * @param config Pipe configuration
 * @return Pipe handle or NULL on error
 *
 * Thread-safe: Can be called from any thread
 */
ios_buffered_pipe_t* ios_pipe_create(const ios_pipe_config_t* config);

/**
 * Write data to pipe
 * Blocks if buffer is full (backpressure)
 *
 * @param pipe Pipe handle
 * @param data Data to write
 * @param size Number of bytes to write
 * @return Number of bytes written, or -1 on error (sets errno)
 *
 * Thread-safe: Multiple writers NOT supported (single writer only)
 * Returns:
 *   > 0: Bytes written (may be less than size if timeout or pipe closed)
 *   0: Pipe closed for writing
 *   -1: Error (check errno: ETIMEDOUT, EPIPE, etc.)
 */
ssize_t ios_pipe_write(ios_buffered_pipe_t* pipe, const void* data, size_t size);

/**
 * Write data with timeout override
 *
 * @param pipe Pipe handle
 * @param data Data to write
 * @param size Number of bytes to write
 * @param timeout_ms Timeout in milliseconds (-1 = infinite, 0 = non-blocking)
 * @return Number of bytes written, or -1 on error
 */
ssize_t ios_pipe_write_timeout(ios_buffered_pipe_t* pipe, const void* data,
                                size_t size, int timeout_ms);

/**
 * Read data from pipe
 * Blocks if buffer is empty
 *
 * @param pipe Pipe handle
 * @param buffer Buffer to read into
 * @param size Maximum bytes to read
 * @return Number of bytes read, 0 on EOF, or -1 on error
 *
 * Thread-safe: Multiple readers NOT supported (single reader only)
 * Returns:
 *   > 0: Bytes read (may be less than size)
 *   0: EOF reached (pipe closed and buffer empty)
 *   -1: Error (check errno)
 */
ssize_t ios_pipe_read(ios_buffered_pipe_t* pipe, void* buffer, size_t size);

/**
 * Read data with timeout override
 *
 * @param pipe Pipe handle
 * @param buffer Buffer to read into
 * @param size Maximum bytes to read
 * @param timeout_ms Timeout in milliseconds (-1 = infinite, 0 = non-blocking)
 * @return Number of bytes read, 0 on EOF, or -1 on error
 */
ssize_t ios_pipe_read_timeout(ios_buffered_pipe_t* pipe, void* buffer,
                               size_t size, int timeout_ms);

/**
 * Close pipe for writing
 * Subsequent writes will fail with EPIPE
 * Reader will see EOF after draining remaining data
 *
 * @param pipe Pipe handle
 * @return 0 on success, -1 on error
 *
 * Thread-safe: Can be called concurrently with read/write
 */
int ios_pipe_close_write(ios_buffered_pipe_t* pipe);

/**
 * Close pipe for reading
 * Subsequent reads will return EOF immediately
 * Writer will fail with EPIPE
 *
 * @param pipe Pipe handle
 * @return 0 on success, -1 on error
 *
 * Thread-safe: Can be called concurrently with read/write
 */
int ios_pipe_close_read(ios_buffered_pipe_t* pipe);

/**
 * Destroy pipe and free resources
 * Closes both ends if not already closed
 *
 * @param pipe Pipe handle
 *
 * Thread-safe: Must not be called concurrently with read/write
 */
void ios_pipe_destroy(ios_buffered_pipe_t* pipe);

/**
 * Get pipe file descriptor for reading
 * For integration with select()/poll()
 *
 * @param pipe Pipe handle
 * @return File descriptor or -1 if not supported
 *
 * Note: Buffered pipes may not support this (returns -1)
 * Use ios_pipe_poll_readable() instead
 */
int ios_pipe_get_read_fd(ios_buffered_pipe_t* pipe);

/**
 * Get pipe file descriptor for writing
 *
 * @param pipe Pipe handle
 * @return File descriptor or -1 if not supported
 */
int ios_pipe_get_write_fd(ios_buffered_pipe_t* pipe);

/**
 * Check if pipe is readable without blocking
 *
 * @param pipe Pipe handle
 * @return true if data available or EOF, false if would block
 */
bool ios_pipe_poll_readable(ios_buffered_pipe_t* pipe);

/**
 * Check if pipe is writable without blocking
 *
 * @param pipe Pipe handle
 * @return true if space available, false if would block
 */
bool ios_pipe_poll_writable(ios_buffered_pipe_t* pipe);

/**
 * Get pipe statistics
 *
 * @param pipe Pipe handle
 * @param stats Output: statistics structure
 * @return 0 on success, -1 on error
 */
int ios_pipe_get_stats(ios_buffered_pipe_t* pipe, ios_pipe_stats_t* stats);

/**
 * Flush pipe (wait for reader to drain)
 * Blocks until buffer is empty or timeout
 *
 * @param pipe Pipe handle
 * @param timeout_ms Timeout in milliseconds (-1 = infinite)
 * @return 0 if flushed, -1 on timeout or error
 */
int ios_pipe_flush(ios_buffered_pipe_t* pipe, int timeout_ms);

/**
 * Get number of bytes available for reading
 *
 * @param pipe Pipe handle
 * @return Number of bytes available, or 0 if empty/closed
 */
size_t ios_pipe_available(ios_buffered_pipe_t* pipe);

/**
 * Get number of bytes available for writing
 *
 * @param pipe Pipe handle
 * @return Number of bytes that can be written without blocking
 */
size_t ios_pipe_space_available(ios_buffered_pipe_t* pipe);

/**
 * Create FILE* wrapper for reading
 * Creates a FILE* that reads from the buffered pipe
 *
 * @param pipe Pipe handle
 * @return FILE* for reading or NULL on error
 *
 * Note: Caller must fclose() the returned FILE*
 * The FILE* is buffered separately from the pipe buffer
 */
FILE* ios_pipe_fdopen_read(ios_buffered_pipe_t* pipe);

/**
 * Create FILE* wrapper for writing
 *
 * @param pipe Pipe handle
 * @return FILE* for writing or NULL on error
 */
FILE* ios_pipe_fdopen_write(ios_buffered_pipe_t* pipe);

#ifdef __cplusplus
}
#endif

#endif /* IOS_BUFFERED_PIPE_H */
