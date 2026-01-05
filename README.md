# GC Throughput Test

JDK 8 G1GC Full GC 회피를 위한 트래픽 임계값 테스트 프레임워크

## 핵심 목표

**JDK 8 G1GC에서 Full GC 없이 처리 가능한 최대 트래픽 수준 찾기**

### JDK 8 G1GC Full GC 문제점

- **Single-threaded**: JDK 8의 G1 Full GC는 단일 스레드로 동작
- **P99 급등**: Full GC 발생 시 수백ms ~ 수초의 STW(Stop-The-World)
- **예측 불가**: 갑자기 발생하여 서비스 품질 저하

## 요구사항

- **Java 8** (OpenJDK 8 권장)
- Bash shell (Linux/macOS/WSL)
- curl
- python3

---

## 실행 방법 (Step by Step)

### Step 1: 빌드

```bash
cd gctrack
./scripts/build.sh
```

### Step 2: G1GC 서버 시작 (터미널 1)

```bash
# 기본 설정 (힙 2GB)
./scripts/run-g1gc.sh

# 또는 힙 크기 지정
HEAP_SIZE=4g ./scripts/run-g1gc.sh
```

서버가 시작되면 다음과 같이 출력됩니다:
```
============================================================
GC Throughput Test Server
============================================================
JVM Information:
  Java Version: 1.8.0_xxx
Garbage Collectors:
  G1 Young Generation
  G1 Old Generation      ← 이것이 Full GC 포함
============================================================
Server started on port 8080
```

### Step 3: Full GC 회피 벤치마크 실행 (터미널 2)

```bash
# G1GC Full GC 회피 테스트 (권장)
./scripts/benchmark-g1gc-fullgc.sh

# 또는 설정 변경
HEAP_SIZE=4g \
STEP_DURATION=60 \
MAX_CONCURRENCY=200 \
./scripts/benchmark-g1gc-fullgc.sh
```

### Step 4: 결과 확인

```
=============================================================================
 테스트 결과
=============================================================================
[중단 사유] Full GC 발생 (Old Gen GC: 1회)

[Full GC 없이 안전한 트래픽 수준]

  ┌─────────────────────────────────────────┐
  │  최대 안전 동시접속: 25개
  │  달성 TPS: 3200.50 req/s
  └─────────────────────────────────────────┘
```

---

## 벤치마크 스크립트 종류

| 스크립트 | 용도 |
|----------|------|
| `benchmark-g1gc-fullgc.sh` | **G1GC Full GC 회피 테스트** (권장) |
| `benchmark.sh` | 일반 처리량 벤치마크 |
| `benchmark-compare.sh` | G1GC vs Parallel GC 비교 |

---

## G1GC Full GC 회피 테스트 상세

### Full GC 발생 조건 (JDK 8 G1GC)

```
1. Allocation Failure
   └─ Young Gen에서 객체 할당 실패
   └─ Survivor 공간 부족으로 Old Gen으로 조기 승격

2. Concurrent Mode Failure
   └─ Concurrent Marking 중 Old Gen 가득 참
   └─ Mixed GC가 충분히 빠르게 공간 확보 못함

3. To-space Exhausted
   └─ GC 중 객체 복사할 공간 부족
   └─ Humongous 객체 할당 실패
```

### 테스트 종료 기준

| 기준 | 기본값 | 설명 |
|------|--------|------|
| **Old Gen GC 발생** | 0회 | G1 Old Generation 수집 발생 시 즉시 중단 |
| 힙 사용률 위험 | 85% | Full GC 직전 상태로 판단 |
| 힙 사용률 경고 | 70% | 경고 표시 (계속 진행) |

### 측정 지표

| 지표 | 설명 | Full GC 관점 |
|------|------|--------------|
| TPS | 초당 처리량 | Full GC 시 급감 |
| P99 | 99%ile 응답시간 | Full GC 시 급등 (수백ms~수초) |
| Max | 최대 응답시간 | Full GC STW 시간 반영 |
| 힙 사용률 | 현재 힙 사용량 | 높을수록 Full GC 위험 |
| Old GC Count | Old Gen GC 횟수 | 0이어야 안전 |

### 설정 파라미터

```bash
# Full GC 회피 테스트 설정
HEAP_USAGE_WARN_PERCENT=70    # 힙 사용률 경고 기준 (%)
HEAP_USAGE_STOP_PERCENT=85    # 힙 사용률 중단 기준 (%)

# 부하 설정
INITIAL_CONCURRENCY=5         # 시작 동시접속
CONCURRENCY_STEP=5            # 증가 단위
MAX_CONCURRENCY=100           # 최대 동시접속
STEP_DURATION=30              # 단계별 측정 시간 (초)

# 워밍업
WARMUP_DURATION=30            # 워밍업 시간 (초)
```

### 결과 해석 예시

```
동시접속   TPS        평균(ms)   P99(ms)    Max(ms)    힙(%)   OldGC   상태
---------------------------------------------------------------------------------------------
5          1250.00    4          8          15         35      0       OK
10         2340.00    6          12         25         42      0       OK
15         3100.00    9          18         40         55      0       OK
20         3450.00    15         35         80         68      0       OK
25         3200.00    45         98         150        75      0       힙 경고 (75%)
30         2100.00    120        850        2500       88      1       FULL GC 발생!
```

**해석:**
- 동시접속 20개까지: 안전 (Full GC 없음)
- 동시접속 25개: 경고 수준 (힙 75%)
- 동시접속 30개: Full GC 발생 → P99가 850ms, Max가 2.5초로 급등

**권장:** 동시접속 20개 이하 유지 (안전 마진 적용 시 16개)

---

## 테스트 진행 방식 상세 가이드

### 1. 테스트 목적

이 벤치마크는 다음을 측정합니다:
- **Full GC 없는 최대 트래픽**: JDK 8 G1GC에서 안전하게 처리 가능한 부하
- **최대 처리량(TPS)**: 서버가 안정적으로 처리할 수 있는 초당 요청 수
- **포화점(Saturation Point)**: 성능 저하가 시작되는 부하 수준

### 2. 테스트 단계별 설명

#### 2.1 워밍업 단계 (Warmup Phase)

```
목적: JVM 최적화 완료 대기
시간: 30초 (기본값)
동시접속: 5개 (기본값)
```

**왜 필요한가?**
- JIT(Just-In-Time) 컴파일러가 핫스팟 코드를 최적화하는 시간 필요
- 힙 메모리가 안정적인 상태에 도달해야 함
- 초기 클래스 로딩 오버헤드 제거

**권장 설정:**
- 워밍업 시간: 최소 30초, 대규모 애플리케이션은 60초 이상
- 워밍업 부하: 실제 테스트의 50% 수준

#### 2.2 부하 증가 단계 (Ramp-up Phase)

```
시작: 동시접속 5개
증가: 매 단계 +5개
단계별 측정 시간: 30초
```

**진행 방식:**
```
단계 1: 동시접속 5개  → 30초 측정 → TPS, 응답시간, 에러율 기록
단계 2: 동시접속 10개 → 30초 측정 → TPS, 응답시간, 에러율 기록
단계 3: 동시접속 15개 → 30초 측정 → TPS, 응답시간, 에러율 기록
...
계속 증가 → 종료 기준 도달 시 중단
```

**각 단계에서 측정하는 지표:**
| 지표 | 설명 | 계산 방식 |
|------|------|-----------|
| TPS | 초당 처리량 | 성공 요청 수 ÷ 측정 시간 |
| 평균 응답시간 | 요청당 평균 처리 시간 | 전체 응답시간 합 ÷ 요청 수 |
| P99 응답시간 | 99%ile 응답시간 | 상위 1% 제외한 최대 응답시간 |
| 에러율 | 실패 요청 비율 | 실패 요청 ÷ 전체 요청 × 100 |

#### 2.3 포화점 탐지 (Saturation Detection)

**종료 기준 (하나라도 해당되면 테스트 종료):**

| 기준 | 기본값 | 의미 |
|------|--------|------|
| 최대 응답시간 초과 | 100ms | 평균 응답시간이 100ms를 넘으면 서버가 포화 상태 |
| 최대 에러율 초과 | 5% | 에러가 5% 이상 발생하면 서버가 한계에 도달 |
| 최대 동시접속 도달 | 100개 | 설정된 최대치까지 테스트 완료 |

**포화점 판단 기준:**
```
정상 상태:
  - 부하 증가 → TPS 비례 증가
  - 응답시간 일정하게 유지

포화 상태 진입:
  - 부하 증가 → TPS 증가 둔화 또는 감소
  - 응답시간 급격히 증가
  - 에러 발생 시작
```

### 3. 테스트 설정 파라미터

#### 3.1 환경변수 설정

```bash
# 워밍업 설정
WARMUP_DURATION=30        # 워밍업 시간 (초)
WARMUP_CONCURRENCY=5      # 워밍업 동시접속 수

# 부하 증가 설정
INITIAL_CONCURRENCY=5     # 시작 동시접속 수
CONCURRENCY_STEP=5        # 단계별 증가량
MAX_CONCURRENCY=100       # 최대 동시접속 수
STEP_DURATION=30          # 각 단계 측정 시간 (초)

# 종료 기준
MAX_RESPONSE_TIME_MS=100  # 최대 허용 응답시간 (ms)
MAX_ERROR_RATE=5          # 최대 허용 에러율 (%)
```

#### 3.2 권장 설정 시나리오

**시나리오 A: 빠른 테스트 (개발 중 확인용)**
```bash
WARMUP_DURATION=10 \
STEP_DURATION=15 \
CONCURRENCY_STEP=10 \
MAX_CONCURRENCY=50 \
./scripts/benchmark.sh
```

**시나리오 B: 표준 테스트 (일반적인 성능 측정)**
```bash
WARMUP_DURATION=30 \
STEP_DURATION=30 \
CONCURRENCY_STEP=5 \
MAX_CONCURRENCY=100 \
./scripts/benchmark.sh
```

**시나리오 C: 정밀 테스트 (운영 환경 검증용)**
```bash
WARMUP_DURATION=60 \
STEP_DURATION=60 \
CONCURRENCY_STEP=5 \
MAX_CONCURRENCY=200 \
./scripts/benchmark.sh
```

### 4. 워크로드 유형

| 엔드포인트 | 객체 크기 | 할당 횟수/요청 | 시뮬레이션 대상 |
|------------|-----------|----------------|-----------------|
| `/allocate` | 1-5KB | 10-50개 | 웹 API, REST 서비스 |
| `/heavy` | 10-110KB | 50-150개 | 배치 처리, 대용량 데이터 처리 |

### 5. 결과 해석 가이드

#### 5.1 출력 예시

```
동시접속    TPS          평균응답(ms)   P99응답(ms)    에러율(%)    상태
-----------------------------------------------------------------------------
5           1250.00      4              8              0.00         OK
10          2340.00      6              12             0.00         OK
15          3100.00      9              18             0.00         OK
20          3450.00      15             35             0.00         OK      ← 최적점
25          3200.00      45             98             0.00         OK      ← TPS 감소 시작
30          2800.00      120            250            2.50         응답시간 초과  ← 포화점
```

#### 5.2 결과 분석

**최적 동시접속 수 찾기:**
- TPS가 가장 높은 지점 = 최적 동시접속 수
- 위 예시에서는 동시접속 20개일 때 TPS 3450으로 최적

**포화점 확인:**
- 응답시간이 급격히 증가하는 지점
- TPS가 감소하기 시작하는 지점
- 위 예시에서는 동시접속 25개부터 포화 징후, 30개에서 완전 포화

#### 5.3 GC별 예상 결과

| 항목 | G1GC | Parallel GC |
|------|------|-------------|
| 최대 TPS | 중간 | 높음 |
| 응답시간 일관성 | 좋음 (편차 작음) | 보통 (편차 큼) |
| 포화점 | 빨리 도달 | 늦게 도달 |
| GC 오버헤드 | 5-10% | 2-5% |

### 6. 주의사항

1. **테스트 환경 격리**: 다른 프로세스가 CPU/메모리를 사용하지 않도록 주의
2. **반복 측정**: 정확한 결과를 위해 3회 이상 반복 측정 권장
3. **힙 크기 고정**: `-Xms`와 `-Xmx`를 동일하게 설정하여 힙 리사이징 오버헤드 제거
4. **네트워크 제외**: 로컬에서 테스트하여 네트워크 지연 변수 제거

### 7. 결과 파일

테스트 완료 후 `results/` 디렉토리에 생성되는 파일:

```
results/
├── benchmark-20240105-143022.csv    # 단계별 측정 데이터
├── benchmark-20240105-143022.txt    # 요약 리포트
├── g1gc-light-20240105-150000.csv   # G1GC light 워크로드 결과
├── g1gc-heavy-20240105-150500.csv   # G1GC heavy 워크로드 결과
├── parallel-light-20240105-151000.csv
└── parallel-heavy-20240105-151500.csv
```

CSV 파일을 엑셀이나 구글 시트에서 열어 그래프로 시각화할 수 있습니다.

## Project Structure

```
gctrack/
├── src/main/java/com/gctest/
│   └── GCThroughputServer.java    # Main test server
├── scripts/
│   ├── build.sh                   # Build script
│   ├── run-g1gc.sh               # Run with G1GC
│   ├── run-parallel-gc.sh        # Run with Parallel GC
│   ├── benchmark.sh              # 체계적인 벤치마크 스크립트
│   ├── benchmark-compare.sh      # G1GC vs Parallel GC 비교
│   ├── load-test.sh              # 간단한 부하 테스트
│   └── compare-gc.sh             # 간단한 비교 테스트
├── config/
│   ├── g1gc.conf                 # G1GC configuration reference
│   ├── parallel-gc.conf          # Parallel GC configuration reference
│   └── test-params.conf          # Test parameters
├── gc-logs/                      # GC log output directory
├── results/                      # Test results directory (CSV 포함)
└── README.md
```

## Server Endpoints

| Endpoint | Description |
|----------|-------------|
| `GET /allocate` | Light allocation workload (1-5KB objects) |
| `GET /heavy` | Heavy allocation workload (10-110KB objects) |
| `GET /stats` | View GC and throughput statistics |
| `GET /health` | Health check endpoint |
| `GET /gc` | Force garbage collection |

## Configuration

### Heap Size

```bash
HEAP_SIZE=4g ./scripts/run-g1gc.sh
```

### Port

```bash
PORT=9090 ./scripts/run-g1gc.sh
```

### Load Test Parameters

```bash
DURATION=120 CONCURRENCY=20 ENDPOINT=/heavy ./scripts/load-test.sh
```

## Understanding the Results

### Key Metrics

- **Throughput (req/s)**: Higher is better
- **Average Latency (µs)**: Lower is better
- **GC Collections**: Total number of GC events
- **GC Time (ms)**: Total time spent in GC
- **GC Overhead (%)**: Percentage of time spent in GC

### Typical Results

| Metric | G1GC | Parallel GC |
|--------|------|-------------|
| Best For | Low latency | High throughput |
| Pause Times | More predictable | Can be longer |
| Throughput | Good | Excellent |
| Memory Overhead | Higher | Lower |

## GC Tuning Tips

### G1GC

```bash
# Lower latency (smaller pauses)
-XX:MaxGCPauseMillis=50

# Higher throughput
-XX:MaxGCPauseMillis=500 -XX:G1HeapRegionSize=32m
```

### Parallel GC

```bash
# Maximum throughput
-XX:GCTimeRatio=99 -XX:MaxGCPauseMillis=500

# Balanced
-XX:GCTimeRatio=19 -XX:MaxGCPauseMillis=200
```

## Analyzing GC Logs

GC logs are saved to `gc-logs/` directory. Use these tools for analysis:

- **GCViewer**: https://github.com/chewiebug/GCViewer
- **GCEasy**: https://gceasy.io/ (online analyzer)
- **Eclipse MAT**: For heap dump analysis

## Example Test Scenarios

### Scenario 1: Web Application Simulation

```bash
# Light, frequent allocations
ENDPOINT=/allocate CONCURRENCY=50 DURATION=300 ./scripts/load-test.sh
```

### Scenario 2: Batch Processing Simulation

```bash
# Heavy allocations, lower concurrency
ENDPOINT=/heavy CONCURRENCY=10 DURATION=300 ./scripts/load-test.sh
```

### Scenario 3: Memory Pressure Test

```bash
# Small heap with heavy load
HEAP_SIZE=512m ./scripts/run-g1gc.sh
ENDPOINT=/heavy CONCURRENCY=20 ./scripts/load-test.sh
```

## When to Use Each GC

### Use G1GC When:
- Latency-sensitive applications (web services, APIs)
- Large heaps (>4GB)
- Need predictable pause times
- Mixed workloads

### Use Parallel GC When:
- Batch processing applications
- Maximum throughput is priority
- Can tolerate occasional longer pauses
- Memory-constrained environments

## Troubleshooting

### Out of Memory

Increase heap size:
```bash
HEAP_SIZE=4g ./scripts/run-g1gc.sh
```

### Port Already in Use

Change the port:
```bash
PORT=9090 ./scripts/run-g1gc.sh
```

### Java Version Issues

Check your Java version:
```bash
java -version
```

The project is compiled with Java 8 compatibility. The scripts automatically detect Java version and use appropriate GC logging options:
- Java 8: Uses `-XX:+PrintGCDetails -Xloggc:<file>`
- Java 9+: Uses `-Xlog:gc*:file=<file>`

## License

MIT License
