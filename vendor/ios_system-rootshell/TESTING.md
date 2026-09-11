# ios_system Concurrency Testing Guide

This document describes the comprehensive concurrency test suite for ios_system and how to run it with Thread Sanitizer (TSan).

## Test Suite Overview

The test suite (`concurrency_tests.m`) comprehensively tests all new concurrency subsystems:

### 1. Session Manager Tests
- `testSessionManagerConcurrentAccess` - 20 threads creating/accessing 5 sessions concurrently
- `testSessionManagerCreateDelete` - Session lifecycle testing
- **Coverage:** Thread-safe session creation, reference counting, deletion

### 2. Environment Manager Tests
- `testEnvManagerConcurrentSetGet` - Concurrent environment variable operations
- **Coverage:** Thread-local environment isolation, COW semantics

### 3. Interpreter Pool Tests
- `testInterpreterPoolAcquireRelease` - Basic slot acquisition
- `testInterpreterPoolConcurrentAcquire` - Multiple threads acquiring slots
- **Coverage:** Lock-free slot allocation, semaphore coordination

### 4. Buffered Pipe Tests
- `testBufferedPipeBasic` - Basic read/write operations
- `testBufferedPipeConcurrent` - Concurrent producer/consumer
- **Coverage:** Ring buffer, atomic head/tail, backpressure

### 5. PID Allocator Tests
- `testPIDAllocatorBasic` - Basic allocation/release
- `testPIDAllocatorConcurrent` - 20 threads, 100 iterations each
- `testPIDAllocatorLookup` - Hash table lookup by PID
- **Coverage:** Lock-free free-list, hash table, reference counting

### 6. Cleanup Synchronization Tests
- `testCleanupSynchronization` - Condition variable blocking
- **Coverage:** Cleanup synchronization, no spinlocks

### 7. Async API Tests
- `testAsyncAPIBasic` - Basic async execution
- `testAsyncAPIConcurrent` - 10 concurrent async commands
- `testAsyncAPICallback` - Completion callbacks
- **Coverage:** Async execution, status tracking, callbacks

### 8. Stress Tests
- `testStressSessionManager` - 50 threads, 5 seconds
- `testStressPIDAllocator` - 50 threads, 5 seconds
- **Coverage:** Heavy concurrent load, race condition detection

## Running Tests

### Standard Unit Tests

Run tests from Xcode:
```bash
# Open project
open ios_system.xcodeproj

# Product > Test (Cmd+U)
# Or from command line:
xcodebuild test -scheme ios_system_tests -sdk iphonesimulator
```

### With Thread Sanitizer (TSan)

Thread Sanitizer detects:
- Data races
- Deadlocks
- Use of uninitialized mutexes
- Thread leaks

#### Enable TSan in Xcode:
1. Product > Scheme > Edit Scheme
2. Select "Test" action
3. Click "Diagnostics" tab
4. Check "Thread Sanitizer"
5. Product > Test (Cmd+U)

#### Enable TSan from Command Line:
```bash
xcodebuild test \
  -scheme ios_system_tests \
  -sdk iphonesimulator \
  -enableThreadSanitizer YES \
  | tee test_results.log
```

#### Analyze TSan Output:
```bash
# Filter for TSan warnings
grep -A 10 "WARNING: ThreadSanitizer" test_results.log

# Check for data races
grep "data race" test_results.log

# Check for deadlocks
grep "deadlock" test_results.log
```

### With Address Sanitizer (ASan)

Address Sanitizer detects:
- Memory leaks
- Use-after-free
- Buffer overflows
- Double-free

```bash
xcodebuild test \
  -scheme ios_system_tests \
  -sdk iphonesimulator \
  -enableAddressSanitizer YES
```

## Expected Results

All tests should **PASS** without any sanitizer warnings.

### Clean TSan Output:
```
Test Suite 'ConcurrencyTests' passed
Test Case '-[ConcurrencyTests testSessionManagerConcurrentAccess]' passed (0.234 seconds).
Test Case '-[ConcurrencyTests testPIDAllocatorConcurrent]' passed (0.456 seconds).
...
Executed 15 tests, with 0 failures (0 unexpected)
```

### TSan Warnings to Investigate:
- `WARNING: ThreadSanitizer: data race` - Indicates unsynchronized access
- `WARNING: ThreadSanitizer: lock-order-inversion (potential deadlock)` - Lock ordering issue
- `WARNING: ThreadSanitizer: destroy of a locked mutex` - Mutex lifecycle issue

## Debugging Failed Tests

### Data Race Example:
```
WARNING: ThreadSanitizer: data race (pid=12345)
  Write of size 4 at 0x7b0400001234 by thread T2:
    #0 ios_pid_allocate ios_pid_allocator.c:250

  Previous read of size 4 at 0x7b0400001234 by thread T1:
    #0 ios_pid_lookup ios_pid_allocator.c:320
```

**Fix:** Add proper atomic operations or locking around the shared variable.

### Deadlock Example:
```
WARNING: ThreadSanitizer: lock-order-inversion (potential deadlock)
  Mutex M1 acquired here while holding mutex M2:
    #0 pthread_mutex_lock
    #1 ios_session_get_or_create

  Mutex M2 previously acquired here while holding mutex M1:
    #0 pthread_mutex_lock
    #1 ios_session_delete
```

**Fix:** Establish consistent lock ordering across all code paths.

## Performance Benchmarks

Run stress tests to measure performance:

```bash
# Run only stress tests
xcodebuild test \
  -scheme ios_system_tests \
  -only-testing:ConcurrencyTests/testStressSessionManager \
  -only-testing:ConcurrencyTests/testStressPIDAllocator
```

Expected metrics (5 second stress test):
- Session Manager: >50,000 operations
- PID Allocator: >20,000 allocations
- Buffered Pipes: >10 MB/sec throughput

## Continuous Integration

### GitHub Actions Example:
```yaml
name: TSan Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v2
      - name: Run tests with TSan
        run: |
          xcodebuild test \
            -scheme ios_system_tests \
            -sdk iphonesimulator \
            -destination 'platform=iOS Simulator,name=iPhone 15' \
            -enableThreadSanitizer YES
```

## Test Maintenance

### Adding New Tests:
1. Add test method to `concurrency_tests.m`
2. Follow naming convention: `test<Subsystem><Scenario>`
3. Use `XCTAssert*` macros for assertions
4. Run with TSan to verify no races

### Test Coverage Goals:
- All public APIs tested
- All atomic operations verified
- All lock acquisitions tested for deadlocks
- Edge cases (empty state, full capacity, timeout)
- Stress tests for performance regression

## Known Issues

### False Positives:
- Some system libraries may trigger TSan warnings
- Filter these with TSan suppression files if needed

### Platform-Specific:
- Tests run on iOS Simulator (not device)
- TSan not available on iOS device builds
- Some timing-sensitive tests may be flaky

## Resources

- [Thread Sanitizer Documentation](https://developer.apple.com/documentation/xcode/diagnosing-memory-thread-and-crash-issues-early)
- [XCTest Framework Guide](https://developer.apple.com/documentation/xctest)
- [Concurrency Programming Guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ConcurrencyProgrammingGuide/)
