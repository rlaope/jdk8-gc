#!/bin/bash

# Load Test Script for GC Throughput Comparison
# Uses curl for simple load generation

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="$PROJECT_DIR/results"

# Default settings
HOST="${HOST:-localhost}"
PORT="${PORT:-8080}"
DURATION="${DURATION:-60}"
CONCURRENCY="${CONCURRENCY:-10}"
ENDPOINT="${ENDPOINT:-/allocate}"
TEST_NAME="${TEST_NAME:-gc-test}"

mkdir -p "$RESULTS_DIR"

echo "=============================================="
echo "GC Throughput Load Test"
echo "=============================================="
echo "Target: http://${HOST}:${PORT}${ENDPOINT}"
echo "Duration: ${DURATION}s"
echo "Concurrency: ${CONCURRENCY}"
echo "Test Name: ${TEST_NAME}"
echo "=============================================="

# Function to make requests
make_requests() {
    local worker_id=$1
    local count=0
    local errors=0
    local start_time=$(date +%s)
    local end_time=$((start_time + DURATION))

    while [ $(date +%s) -lt $end_time ]; do
        response=$(curl -s -w "\n%{http_code}" "http://${HOST}:${PORT}${ENDPOINT}" 2>/dev/null)
        http_code=$(echo "$response" | tail -n 1)

        if [ "$http_code" = "200" ]; then
            ((count++))
        else
            ((errors++))
        fi
    done

    echo "$count,$errors"
}

# Export function for parallel execution
export -f make_requests
export HOST PORT ENDPOINT DURATION

echo ""
echo "Starting load test..."
echo ""

# Record start time
START_TIME=$(date +%s)

# Get initial stats
INITIAL_STATS=$(curl -s "http://${HOST}:${PORT}/stats" 2>/dev/null)

# Run concurrent workers
RESULTS=""
pids=()
for i in $(seq 1 $CONCURRENCY); do
    make_requests $i &
    pids+=($!)
done

# Wait for all workers and collect results
total_requests=0
total_errors=0
for pid in "${pids[@]}"; do
    wait $pid
done

# Get final stats
sleep 1
FINAL_STATS=$(curl -s "http://${HOST}:${PORT}/stats" 2>/dev/null)

# Record end time
END_TIME=$(date +%s)
ACTUAL_DURATION=$((END_TIME - START_TIME))

# Parse stats
echo ""
echo "=============================================="
echo "Test Results"
echo "=============================================="
echo ""
echo "Duration: ${ACTUAL_DURATION}s"
echo ""
echo "Server Statistics:"
echo "$FINAL_STATS" | python3 -c "
import json
import sys

try:
    data = json.load(sys.stdin)
    print(f\"  Total Requests: {data['total_requests']}\")
    print(f\"  Throughput: {data['throughput_rps']} req/s\")
    print(f\"  Avg Latency: {data['avg_latency_us']} µs\")
    print()
    print('  Memory:')
    print(f\"    Heap Used: {data['memory']['heap_used']}\")
    print(f\"    Heap Total: {data['memory']['heap_total']}\")
    print(f\"    Heap Max: {data['memory']['heap_max']}\")
    print()
    print('  GC Statistics:')
    total_gc_time = 0
    total_gc_count = 0
    for gc in data['gc']:
        print(f\"    {gc['name']}:\")
        print(f\"      Collections: {gc['collection_count']}\")
        print(f\"      Time: {gc['collection_time_ms']} ms\")
        total_gc_time += gc['collection_time_ms']
        total_gc_count += gc['collection_count']
    print()
    print(f\"  Total GC Collections: {total_gc_count}\")
    print(f\"  Total GC Time: {total_gc_time} ms\")

    uptime_s = data['uptime_ms'] / 1000
    gc_overhead = (total_gc_time / 1000) / uptime_s * 100 if uptime_s > 0 else 0
    print(f\"  GC Overhead: {gc_overhead:.2f}%\")
except Exception as e:
    print(f'Error parsing stats: {e}')
    print('Raw response:')
    print(sys.stdin.read())
" 2>/dev/null || echo "$FINAL_STATS"

# Save results to file
RESULT_FILE="$RESULTS_DIR/${TEST_NAME}-$(date +%Y%m%d-%H%M%S).json"
echo "$FINAL_STATS" > "$RESULT_FILE"
echo ""
echo "Results saved to: $RESULT_FILE"
echo "=============================================="
