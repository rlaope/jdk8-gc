#!/bin/bash

# G1GC Throughput Test Runner
# This script runs the GC test server with G1 Garbage Collector

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
LOG_DIR="$PROJECT_DIR/gc-logs"

# Default settings
HEAP_SIZE="${HEAP_SIZE:-2g}"
PORT="${PORT:-8080}"
GC_LOG_FILE="$LOG_DIR/g1gc-$(date +%Y%m%d-%H%M%S).log"

# Create directories
mkdir -p "$LOG_DIR"

echo "=============================================="
echo "Starting GC Throughput Test with G1GC"
echo "=============================================="
echo "Heap Size: $HEAP_SIZE"
echo "Port: $PORT"
echo "GC Log: $GC_LOG_FILE"
echo "=============================================="

# G1GC specific JVM options
JVM_OPTS=(
    # Memory settings
    "-Xms${HEAP_SIZE}"
    "-Xmx${HEAP_SIZE}"

    # G1GC selection
    "-XX:+UseG1GC"

    # G1GC tuning options
    "-XX:MaxGCPauseMillis=200"
    "-XX:G1HeapRegionSize=16m"
    "-XX:InitiatingHeapOccupancyPercent=45"
    "-XX:G1ReservePercent=10"
    "-XX:ParallelGCThreads=$(nproc)"
    "-XX:ConcGCThreads=$(($(nproc) / 4 + 1))"

    # GC logging (Java 9+)
    "-Xlog:gc*:file=${GC_LOG_FILE}:time,uptime,level,tags:filecount=5,filesize=50m"

    # Additional diagnostics
    "-XX:+PrintCommandLineFlags"
)

# Check Java version for GC logging compatibility
JAVA_VERSION=$(java -version 2>&1 | head -n 1 | cut -d'"' -f2 | cut -d'.' -f1)
if [[ "$JAVA_VERSION" -lt 9 ]]; then
    echo "Warning: Java 8 detected. Using legacy GC logging options."
    JVM_OPTS=(
        "-Xms${HEAP_SIZE}"
        "-Xmx${HEAP_SIZE}"
        "-XX:+UseG1GC"
        "-XX:MaxGCPauseMillis=200"
        "-XX:G1HeapRegionSize=16m"
        "-XX:+PrintGCDetails"
        "-XX:+PrintGCDateStamps"
        "-XX:+PrintGCTimeStamps"
        "-Xloggc:${GC_LOG_FILE}"
        "-XX:+PrintCommandLineFlags"
    )
fi

# Run the server
cd "$PROJECT_DIR"
java "${JVM_OPTS[@]}" -cp "$BUILD_DIR" com.gctest.GCThroughputServer "$PORT"
