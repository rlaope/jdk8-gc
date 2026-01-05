#!/bin/bash

# =============================================================================
# G1GC vs Parallel GC 비교 벤치마크
# =============================================================================
#
# 사용법:
#   1. 터미널 1: PORT=8080 ./scripts/run-g1gc.sh
#   2. 터미널 2: PORT=8081 ./scripts/run-parallel-gc.sh
#   3. 터미널 3: ./scripts/benchmark-compare.sh
#
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="$PROJECT_DIR/results"

G1GC_PORT="${G1GC_PORT:-8080}"
PARALLEL_PORT="${PARALLEL_PORT:-8081}"

# 벤치마크 설정 (필요시 조정)
export WARMUP_DURATION="${WARMUP_DURATION:-30}"
export STEP_DURATION="${STEP_DURATION:-30}"
export INITIAL_CONCURRENCY="${INITIAL_CONCURRENCY:-5}"
export CONCURRENCY_STEP="${CONCURRENCY_STEP:-5}"
export MAX_CONCURRENCY="${MAX_CONCURRENCY:-50}"
export MAX_RESPONSE_TIME_MS="${MAX_RESPONSE_TIME_MS:-100}"

mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

echo "============================================================================="
echo " G1GC vs Parallel GC 비교 벤치마크"
echo "============================================================================="
echo ""
echo "설정:"
echo "  G1GC 서버: localhost:${G1GC_PORT}"
echo "  Parallel GC 서버: localhost:${PARALLEL_PORT}"
echo "  워밍업: ${WARMUP_DURATION}초"
echo "  단계별 테스트: ${STEP_DURATION}초"
echo "  동시접속 범위: ${INITIAL_CONCURRENCY} ~ ${MAX_CONCURRENCY} (step: ${CONCURRENCY_STEP})"
echo ""

# 서버 체크
check_server() {
    local port=$1
    local name=$2
    if curl -s --connect-timeout 3 "http://localhost:${port}/health" > /dev/null 2>&1; then
        echo "  ✓ ${name} (port ${port}): 실행 중"
        return 0
    else
        echo "  ✗ ${name} (port ${port}): 미실행"
        return 1
    fi
}

echo "서버 상태 확인:"
g1gc_ok=false
parallel_ok=false

if check_server $G1GC_PORT "G1GC"; then
    g1gc_ok=true
fi

if check_server $PARALLEL_PORT "Parallel GC"; then
    parallel_ok=true
fi

echo ""

if ! $g1gc_ok && ! $parallel_ok; then
    echo "실행 중인 서버가 없습니다."
    echo ""
    echo "서버 시작 방법:"
    echo "  터미널 1: PORT=${G1GC_PORT} ./scripts/run-g1gc.sh"
    echo "  터미널 2: PORT=${PARALLEL_PORT} ./scripts/run-parallel-gc.sh"
    exit 1
fi

# 엔드포인트별 테스트
run_endpoint_test() {
    local endpoint=$1
    local label=$2

    echo ""
    echo "============================================================================="
    echo " 테스트: ${label} (${endpoint})"
    echo "============================================================================="

    if $g1gc_ok; then
        echo ""
        echo ">>> G1GC 벤치마크 <<<"
        PORT=$G1GC_PORT ENDPOINT=$endpoint "$SCRIPT_DIR/benchmark.sh"
        mv "$RESULTS_DIR/benchmark-"*.csv "$RESULTS_DIR/g1gc-${label}-${TIMESTAMP}.csv" 2>/dev/null
    fi

    if $parallel_ok; then
        echo ""
        echo ">>> Parallel GC 벤치마크 <<<"
        PORT=$PARALLEL_PORT ENDPOINT=$endpoint "$SCRIPT_DIR/benchmark.sh"
        mv "$RESULTS_DIR/benchmark-"*.csv "$RESULTS_DIR/parallel-${label}-${TIMESTAMP}.csv" 2>/dev/null
    fi
}

# Light 워크로드 테스트
run_endpoint_test "/allocate" "light"

# Heavy 워크로드 테스트
run_endpoint_test "/heavy" "heavy"

# 최종 요약
echo ""
echo "============================================================================="
echo " 비교 결과 요약"
echo "============================================================================="
echo ""
echo "결과 파일 위치: $RESULTS_DIR"
echo ""
ls -la "$RESULTS_DIR"/*${TIMESTAMP}* 2>/dev/null

echo ""
echo "CSV 파일을 엑셀이나 구글 시트에서 열어 그래프로 비교하세요."
echo ""
echo "주요 비교 지표:"
echo "  1. 최대 TPS: 처리량 비교"
echo "  2. 응답시간: 지연시간 비교 (P99 권장)"
echo "  3. 포화점: 어느 동시접속에서 성능 저하가 시작되는지"
echo "  4. GC 오버헤드: GC가 전체 시간의 몇 %를 차지하는지"
echo ""
