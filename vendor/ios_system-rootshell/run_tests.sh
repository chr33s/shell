#!/bin/bash
#
# run_tests.sh
# Comprehensive test runner for ios_system concurrency tests
#
# Usage:
#   ./run_tests.sh [tsan|asan|both|standard]
#

set -e

SCHEME="ios_system"
SDK="iphonesimulator"
DESTINATION="platform=iOS Simulator,name=iPhone 15"

print_header() {
    echo ""
    echo "=========================================="
    echo "$1"
    echo "=========================================="
    echo ""
}

run_standard_tests() {
    print_header "Running Standard Tests"

    xcodebuild test \
        -project ios_system.xcodeproj \
        -scheme "$SCHEME" \
        -sdk "$SDK" \
        -destination "$DESTINATION" \
        2>&1 | tee test_standard.log

    echo ""
    echo "✅ Standard tests complete. Results in test_standard.log"
}

run_tsan_tests() {
    print_header "Running Tests with Thread Sanitizer (TSan)"

    xcodebuild test \
        -project ios_system.xcodeproj \
        -scheme "$SCHEME" \
        -sdk "$SDK" \
        -destination "$DESTINATION" \
        -enableThreadSanitizer YES \
        2>&1 | tee test_tsan.log

    echo ""
    echo "Checking for TSan warnings..."

    if grep -q "WARNING: ThreadSanitizer" test_tsan.log; then
        echo "❌ TSan detected issues!"
        echo ""
        grep -A 5 "WARNING: ThreadSanitizer" test_tsan.log
        exit 1
    else
        echo "✅ No TSan warnings detected"
    fi

    echo "Results in test_tsan.log"
}

run_asan_tests() {
    print_header "Running Tests with Address Sanitizer (ASan)"

    xcodebuild test \
        -project ios_system.xcodeproj \
        -scheme "$SCHEME" \
        -sdk "$SDK" \
        -destination "$DESTINATION" \
        -enableAddressSanitizer YES \
        2>&1 | tee test_asan.log

    echo ""
    echo "Checking for ASan warnings..."

    if grep -q "ERROR: AddressSanitizer" test_asan.log; then
        echo "❌ ASan detected issues!"
        echo ""
        grep -A 5 "ERROR: AddressSanitizer" test_asan.log
        exit 1
    else
        echo "✅ No ASan errors detected"
    fi

    echo "Results in test_asan.log"
}

show_summary() {
    print_header "Test Summary"

    if [ -f test_standard.log ]; then
        echo "Standard Tests:"
        grep "Test Suite.*passed" test_standard.log | tail -1 || echo "  (not run)"
    fi

    if [ -f test_tsan.log ]; then
        echo "TSan Tests:"
        grep "Test Suite.*passed" test_tsan.log | tail -1 || echo "  (not run)"
    fi

    if [ -f test_asan.log ]; then
        echo "ASan Tests:"
        grep "Test Suite.*passed" test_asan.log | tail -1 || echo "  (not run)"
    fi

    echo ""
}

# Main execution
MODE="${1:-standard}"

case "$MODE" in
    standard)
        run_standard_tests
        ;;
    tsan)
        run_tsan_tests
        ;;
    asan)
        run_asan_tests
        ;;
    both)
        run_tsan_tests
        run_asan_tests
        ;;
    all)
        run_standard_tests
        run_tsan_tests
        run_asan_tests
        ;;
    *)
        echo "Usage: $0 [standard|tsan|asan|both|all]"
        echo ""
        echo "  standard - Run tests without sanitizers"
        echo "  tsan     - Run with Thread Sanitizer"
        echo "  asan     - Run with Address Sanitizer"
        echo "  both     - Run with TSan and ASan"
        echo "  all      - Run all test modes"
        exit 1
        ;;
esac

show_summary

echo ""
echo "✅ All requested tests complete!"
