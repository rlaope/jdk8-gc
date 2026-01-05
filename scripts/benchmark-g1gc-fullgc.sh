#!/bin/bash

# =============================================================================
# G1GC Full GC 회피 벤치마크
# =============================================================================
#
# 목적: JDK 8 G1GC에서 Full GC가 발생하지 않는 최대 트래픽 수준 찾기
#
# JDK 8 G1GC Full GC 특징:
# - Single-threaded로 동작 (매우 느림)
# - P99 latency 급등의 주범
# - 힙이 가득 차거나 Allocation Failure 시 발생
#
# 테스트 종료 기준:
# 1. Old Gen GC (Full GC 포함) 발생 시 → 즉시 중단
# 2. 힙 사용률 임계값 초과 시 → 위험 경고
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="$PROJECT_DIR/results"

# =============================================================================
# 설정값
# =============================================================================
HOST="${HOST:-localhost}"
PORT="${PORT:-8080}"
ENDPOINT="${ENDPOINT:-/allocate}"

# 워밍업 설정
WARMUP_DURATION="${WARMUP_DURATION:-30}"
WARMUP_CONCURRENCY="${WARMUP_CONCURRENCY:-5}"

# 부하 증가 설정
INITIAL_CONCURRENCY="${INITIAL_CONCURRENCY:-5}"
CONCURRENCY_STEP="${CONCURRENCY_STEP:-5}"
MAX_CONCURRENCY="${MAX_CONCURRENCY:-100}"
STEP_DURATION="${STEP_DURATION:-30}"

# Full GC 회피 전용 설정
HEAP_USAGE_WARN_PERCENT="${HEAP_USAGE_WARN_PERCENT:-70}"   # 힙 사용률 경고 (%)
HEAP_USAGE_STOP_PERCENT="${HEAP_USAGE_STOP_PERCENT:-85}"   # 힙 사용률 중단 (%)

# =============================================================================
mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
CSV_FILE="$RESULTS_DIR/g1gc-fullgc-test-${TIMESTAMP}.csv"
REPORT_FILE="$RESULTS_DIR/g1gc-fullgc-test-${TIMESTAMP}.txt"

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_header() {
    echo -e "${CYAN}"
    echo "============================================================================="
    echo " JDK 8 G1GC Full GC 회피 벤치마크"
    echo "============================================================================="
    echo -e "${NC}"
    echo ""
    echo -e "${YELLOW}[목적]${NC} Full GC 없이 처리 가능한 최대 트래픽 찾기"
    echo ""
    echo "JDK 8 G1GC Full GC 특징:"
    echo "  - Single-threaded (매우 느림)"
    echo "  - P99 latency 급등 원인"
    echo "  - 발생 시 수백ms ~ 수초 STW"
    echo ""
}

print_config() {
    echo "[ 테스트 설정 ]"
    echo "  대상: http://${HOST}:${PORT}${ENDPOINT}"
    echo "  워밍업: ${WARMUP_DURATION}초"
    echo "  단계별 테스트: ${STEP_DURATION}초"
    echo "  동시접속: ${INITIAL_CONCURRENCY} → ${MAX_CONCURRENCY} (step: ${CONCURRENCY_STEP})"
    echo ""
    echo "[ Full GC 회피 기준 ]"
    echo "  힙 사용률 경고: ${HEAP_USAGE_WARN_PERCENT}%"
    echo "  힙 사용률 중단: ${HEAP_USAGE_STOP_PERCENT}%"
    echo "  Old Gen GC 발생: 즉시 중단"
    echo "============================================================================="
    echo ""
}

check_server() {
    echo -n "서버 상태 확인... "
    local stats=$(curl -s --connect-timeout 5 "http://${HOST}:${PORT}/stats" 2>/dev/null)
    if [ -z "$stats" ]; then
        echo -e "${RED}FAILED${NC}"
        echo "서버가 http://${HOST}:${PORT} 에서 실행 중인지 확인하세요."
        exit 1
    fi
    echo -e "${GREEN}OK${NC}"

    # GC 타입 확인
    echo ""
    echo "[ GC 정보 ]"
    echo "$stats" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for gc in data['gc']:
        print(f\"  {gc['name']}\")
except: pass
" 2>/dev/null
    echo ""
}

# 서버 통계 가져오기
get_stats() {
    curl -s "http://${HOST}:${PORT}/stats" 2>/dev/null
}

# Old Gen GC 카운트 가져오기
get_old_gc_count() {
    local stats=$1
    echo "$stats" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data['gc_summary']['old_gc_count'])
except:
    print(0)
" 2>/dev/null
}

# 힙 사용률 가져오기
get_heap_usage_percent() {
    local stats=$1
    echo "$stats" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    used = data['memory']['heap_used_bytes']
    max_heap = data['memory']['heap_max_bytes']
    print(int(used * 100 / max_heap))
except:
    print(0)
" 2>/dev/null
}

# 단일 요청
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

# 부하 테스트 (Full GC 모니터링 포함)
run_load_step_with_gc_check() {
    local concurrency=$1
    local duration=$2
    local initial_old_gc=$3

    local temp_file=$(mktemp)
    local gc_check_file=$(mktemp)

    # 워커 함수
    worker() {
        local end_time=$(($(date +%s) + duration))
        while [ $(date +%s) -lt $end_time ]; do
            make_request
        done
    }

    # GC 모니터링 함수 (백그라운드)
    gc_monitor() {
        local end_time=$(($(date +%s) + duration))
        while [ $(date +%s) -lt $end_time ]; do
            local stats=$(get_stats)
            local current_old_gc=$(get_old_gc_count "$stats")
            local heap_percent=$(get_heap_usage_percent "$stats")

            # Full GC 발생 체크
            if [ "$current_old_gc" -gt "$initial_old_gc" ]; then
                echo "FULLGC:$current_old_gc" > "$gc_check_file"
                break
            fi

            # 힙 사용률 체크
            if [ "$heap_percent" -ge "$HEAP_USAGE_STOP_PERCENT" ]; then
                echo "HEAP_HIGH:$heap_percent" >> "$gc_check_file"
            fi

            sleep 2
        done
    }

    # GC 모니터 시작
    gc_monitor &
    local monitor_pid=$!

    # 병렬 워커 실행
    for i in $(seq 1 $concurrency); do
        worker >> "$temp_file" &
    done

    # 워커 완료 대기
    wait

    # 모니터 종료
    kill $monitor_pid 2>/dev/null
    wait $monitor_pid 2>/dev/null

    # GC 체크 결과
    local gc_status="OK"
    if [ -f "$gc_check_file" ]; then
        if grep -q "FULLGC" "$gc_check_file"; then
            gc_status="FULLGC"
        elif grep -q "HEAP_HIGH" "$gc_check_file"; then
            gc_status="HEAP_WARN"
        fi
    fi

    # 결과 분석
    local total
    total=$(wc -l < "$temp_file" 2>/dev/null | tr -d '[:space:]')
    total=${total:-0}

    local errors
    errors=$(grep -c "^ERROR" "$temp_file" 2>/dev/null || true)
    errors=$(echo "$errors" | tr -d '[:space:]')
    errors=${errors:-0}

    local successes=0
    if [ "$total" -gt 0 ] 2>/dev/null; then
        successes=$((total - errors))
    fi

    local avg_time=0
    local p99_time=0
    local max_time=0

    if [ "$successes" -gt 0 ] 2>/dev/null; then
        avg_time=$(grep "^OK" "$temp_file" | cut -d: -f2 | awk '{sum+=$1; c++} END {if(c>0) printf "%.0f", sum/c; else print 0}')
        p99_time=$(grep "^OK" "$temp_file" | cut -d: -f2 | sort -n | awk -v p=0.99 'BEGIN{c=0} {v[c++]=$1} END{if(c>0){idx=int(c*p); print v[idx]} else print 0}')
        max_time=$(grep "^OK" "$temp_file" | cut -d: -f2 | sort -n | tail -1)
    fi
    avg_time=${avg_time:-0}
    p99_time=${p99_time:-0}
    max_time=${max_time:-0}

    local tps
    tps=$(awk -v s="$successes" -v d="$duration" 'BEGIN {printf "%.2f", s / d}')

    rm -f "$temp_file" "$gc_check_file"

    # 결과: TPS,AvgTime,P99Time,MaxTime,GCStatus
    echo "${tps},${avg_time},${p99_time},${max_time},${gc_status}"
}

# 워밍업 (리턴값: Old GC count)
run_warmup() {
    echo -e "${YELLOW}[ 워밍업 ]${NC} ${WARMUP_DURATION}초" >&2

    local initial_stats
    initial_stats=$(get_stats)
    local initial_old_gc
    initial_old_gc=$(get_old_gc_count "$initial_stats")
    initial_old_gc=${initial_old_gc:-0}

    # 워밍업 부하
    for _ in $(seq 1 $WARMUP_CONCURRENCY); do
        (
            end_time=$(($(date +%s) + WARMUP_DURATION))
            while [ "$(date +%s)" -lt "$end_time" ]; do
                curl -s "http://${HOST}:${PORT}${ENDPOINT}" > /dev/null 2>&1
            done
        ) &
    done
    wait

    local final_stats
    final_stats=$(get_stats)
    local final_old_gc
    final_old_gc=$(get_old_gc_count "$final_stats")
    final_old_gc=${final_old_gc:-0}
    local heap_percent
    heap_percent=$(get_heap_usage_percent "$final_stats")
    heap_percent=${heap_percent:-0}

    echo -e "${GREEN}[ 워밍업 완료 ]${NC}" >&2
    echo "  힙 사용률: ${heap_percent}%" >&2
    echo "  Old Gen GC: ${final_old_gc}회" >&2

    if [ "$final_old_gc" -gt "$initial_old_gc" ]; then
        echo -e "  ${RED}⚠ 워밍업 중 Old Gen GC 발생!${NC}" >&2
    fi
    echo "" >&2

    echo "$final_old_gc"  # stdout으로 리턴값만 출력
}

# 메인 벤치마크
run_benchmark() {
    local initial_old_gc=$1

    echo -e "${YELLOW}[ 벤치마크 시작 ]${NC}"
    echo ""

    # CSV 헤더
    echo "Concurrency,TPS,AvgResponseTime(ms),P99ResponseTime(ms),MaxResponseTime(ms),HeapUsage(%),OldGCCount,Status" > "$CSV_FILE"

    local current_concurrency=$INITIAL_CONCURRENCY
    local safe_concurrency=0
    local safe_tps=0
    local stop_reason=""

    printf "%-10s %-10s %-12s %-12s %-12s %-10s %-10s %-15s\n" \
        "동시접속" "TPS" "평균(ms)" "P99(ms)" "Max(ms)" "힙(%)" "OldGC" "상태"
    echo "---------------------------------------------------------------------------------------------"

    while [ "$current_concurrency" -le "$MAX_CONCURRENCY" ]; do
        # 현재 상태 확인
        local before_stats
        before_stats=$(get_stats)
        local before_old_gc
        before_old_gc=$(get_old_gc_count "$before_stats")
        before_old_gc=${before_old_gc:-0}

        # 부하 테스트
        local result
        result=$(run_load_step_with_gc_check "$current_concurrency" "$STEP_DURATION" "$before_old_gc")

        local tps avg_time p99_time max_time gc_status
        tps=$(echo "$result" | cut -d, -f1)
        avg_time=$(echo "$result" | cut -d, -f2)
        p99_time=$(echo "$result" | cut -d, -f3)
        max_time=$(echo "$result" | cut -d, -f4)
        gc_status=$(echo "$result" | cut -d, -f5)

        # 최종 상태 확인
        local after_stats
        after_stats=$(get_stats)
        local after_old_gc
        after_old_gc=$(get_old_gc_count "$after_stats")
        after_old_gc=${after_old_gc:-0}
        local heap_percent
        heap_percent=$(get_heap_usage_percent "$after_stats")
        heap_percent=${heap_percent:-0}

        # 상태 판단
        local status_color="${GREEN}"
        local status_text="OK"
        local should_stop=false

        # Full GC 발생 체크 (가장 중요!)
        if [ "$after_old_gc" -gt "${initial_old_gc:-0}" ]; then
            status_color="${RED}"
            status_text="FULL GC 발생!"
            stop_reason="Full GC 발생 (Old Gen GC: ${after_old_gc}회)"
            should_stop=true
        # 힙 사용률 위험
        elif [ "$heap_percent" -ge "$HEAP_USAGE_STOP_PERCENT" ]; then
            status_color="${RED}"
            status_text="힙 위험 (${heap_percent}%)"
            stop_reason="힙 사용률 ${heap_percent}% (임계값: ${HEAP_USAGE_STOP_PERCENT}%)"
            should_stop=true
        # 힙 사용률 경고
        elif [ "$heap_percent" -ge "$HEAP_USAGE_WARN_PERCENT" ]; then
            status_color="${YELLOW}"
            status_text="힙 경고 (${heap_percent}%)"
        fi

        # CSV 기록
        echo "${current_concurrency},${tps},${avg_time},${p99_time},${max_time},${heap_percent},${after_old_gc},${status_text}" >> "$CSV_FILE"

        # 출력
        printf "%-10s %-10s %-12s %-12s %-12s %-10s %-10s " \
            "$current_concurrency" "$tps" "$avg_time" "$p99_time" "$max_time" "$heap_percent" "$after_old_gc"
        echo -e "${status_color}${status_text}${NC}"

        # 안전 범위 갱신
        if [ "$should_stop" = false ]; then
            safe_concurrency=$current_concurrency
            safe_tps=$tps
        fi

        # 종료 조건
        if [ "$should_stop" = true ]; then
            break
        fi

        current_concurrency=$((current_concurrency + CONCURRENCY_STEP))
    done

    echo ""

    # 결과 리포트
    print_report "$safe_concurrency" "$safe_tps" "$stop_reason" "$after_stats"
}

print_report() {
    local safe_concurrency=$1
    local safe_tps=$2
    local stop_reason=$3
    local final_stats=$4

    echo -e "${CYAN}"
    echo "============================================================================="
    echo " 테스트 결과"
    echo "============================================================================="
    echo -e "${NC}"

    if [ -n "$stop_reason" ]; then
        echo -e "${RED}[중단 사유]${NC} $stop_reason"
        echo ""
    fi

    echo -e "${GREEN}[Full GC 없이 안전한 트래픽 수준]${NC}"
    echo ""
    echo "  ┌─────────────────────────────────────────┐"
    echo "  │  최대 안전 동시접속: ${safe_concurrency}개"
    echo "  │  달성 TPS: ${safe_tps} req/s"
    echo "  └─────────────────────────────────────────┘"
    echo ""

    echo "[ 최종 GC 상태 ]"
    echo "$final_stats" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    gs = data['gc_summary']
    print(f\"  Young GC: {gs['young_gc_count']}회, {gs['young_gc_time_ms']}ms\")
    print(f\"  Old GC: {gs['old_gc_count']}회, {gs['old_gc_time_ms']}ms\")
    if gs['old_gc_count'] > 0:
        print(f\"  평균 Old GC 시간: {gs['avg_old_gc_time_ms']}ms\")
    print()
    print(f\"  힙 사용량: {data['memory']['heap_used']}\")
    print(f\"  힙 최대: {data['memory']['heap_max']}\")
except Exception as e:
    print(f'  파싱 실패: {e}')
" 2>/dev/null

    echo ""
    echo "[ 권장사항 ]"
    if [ "$safe_concurrency" -gt 0 ]; then
        echo "  - 운영 환경에서는 ${safe_concurrency}개 이하의 동시접속 유지"
        echo "  - 안전 마진을 위해 최대 $((safe_concurrency * 80 / 100))개 권장"
        echo "  - 힙 크기 증가 시 더 높은 트래픽 처리 가능"
    else
        echo "  - 현재 설정으로는 안전한 트래픽 수준 없음"
        echo "  - 힙 크기를 늘리거나 부하를 줄이세요"
    fi

    echo ""
    echo "[ 결과 파일 ]"
    echo "  CSV: $CSV_FILE"
    echo "============================================================================="

    # 리포트 파일 저장
    {
        echo "JDK 8 G1GC Full GC 회피 벤치마크 결과"
        echo "======================================="
        echo "Date: $(date)"
        echo "Server: http://${HOST}:${PORT}${ENDPOINT}"
        echo ""
        echo "Safe Concurrency: $safe_concurrency"
        echo "Safe TPS: $safe_tps"
        echo "Stop Reason: $stop_reason"
        echo ""
        echo "Final Stats:"
        echo "$final_stats"
    } > "$REPORT_FILE"
}

# =============================================================================
# 메인 실행
# =============================================================================
print_header
print_config
check_server

initial_old_gc=$(run_warmup)
run_benchmark "$initial_old_gc"

echo ""
echo -e "${GREEN}테스트 완료!${NC}"
