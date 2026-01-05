#!/bin/bash

# =============================================================================
# GC Throughput Benchmark Script
# =============================================================================
#
# 테스트 방법론:
# 1. Warmup: JIT 컴파일 및 힙 안정화를 위한 워밍업
# 2. Ramp-up: 동시 접속 수를 단계적으로 증가
# 3. Saturation Detection: 응답시간 급증 또는 에러 발생 시 포화점 판단
# 4. Report: 최적 TPS 및 GC 통계 리포트
#
# 종료 기준:
# - 평균 응답시간이 임계값(기본 100ms) 초과
# - 에러율이 임계값(기본 5%) 초과
# - 최대 동시접속 수 도달
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="$PROJECT_DIR/results"

# =============================================================================
# 설정값 (환경변수로 오버라이드 가능)
# =============================================================================
HOST="${HOST:-localhost}"
PORT="${PORT:-8080}"
ENDPOINT="${ENDPOINT:-/allocate}"

# 워밍업 설정
WARMUP_DURATION="${WARMUP_DURATION:-30}"        # 워밍업 시간 (초)
WARMUP_CONCURRENCY="${WARMUP_CONCURRENCY:-5}"   # 워밍업 동시접속

# 램프업 설정
INITIAL_CONCURRENCY="${INITIAL_CONCURRENCY:-5}"   # 시작 동시접속 수
CONCURRENCY_STEP="${CONCURRENCY_STEP:-5}"         # 단계별 증가량
MAX_CONCURRENCY="${MAX_CONCURRENCY:-100}"         # 최대 동시접속 수
STEP_DURATION="${STEP_DURATION:-30}"              # 각 단계 테스트 시간 (초)

# 종료 기준
MAX_RESPONSE_TIME_MS="${MAX_RESPONSE_TIME_MS:-100}"  # 최대 허용 응답시간 (ms)
MAX_ERROR_RATE="${MAX_ERROR_RATE:-5}"                # 최대 허용 에러율 (%)

# =============================================================================
mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REPORT_FILE="$RESULTS_DIR/benchmark-${TIMESTAMP}.txt"
CSV_FILE="$RESULTS_DIR/benchmark-${TIMESTAMP}.csv"

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo -e "${BLUE}"
    echo "============================================================================="
    echo " GC Throughput Benchmark"
    echo "============================================================================="
    echo -e "${NC}"
}

print_config() {
    echo "[ 테스트 설정 ]"
    echo "  대상 서버: http://${HOST}:${PORT}${ENDPOINT}"
    echo ""
    echo "[ 워밍업 ]"
    echo "  시간: ${WARMUP_DURATION}초"
    echo "  동시접속: ${WARMUP_CONCURRENCY}"
    echo ""
    echo "[ 램프업 ]"
    echo "  시작 동시접속: ${INITIAL_CONCURRENCY}"
    echo "  증가 단위: +${CONCURRENCY_STEP}"
    echo "  최대 동시접속: ${MAX_CONCURRENCY}"
    echo "  단계별 테스트 시간: ${STEP_DURATION}초"
    echo ""
    echo "[ 종료 기준 ]"
    echo "  최대 응답시간: ${MAX_RESPONSE_TIME_MS}ms"
    echo "  최대 에러율: ${MAX_ERROR_RATE}%"
    echo "============================================================================="
    echo ""
}

check_server() {
    echo -n "서버 상태 확인 중... "
    if curl -s --connect-timeout 5 "http://${HOST}:${PORT}/health" > /dev/null 2>&1; then
        echo -e "${GREEN}OK${NC}"
        return 0
    else
        echo -e "${RED}FAILED${NC}"
        echo "서버가 http://${HOST}:${PORT} 에서 실행 중인지 확인하세요."
        exit 1
    fi
}

# 단일 요청 수행 및 응답시간 측정 (ms)
make_request() {
    local start=$(python3 -c "import time; print(int(time.time()*1000))")
    local http_code=$(curl -s -o /dev/null -w "%{http_code}" "http://${HOST}:${PORT}${ENDPOINT}" 2>/dev/null)
    local end=$(python3 -c "import time; print(int(time.time()*1000))")
    local elapsed=$((end - start))

    if [ "$http_code" = "200" ]; then
        echo "OK:$elapsed"
    else
        echo "ERROR:$elapsed"
    fi
}

# 부하 테스트 실행 (지정된 동시접속 수로)
run_load_step() {
    local concurrency=$1
    local duration=$2
    local temp_file=$(mktemp)

    # 워커 함수
    worker() {
        local end_time=$(($(date +%s) + duration))
        while [ $(date +%s) -lt $end_time ]; do
            make_request
        done
    }

    # 병렬 워커 실행
    for i in $(seq 1 $concurrency); do
        worker >> "$temp_file" &
    done

    # 모든 워커 완료 대기
    wait

    # 결과 분석
    local total=$(wc -l < "$temp_file")
    local errors=$(grep -c "^ERROR" "$temp_file" || echo 0)
    local successes=$((total - errors))

    # 응답시간 통계 계산
    local avg_time=0
    local p99_time=0

    if [ $successes -gt 0 ]; then
        avg_time=$(grep "^OK" "$temp_file" | cut -d: -f2 | awk '{sum+=$1} END {printf "%.0f", sum/NR}')
        p99_time=$(grep "^OK" "$temp_file" | cut -d: -f2 | sort -n | awk -v p=0.99 'BEGIN{c=0} {v[c++]=$1} END{idx=int(c*p); print v[idx]}')
    fi

    local error_rate=0
    if [ $total -gt 0 ]; then
        error_rate=$(awk "BEGIN {printf \"%.2f\", ($errors / $total) * 100}")
    fi

    local tps=$(awk "BEGIN {printf \"%.2f\", $successes / $duration}")

    rm -f "$temp_file"

    # 결과 반환: TPS,AvgTime,P99Time,ErrorRate,Total,Errors
    echo "${tps},${avg_time},${p99_time},${error_rate},${total},${errors}"
}

# GC 통계 가져오기
get_gc_stats() {
    curl -s "http://${HOST}:${PORT}/stats" 2>/dev/null
}

# 워밍업 실행
run_warmup() {
    echo -e "${YELLOW}[ 워밍업 시작 ]${NC} ${WARMUP_DURATION}초, 동시접속 ${WARMUP_CONCURRENCY}"

    # 초기 GC 통계
    local initial_stats=$(get_gc_stats)

    run_load_step $WARMUP_CONCURRENCY $WARMUP_DURATION > /dev/null

    echo -e "${GREEN}[ 워밍업 완료 ]${NC}"
    echo ""

    # 워밍업 후 GC 통계
    local final_stats=$(get_gc_stats)
    echo "워밍업 후 서버 상태:"
    echo "$final_stats" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(f\"  힙 사용량: {data['memory']['heap_used']}\")
    for gc in data['gc']:
        print(f\"  {gc['name']}: {gc['collection_count']}회, {gc['collection_time_ms']}ms\")
except: pass
" 2>/dev/null
    echo ""
}

# 메인 벤치마크 실행
run_benchmark() {
    echo -e "${YELLOW}[ 벤치마크 시작 ]${NC}"
    echo ""

    # CSV 헤더
    echo "Concurrency,TPS,AvgResponseTime(ms),P99ResponseTime(ms),ErrorRate(%),TotalRequests,Errors" > "$CSV_FILE"

    local current_concurrency=$INITIAL_CONCURRENCY
    local optimal_concurrency=0
    local optimal_tps=0
    local saturation_reached=false

    # 초기 GC 통계 저장
    local initial_gc_stats=$(get_gc_stats)

    printf "%-12s %-12s %-15s %-15s %-12s %-10s\n" "동시접속" "TPS" "평균응답(ms)" "P99응답(ms)" "에러율(%)" "상태"
    echo "-----------------------------------------------------------------------------"

    while [ $current_concurrency -le $MAX_CONCURRENCY ]; do
        # 단계 실행
        local result=$(run_load_step $current_concurrency $STEP_DURATION)

        local tps=$(echo $result | cut -d, -f1)
        local avg_time=$(echo $result | cut -d, -f2)
        local p99_time=$(echo $result | cut -d, -f3)
        local error_rate=$(echo $result | cut -d, -f4)
        local total=$(echo $result | cut -d, -f5)
        local errors=$(echo $result | cut -d, -f6)

        # CSV 기록
        echo "${current_concurrency},${tps},${avg_time},${p99_time},${error_rate},${total},${errors}" >> "$CSV_FILE"

        # 상태 판단
        local status="${GREEN}OK${NC}"
        local stop=false

        # 응답시간 초과 체크
        if [ $(echo "$avg_time > $MAX_RESPONSE_TIME_MS" | bc -l) -eq 1 ]; then
            status="${RED}응답시간 초과${NC}"
            stop=true
        fi

        # 에러율 초과 체크
        if [ $(echo "$error_rate > $MAX_ERROR_RATE" | bc -l) -eq 1 ]; then
            status="${RED}에러율 초과${NC}"
            stop=true
        fi

        printf "%-12s %-12s %-15s %-15s %-12s " "$current_concurrency" "$tps" "$avg_time" "$p99_time" "$error_rate"
        echo -e "$status"

        # 최적값 갱신
        if [ "$stop" = false ]; then
            if [ $(echo "$tps > $optimal_tps" | bc -l) -eq 1 ]; then
                optimal_tps=$tps
                optimal_concurrency=$current_concurrency
            fi
        fi

        # 종료 조건
        if [ "$stop" = true ]; then
            saturation_reached=true
            break
        fi

        current_concurrency=$((current_concurrency + CONCURRENCY_STEP))
    done

    echo ""

    # 최종 GC 통계
    local final_gc_stats=$(get_gc_stats)

    # 결과 리포트
    print_report "$optimal_concurrency" "$optimal_tps" "$saturation_reached" "$initial_gc_stats" "$final_gc_stats"
}

print_report() {
    local optimal_concurrency=$1
    local optimal_tps=$2
    local saturation_reached=$3
    local initial_gc=$4
    local final_gc=$5

    echo -e "${BLUE}"
    echo "============================================================================="
    echo " 벤치마크 결과"
    echo "============================================================================="
    echo -e "${NC}"

    echo "[ 최적 성능 ]"
    echo "  최적 동시접속 수: $optimal_concurrency"
    echo "  달성 TPS: $optimal_tps req/s"

    if [ "$saturation_reached" = true ]; then
        echo -e "  포화점 도달: ${YELLOW}예${NC}"
    else
        echo -e "  포화점 도달: ${GREEN}아니오 (최대 동시접속까지 테스트 완료)${NC}"
    fi

    echo ""
    echo "[ GC 통계 비교 ]"
    echo "$final_gc" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    total_gc_count = sum(gc['collection_count'] for gc in data['gc'])
    total_gc_time = sum(gc['collection_time_ms'] for gc in data['gc'])
    uptime_s = data['uptime_ms'] / 1000
    gc_overhead = (total_gc_time / 1000) / uptime_s * 100 if uptime_s > 0 else 0

    print(f\"  총 GC 횟수: {total_gc_count}회\")
    print(f\"  총 GC 시간: {total_gc_time}ms\")
    print(f\"  GC 오버헤드: {gc_overhead:.2f}%\")
    print()
    for gc in data['gc']:
        print(f\"  {gc['name']}:\")
        print(f\"    수집 횟수: {gc['collection_count']}회\")
        print(f\"    총 시간: {gc['collection_time_ms']}ms\")
except Exception as e:
    print(f'  통계 파싱 실패: {e}')
" 2>/dev/null

    echo ""
    echo "[ 결과 파일 ]"
    echo "  CSV: $CSV_FILE"
    echo "============================================================================="

    # 파일로도 저장
    {
        echo "GC Throughput Benchmark Report"
        echo "=============================="
        echo "Date: $(date)"
        echo "Server: http://${HOST}:${PORT}${ENDPOINT}"
        echo ""
        echo "Optimal Concurrency: $optimal_concurrency"
        echo "Optimal TPS: $optimal_tps"
        echo "Saturation Reached: $saturation_reached"
        echo ""
        echo "GC Stats:"
        echo "$final_gc"
    } > "$REPORT_FILE"
}

# =============================================================================
# 메인 실행
# =============================================================================
print_header
print_config
check_server
run_warmup
run_benchmark

echo ""
echo -e "${GREEN}벤치마크 완료!${NC}"
