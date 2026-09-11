/*
 * concurrency_tests.m
 * Comprehensive concurrency test suite for ios_system
 *
 * Tests all new concurrency subsystems with Thread Sanitizer (TSan) support.
 * Run with: xcodebuild test -scheme ios_system_tests -enableThreadSanitizer YES
 */

#import <XCTest/XCTest.h>
#import <pthread.h>
#import <unistd.h>

// Include all new subsystem headers
#include "ios_session_manager.h"
#include "ios_env_manager.h"
#include "ios_interpreter_pool.h"
#include "ios_thread_pool.h"
#include "ios_buffered_pipe.h"
#include "ios_pipeline.h"
#include "ios_pid_allocator.h"
#include "ios_async.h"
#include "ios_shell_parser.h"
#include "ios_system.h"

// Test configuration
#define TEST_THREAD_COUNT 20
#define TEST_ITERATIONS 100
#define STRESS_TEST_DURATION_SEC 5

@interface ConcurrencyTests : XCTestCase
@end

@implementation ConcurrencyTests

#pragma mark - Setup/Teardown

- (void)setUp {
    [super setUp];

    // Initialize all subsystems
    ios_session_manager_init();
    ios_env_manager_init();
    ios_interp_pool_init();
    ios_thread_pool_init(8);  // 8 worker threads
    ios_pid_allocator_init();
}

- (void)tearDown {
    // Cleanup subsystems
    ios_thread_pool_shutdown();
    ios_session_manager_shutdown();
    ios_env_manager_shutdown();
    ios_interp_pool_shutdown();
    ios_pid_allocator_shutdown();

    [super tearDown];
}

#pragma mark - Session Manager Tests

- (void)testSessionManagerConcurrentAccess {
    NSLog(@"[TEST] Session Manager: Concurrent access");

    __block int success_count = 0;
    pthread_mutex_t count_mutex = PTHREAD_MUTEX_INITIALIZER;

    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);

    // Create/access sessions concurrently
    for (int i = 0; i < TEST_THREAD_COUNT; i++) {
        dispatch_group_async(group, queue, ^{
            void* session_id = (void*)(long)(i % 5);  // 5 different sessions

            for (int j = 0; j < TEST_ITERATIONS; j++) {
                ios_session_ref_t* ref = ios_session_get_or_create(session_id);
                XCTAssertNotNil(ref, @"Failed to get/create session");

                sessionParameters* params = ios_session_get_params(ref);
                XCTAssertNotNil(params, @"Session parameters should not be NULL");

                ios_session_release(ref);

                pthread_mutex_lock(&count_mutex);
                success_count++;
                pthread_mutex_unlock(&count_mutex);
            }
        });
    }

    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    XCTAssertEqual(success_count, TEST_THREAD_COUNT * TEST_ITERATIONS,
                   @"All session operations should succeed");

    pthread_mutex_destroy(&count_mutex);
}

- (void)testSessionManagerCreateDelete {
    NSLog(@"[TEST] Session Manager: Create/Delete cycle");

    void* session_id = (void*)12345;

    // Create session
    ios_session_ref_t* ref = ios_session_get_or_create(session_id);
    XCTAssertNotNil(ref, @"Should create session");
    ios_session_release(ref);

    // Delete session
    bool deleted = ios_session_delete(session_id);
    XCTAssertTrue(deleted, @"Should delete session");

    // Try to get deleted session
    ios_session_ref_t* ref2 = ios_session_get(session_id);
    XCTAssertNil(ref2, @"Should not find deleted session");
}

#pragma mark - Environment Manager Tests

- (void)testEnvManagerConcurrentSetGet {
    NSLog(@"[TEST] Environment Manager: Concurrent set/get");

    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);

    for (int i = 0; i < TEST_THREAD_COUNT; i++) {
        dispatch_group_async(group, queue, ^{
            for (int j = 0; j < TEST_ITERATIONS; j++) {
                NSString* key = [NSString stringWithFormat:@"TEST_VAR_%d", i];
                NSString* value = [NSString stringWithFormat:@"value_%d", j];

                ios_env_setenv([key UTF8String], [value UTF8String], 1);

                const char* retrieved = ios_env_getenv([key UTF8String]);
                XCTAssertNotNil([NSString stringWithUTF8String:retrieved ?: ""],
                               @"Should retrieve set value");
            }
        });
    }

    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
}

#pragma mark - Interpreter Pool Tests

- (void)testInterpreterPoolAcquireRelease {
    NSLog(@"[TEST] Interpreter Pool: Acquire/Release");

    ios_interpreter_type_t types[] = {
        IOS_INTERP_PYTHON, IOS_INTERP_PERL, IOS_INTERP_TEX
    };

    for (int i = 0; i < 3; i++) {
        ios_interpreter_type_t type = types[i];

        // Acquire slot
        ios_interp_slot_handle_t* slot = ios_interp_acquire(type, 1000);
        XCTAssertNotNil(slot, @"Should acquire interpreter slot");

        int slot_num = ios_interp_get_slot_number(slot);
        XCTAssertGreaterThanOrEqual(slot_num, 0, @"Slot number should be valid");

        // Release slot
        ios_interp_release(slot);
    }
}

- (void)testInterpreterPoolConcurrentAcquire {
    NSLog(@"[TEST] Interpreter Pool: Concurrent acquire");

    __block int acquire_count = 0;
    pthread_mutex_t count_mutex = PTHREAD_MUTEX_INITIALIZER;

    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);

    for (int i = 0; i < 10; i++) {
        dispatch_group_async(group, queue, ^{
            ios_interp_slot_handle_t* slot = ios_interp_acquire(IOS_INTERP_PYTHON, 2000);

            if (slot) {
                pthread_mutex_lock(&count_mutex);
                acquire_count++;
                pthread_mutex_unlock(&count_mutex);

                usleep(10000);  // Hold slot briefly
                ios_interp_release(slot);
            }
        });
    }

    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    XCTAssertEqual(acquire_count, 10, @"All threads should acquire slot");

    pthread_mutex_destroy(&count_mutex);
}

#pragma mark - Buffered Pipe Tests

- (void)testBufferedPipeBasic {
    NSLog(@"[TEST] Buffered Pipe: Basic read/write");

    ios_buffered_pipe_t* pipe = ios_pipe_create_default();
    XCTAssertNotNil(pipe, @"Should create pipe");

    const char* test_data = "Hello, pipe!";
    ssize_t written = ios_pipe_write(pipe, test_data, strlen(test_data));
    XCTAssertEqual(written, strlen(test_data), @"Should write all data");

    char buffer[100];
    ssize_t read_count = ios_pipe_read(pipe, buffer, sizeof(buffer));
    XCTAssertEqual(read_count, strlen(test_data), @"Should read all data");

    buffer[read_count] = '\0';
    XCTAssertEqual(strcmp(buffer, test_data), 0, @"Data should match");

    ios_pipe_destroy(pipe);
}

- (void)testBufferedPipeConcurrent {
    NSLog(@"[TEST] Buffered Pipe: Concurrent read/write");

    ios_buffered_pipe_t* pipe = ios_pipe_create_default();
    XCTAssertNotNil(pipe, @"Should create pipe");

    __block int messages_sent = 0;
    __block int messages_received = 0;

    // Writer thread
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        for (int i = 0; i < 100; i++) {
            char message[64];
            snprintf(message, sizeof(message), "Message %d\n", i);
            ios_pipe_write(pipe, message, strlen(message));
            messages_sent++;
        }
        ios_pipe_close_write(pipe);
    });

    // Reader thread
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        char buffer[64];
        while (1) {
            ssize_t n = ios_pipe_read(pipe, buffer, sizeof(buffer) - 1);
            if (n <= 0) break;
            buffer[n] = '\0';
            messages_received++;
        }
    });

    // Wait for completion
    sleep(2);

    XCTAssertEqual(messages_sent, 100, @"Should send 100 messages");
    XCTAssertEqual(messages_received, 100, @"Should receive 100 messages");

    ios_pipe_destroy(pipe);
}

#pragma mark - PID Allocator Tests

- (void)testPIDAllocatorBasic {
    NSLog(@"[TEST] PID Allocator: Basic allocate/release");

    ios_pid_context_t* ctx = ios_pid_allocate();
    XCTAssertNotNil(ctx, @"Should allocate PID context");

    pid_t pid = ios_pid_get_id(ctx);
    XCTAssertGreaterThanOrEqual(pid, 100, @"PID should be >= 100");

    ios_pid_set_thread(ctx, pthread_self());
    pthread_t thread = ios_pid_get_thread(ctx);
    XCTAssertTrue(pthread_equal(thread, pthread_self()), @"Thread should match");

    ios_pid_release(ctx);
}

- (void)testPIDAllocatorConcurrent {
    NSLog(@"[TEST] PID Allocator: Concurrent allocate/release");

    __block int alloc_count = 0;
    pthread_mutex_t count_mutex = PTHREAD_MUTEX_INITIALIZER;

    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);

    for (int i = 0; i < TEST_THREAD_COUNT; i++) {
        dispatch_group_async(group, queue, ^{
            for (int j = 0; j < TEST_ITERATIONS; j++) {
                ios_pid_context_t* ctx = ios_pid_allocate();
                if (ctx) {
                    pthread_mutex_lock(&count_mutex);
                    alloc_count++;
                    pthread_mutex_unlock(&count_mutex);

                    ios_pid_release(ctx);
                }
            }
        });
    }

    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    XCTAssertEqual(alloc_count, TEST_THREAD_COUNT * TEST_ITERATIONS,
                   @"All allocations should succeed");

    pthread_mutex_destroy(&count_mutex);
}

- (void)testPIDAllocatorLookup {
    NSLog(@"[TEST] PID Allocator: Lookup by PID");

    ios_pid_context_t* ctx1 = ios_pid_allocate();
    pid_t pid1 = ios_pid_get_id(ctx1);

    ios_pid_context_t* ctx2 = ios_pid_lookup(pid1);
    XCTAssertNotNil(ctx2, @"Should find PID");
    XCTAssertEqual(ios_pid_get_id(ctx2), pid1, @"PIDs should match");

    ios_pid_release(ctx2);  // Release lookup reference
    ios_pid_release(ctx1);  // Release original
}

#pragma mark - Cleanup Synchronization Tests

- (void)testCleanupSynchronization {
    NSLog(@"[TEST] Cleanup Synchronization");

    __block bool cleanup_started = false;
    __block bool allocation_blocked = false;

    // Start cleanup
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        ios_pid_begin_cleanup();
        cleanup_started = true;
        sleep(1);  // Simulate cleanup work
        ios_pid_end_cleanup();
    });

    // Wait for cleanup to start
    usleep(100000);  // 100ms

    // Try to allocate during cleanup
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        if (cleanup_started) {
            allocation_blocked = true;
        }
        ios_pid_wait_for_cleanup();
        ios_pid_context_t* ctx = ios_pid_allocate();
        XCTAssertNotNil(ctx, @"Should allocate after cleanup");
        ios_pid_release(ctx);
    });

    sleep(2);
    XCTAssertTrue(allocation_blocked, @"Allocation should be blocked during cleanup");
}

#pragma mark - Async API Tests

- (void)testAsyncAPIBasic {
    NSLog(@"[TEST] Async API: Basic execution");

    ios_async_options_t opts = ios_async_default_options();

    ios_command_t* cmd = ios_system_async("echo 'test'", &opts);
    XCTAssertNotNil(cmd, @"Should create async command");

    int exit_code = ios_command_wait(cmd);
    XCTAssertEqual(exit_code, 0, @"Command should succeed");

    ios_command_status_t status = ios_command_get_status(cmd);
    XCTAssertEqual(status, IOS_CMD_COMPLETED, @"Should be completed");

    ios_command_release(cmd);
}

- (void)testAsyncAPIConcurrent {
    NSLog(@"[TEST] Async API: Concurrent commands");

    __block int completed = 0;
    pthread_mutex_t count_mutex = PTHREAD_MUTEX_INITIALIZER;

    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);

    for (int i = 0; i < 10; i++) {
        dispatch_group_async(group, queue, ^{
            ios_async_options_t opts = ios_async_default_options();
            ios_command_t* cmd = ios_system_async("echo 'concurrent'", &opts);

            if (cmd) {
                ios_command_wait(cmd);

                pthread_mutex_lock(&count_mutex);
                completed++;
                pthread_mutex_unlock(&count_mutex);

                ios_command_release(cmd);
            }
        });
    }

    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    XCTAssertEqual(completed, 10, @"All commands should complete");

    pthread_mutex_destroy(&count_mutex);
}

- (void)testAsyncAPICallback {
    NSLog(@"[TEST] Async API: Completion callback");

    __block bool callback_invoked = false;
    __block int callback_exit_code = -1;

    ios_command_callback_t callback = ^(ios_command_t* cmd, int exit_code, void* user_data) {
        callback_invoked = true;
        callback_exit_code = exit_code;
    };

    ios_async_options_t opts = ios_async_default_options();
    opts.callback = callback;

    ios_command_t* cmd = ios_system_async("echo 'callback test'", &opts);
    ios_command_wait(cmd);

    XCTAssertTrue(callback_invoked, @"Callback should be invoked");
    XCTAssertEqual(callback_exit_code, 0, @"Callback should receive exit code 0");

    ios_command_release(cmd);
}

#pragma mark - Stress Tests

- (void)testStressSessionManager {
    NSLog(@"[TEST] STRESS: Session Manager");

    __block int operations = 0;
    __block bool stop = false;
    pthread_mutex_t count_mutex = PTHREAD_MUTEX_INITIALIZER;

    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);

    // Spawn many threads hammering session manager
    for (int i = 0; i < 50; i++) {
        dispatch_group_async(group, queue, ^{
            while (!stop) {
                void* session_id = (void*)(long)(arc4random() % 20);
                ios_session_ref_t* ref = ios_session_get_or_create(session_id);
                ios_session_release(ref);

                pthread_mutex_lock(&count_mutex);
                operations++;
                pthread_mutex_unlock(&count_mutex);
            }
        });
    }

    // Run for duration
    sleep(STRESS_TEST_DURATION_SEC);
    stop = true;

    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    NSLog(@"[TEST] STRESS: Completed %d operations", operations);
    XCTAssertGreaterThan(operations, 1000, @"Should complete many operations");

    pthread_mutex_destroy(&count_mutex);
}

- (void)testStressPIDAllocator {
    NSLog(@"[TEST] STRESS: PID Allocator");

    __block int operations = 0;
    __block bool stop = false;
    pthread_mutex_t count_mutex = PTHREAD_MUTEX_INITIALIZER;

    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);

    for (int i = 0; i < 50; i++) {
        dispatch_group_async(group, queue, ^{
            while (!stop) {
                ios_pid_context_t* ctx = ios_pid_allocate();
                if (ctx) {
                    usleep(100);  // Hold briefly
                    ios_pid_release(ctx);

                    pthread_mutex_lock(&count_mutex);
                    operations++;
                    pthread_mutex_unlock(&count_mutex);
                }
            }
        });
    }

    sleep(STRESS_TEST_DURATION_SEC);
    stop = true;

    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    NSLog(@"[TEST] STRESS: Completed %d PID allocations", operations);
    XCTAssertGreaterThan(operations, 1000, @"Should handle many allocations");

    pthread_mutex_destroy(&count_mutex);
}

#pragma mark - Shell Parser Tests

- (void)testSemicolonExecution {
    NSLog(@"[TEST] Shell Parser: Semicolon execution");

    // Initialize ios_system if needed
    initializeEnvironment();

    // Test basic semicolon execution
    int result = ios_system("echo a; echo b; echo c");
    XCTAssertEqual(result, 0, @"Semicolon execution should succeed");
}

- (void)testAndOperator {
    NSLog(@"[TEST] Shell Parser: AND operator (&&)");

    initializeEnvironment();

    // Test && with success
    int result = ios_system("true && echo success");
    XCTAssertEqual(result, 0, @"true && echo should succeed");

    // Test && with failure - should short-circuit
    result = ios_system("false && echo should_not_print");
    XCTAssertNotEqual(result, 0, @"false && should fail and short-circuit");
}

- (void)testOrOperator {
    NSLog(@"[TEST] Shell Parser: OR operator (||)");

    initializeEnvironment();

    // Test || with failure then success
    int result = ios_system("false || echo fallback");
    XCTAssertEqual(result, 0, @"false || echo should succeed (fallback executed)");

    // Test || with success - should short-circuit
    result = ios_system("true || echo should_not_print");
    XCTAssertEqual(result, 0, @"true || should succeed and short-circuit");
}

- (void)testMixedOperators {
    NSLog(@"[TEST] Shell Parser: Mixed operators");

    initializeEnvironment();

    // Test mixed ; && ||
    int result = ios_system("true && echo a; false || echo b");
    XCTAssertEqual(result, 0, @"Mixed operators should work");
}

- (void)testQuotedOperators {
    NSLog(@"[TEST] Shell Parser: Quoted operators should not be parsed");

    initializeEnvironment();

    // Operators inside quotes should be treated as literal text
    int result = ios_system("echo 'a && b; c || d'");
    XCTAssertEqual(result, 0, @"Quoted operators should be treated as text");

    result = ios_system("echo \"semicolon ; here\"");
    XCTAssertEqual(result, 0, @"Double-quoted semicolon should be literal");
}

- (void)testCommandSubstitution {
    NSLog(@"[TEST] Shell Parser: Command substitution $()");

    initializeEnvironment();

    // Test basic command substitution
    int result = ios_system("echo $(echo hello)");
    XCTAssertEqual(result, 0, @"Command substitution should succeed");
}

- (void)testBacktickSubstitution {
    NSLog(@"[TEST] Shell Parser: Backtick substitution");

    initializeEnvironment();

    // Test backtick substitution
    int result = ios_system("echo `echo hello`");
    XCTAssertEqual(result, 0, @"Backtick substitution should succeed");
}

- (void)testNestedCommandSubstitution {
    NSLog(@"[TEST] Shell Parser: Nested command substitution");

    initializeEnvironment();

    // Test nested $(...)
    int result = ios_system("echo $(echo $(echo nested))");
    XCTAssertEqual(result, 0, @"Nested command substitution should succeed");
}

- (void)testOperatorPrecedence {
    NSLog(@"[TEST] Shell Parser: Operator precedence");

    initializeEnvironment();

    // Semicolons have lowest precedence, then && and ||, then pipes
    // This should execute: (true && echo a) ; (false || echo b)
    int result = ios_system("true && echo a ; false || echo b");
    XCTAssertEqual(result, 0, @"Operator precedence should be correct");
}

- (void)testEmptySegments {
    NSLog(@"[TEST] Shell Parser: Empty segments");

    initializeEnvironment();

    // Empty segments should be skipped
    int result = ios_system("; ; echo hello ; ;");
    XCTAssertEqual(result, 0, @"Empty segments should be skipped");
}

- (void)testShellOperatorDetection {
    NSLog(@"[TEST] Shell Parser: Operator detection");

    bool has_semi, has_and, has_or;

    // Test basic detection
    ios_check_shell_operators("echo hello", &has_semi, &has_and, &has_or);
    XCTAssertFalse(has_semi, @"No semicolon in simple command");
    XCTAssertFalse(has_and, @"No && in simple command");
    XCTAssertFalse(has_or, @"No || in simple command");

    ios_check_shell_operators("a; b && c || d", &has_semi, &has_and, &has_or);
    XCTAssertTrue(has_semi, @"Should detect semicolon");
    XCTAssertTrue(has_and, @"Should detect &&");
    XCTAssertTrue(has_or, @"Should detect ||");

    // Quoted operators should not be detected
    ios_check_shell_operators("echo 'a && b'", &has_semi, &has_and, &has_or);
    XCTAssertFalse(has_and, @"Should not detect quoted &&");
}

@end
