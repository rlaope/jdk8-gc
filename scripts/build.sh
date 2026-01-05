#!/bin/bash

# Build script for GC Throughput Test Server

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SRC_DIR="$PROJECT_DIR/src/main/java"
BUILD_DIR="$PROJECT_DIR/build"

echo "=============================================="
echo "Building GC Throughput Test Server"
echo "=============================================="

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Compile with Java 8 compatibility
echo "Compiling Java sources (Java 8 compatible)..."
find "$SRC_DIR" -name "*.java" -print0 | xargs -0 javac -source 1.8 -target 1.8 -d "$BUILD_DIR"

if [ $? -eq 0 ]; then
    echo "Build successful!"
    echo "Output directory: $BUILD_DIR"
    echo ""
    echo "To run with G1GC:       ./scripts/run-g1gc.sh"
    echo "To run with Parallel GC: ./scripts/run-parallel-gc.sh"
else
    echo "Build failed!"
    exit 1
fi
