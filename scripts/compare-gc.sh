#!/bin/bash

# GC Comparison Test Script
# Runs load tests against both G1GC and Parallel GC servers

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Default settings
G1GC_PORT="${G1GC_PORT:-8080}"
PARALLEL_PORT="${PARALLEL_PORT:-8081}"
DURATION="${DURATION:-60}"
CONCURRENCY="${CONCURRENCY:-10}"
WARMUP_DURATION="${WARMUP_DURATION:-10}"

echo "=============================================="
echo "GC Throughput Comparison Test"
echo "=============================================="
echo "G1GC Server Port: $G1GC_PORT"
echo "Parallel GC Server Port: $PARALLEL_PORT"
echo "Test Duration: ${DURATION}s per test"
echo "Warmup Duration: ${WARMUP_DURATION}s per test"
echo "Concurrency: $CONCURRENCY"
echo "=============================================="
echo ""
echo "Prerequisites:"
echo "  1. Start G1GC server:       PORT=$G1GC_PORT ./scripts/run-g1gc.sh"
echo "  2. Start Parallel GC server: PORT=$PARALLEL_PORT ./scripts/run-parallel-gc.sh"
echo ""

# Check if servers are running
check_server() {
    local port=$1
    local name=$2
    if curl -s "http://localhost:${port}/health" > /dev/null 2>&1; then
        echo "✓ $name server is running on port $port"
        return 0
    else
        echo "✗ $name server is NOT running on port $port"
        return 1
    fi
}

echo "Checking servers..."
g1gc_running=false
parallel_running=false

if check_server $G1GC_PORT "G1GC"; then
    g1gc_running=true
fi

if check_server $PARALLEL_PORT "Parallel GC"; then
    parallel_running=true
fi

echo ""

if ! $g1gc_running && ! $parallel_running; then
    echo "No servers are running. Please start at least one server."
    exit 1
fi

run_test() {
    local port=$1
    local gc_type=$2
    local endpoint=$3
    local label=$4

    echo ""
    echo "----------------------------------------------"
    echo "Testing: $gc_type - $label"
    echo "----------------------------------------------"

    # Warmup
    echo "Warming up for ${WARMUP_DURATION}s..."
    DURATION=$WARMUP_DURATION PORT=$port ENDPOINT=$endpoint \
        TEST_NAME="${gc_type}-warmup" \
        "$SCRIPT_DIR/load-test.sh" > /dev/null 2>&1

    # Actual test
    echo "Running load test for ${DURATION}s..."
    DURATION=$DURATION PORT=$port ENDPOINT=$endpoint \
        CONCURRENCY=$CONCURRENCY \
        TEST_NAME="${gc_type}-${label}" \
        "$SCRIPT_DIR/load-test.sh"
}

# Run tests
if $g1gc_running; then
    echo ""
    echo "=============================================="
    echo "Testing G1GC"
    echo "=============================================="
    run_test $G1GC_PORT "g1gc" "/allocate" "light"
    run_test $G1GC_PORT "g1gc" "/heavy" "heavy"
fi

if $parallel_running; then
    echo ""
    echo "=============================================="
    echo "Testing Parallel GC"
    echo "=============================================="
    run_test $PARALLEL_PORT "parallel" "/allocate" "light"
    run_test $PARALLEL_PORT "parallel" "/heavy" "heavy"
fi

echo ""
echo "=============================================="
echo "Comparison Complete"
echo "=============================================="
echo ""
echo "Check the results/ directory for detailed JSON output."
echo "Check the gc-logs/ directory for GC log files."
echo ""
echo "To analyze GC logs, you can use tools like:"
echo "  - GCViewer: https://github.com/chewiebug/GCViewer"
echo "  - GCEasy: https://gceasy.io/"
echo "  - HPjmeter: https://www.hp.com/hpinfo/newsroom/press_kits/2009/HPTC2009/HPjmeter.pdf"
