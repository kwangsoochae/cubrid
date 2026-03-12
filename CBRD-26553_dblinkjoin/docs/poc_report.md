# CBRD-26553 DBLink 조인 키 푸시 최적화 — POC 결과 보고서

| 항목 | 내용 |
|------|------|
| 이슈 | CBRD-26553 |
| Before 브랜치 | `develop` |
| After 브랜치 | `dblink_join_improve` |
| 환경 | WSL2 (loopback, 단일 머신) |

---

## 1. 결과 요약

| POC | 시나리오 | Before | After | 배율 | 판정 |
|-----|---------|--------|-------|------|------|
| A | 낮은 선택도 (0.01%) | 0.491s | 0.018s | **26.7x 빠름** | ✅ 효과 |
| B | 조인 결과 없음 | 0.481s | 0.020s | **24.5x 빠름** | ✅ 효과 |
| C | 높은 선택도 (100%) | 0.023s | 0.095s | 4.1x 느림 | ❌ 역효과 |
| D | outer 많음, remote 작음 | 0.017s | 0.272s | 15.8x 느림 | ❌ 역효과 |
| E | 전송행 동일 (손익분기) | 0.228s | 0.481s | 2.1x 느림 | ❌ 역효과 |

낮은 선택도에서 좋은 효과. 높은 선택도/outer(local) 다수/remote 소규모에서 역효과 (좋은 성능의 경우도 있으나, 통계 기반 최적화 선택 등 추가 작업 없이 본작업 단순 적용은 좋은 선택으로 보이지 않음)

---

## 2. 분석

### 효과 케이스 (POC-A, B)

```
전송 절약량 = remote_total - outer_count × avg_match
POC-A: 100,000 - 10 × 1  = 99,990행 절약 → 26.7x 향상
POC-B: 100,000 - 10 × 0  = 100,000행 절약 → 24.5x 향상 (fetch 자체 없음)
```

### 역효과 케이스 (POC-C, D)

```
POC-C: outer × avg_match (100 × 100 = 10,000) > remote_total (1,000)
       → After 전송량이 Before의 10배. MEMOIZE hit 90% 효과도 소멸.
POC-D: remote가 이미 작아 1회 fetch가 최소 비용.
       After는 1,000회 execute → execute당 ~0.27ms × 1,000 = 270ms
```

### 손익분기 분석 (POC-E)

전송행 수가 동일해도 After가 2.1x 느림:
```
Before: 1회 execute + 100,000행 전송 = 228ms
After: 10회 execute + 100,000행 전송 = 481ms
→ execute 1회 setup 오버헤드 ≈ (481-228) / 9 ≈ 28ms (loopback 기준)
```

실제 break-even 지점은 전송행 동일 지점보다 훨씬 낮음:
```
절약행 수 > 28ms / 2.28μs(행당 비용) ≈ 12,280행
→ outer 1행이 줄이는 전송량이 12,280행 이상일 때 After 유리
```

### 향후 과제

push-down 적용 조건 (안):

유리한 조건: 절약 시간 > 추가 시간

절약한 시간: 전송행이 줄어서 아낀 시간
절약 전송행 수 = remote_total - outer_count × avg_match
절약 시간     = 절약 전송행 수 × row_cost  (행 1개 전송·처리 비용)

  - 추가로 든 시간: execute 횟수가 늘어서 생긴 round-trip 오버헤드
    추가 round-trip = outer_count - 1  ≈  outer_count
    추가 시간       = outer_count × round_trip_latency
    (remote_total - outer_count × avg_match) × row_cost  >  outer_count × round_trip_latency

WAN 환경에서는 round-trip latency가 커지므로 POC-D 유형의 역효과가 더 심각해진다.

---

## 3. 테스트 환경

### DB 구성

```
단일 머신 (WSL2)
├── testdb          (로컬 DB — 조인 outer 측)
└── testdb4dblink   (원격 DB — dblink inner 측, @cubrid_conn)
```

### 데이터 규모

| POC | 로컬 테이블 | 행 수 | 원격 테이블 | 행 수 | 매칭 건수 |
|-----|-----------|------|-----------|------|---------|
| A | local_small_t | 10 | remote_large_t | 100,000 | 10건 (0.01%) |
| B | local_nomatch_t | 10 | remote_large_t | 100,000 | 0건 |
| C | local_hiselectivity_t | 100 | remote_hiselectivity_t | 1,000 | 10,000건 (100%) |
| D | local_manyouter_t | 1,000 | remote_smalltable_t | 5 | 5건 |
| E | local_breakeven_t | 10 | remote_breakeven_t | 100,000 | 100,000건 (100%) |

---

## 4. 실행 계획 변화

### Before — 공통 패턴

Before는 모든 케이스에서 동일한 패턴으로 실행된다.

```
SELECT
  SCAN (table: local_xxx_t)          ← outer
    SCAN (hash temp)                  ← dblink 결과 전체를 hash로 빌드
    MEMOIZE                           ← hash probe 결과 캐시
  SUBQUERY (uncorrelated)             ← dblink: 1회만 execute
    SELECT
      SCAN (dblink ...)               ← remote 전체 fetch
```

- `SUBQUERY (uncorrelated)`: outer row와 무관하게 **1회만 실행**
- 매칭 여부·건수에 무관하게 항상 remote 전체 전송

### After — 변화된 패턴

```
Query Plan:
  NESTED LOOPS (cross join)
    TABLE SCAN (l)                    ← outer
    TABLE SCAN (r)                    ← inner (dblink, correlated)

rewritten query:
  SELECT * FROM (...) WHERE id = ?    ← 조인 키 push-down
```

- outer row마다 `WHERE id = ?` 조건이 push-down된 쿼리로 **개별 execute**
- remote에서 매칭 행만 반환 → 불필요한 전송 제거

---

## 5. 시나리오별 상세

### POC-A: 낮은 선택도 (0.01% 매칭)

**쿼리**
```sql
SELECT l.id, l.name, r.val
FROM local_small_t l, remote_large_t@cubrid_conn r
WHERE l.id = r.id;
-- outer 10행, remote 100,000행, 매칭 10건
```

| | Before | After | 배율 |
|--|--------|-------|------|
| 실행 시간 | **0.491s** | **0.018s** | **26.7x 빠름** |
| dblink execute | 1회 | 10회 | |
| 전송 행 수 | 100,000행 | 10행 | 1/10,000 |

**Before 실행 계획**
```
SELECT (time: 588ms, fetch: 6452)
  SCAN (table: local_small_t, readrows: 10, rows: 10)
    SCAN (hash temp(h), build time: 36ms, readrows: 100010, rows: 10)
    MEMOIZE (hit: 0, miss: 10)
  SUBQUERY (uncorrelated)
    SELECT (time: 540ms)
      SCAN (dblink time: 340ms)
```

**After 실행 계획**
```
SELECT (time: 8ms, fetch: 8)
  SCAN (table: local_small_t, readrows: 10, rows: 10)
    SCAN (dblink time: 0ms)
```
hash temp / MEMOIZE / uncorrelated 구조 소멸. outer 10행 × 1회 execute, 매칭 1행씩 즉시 반환.

---

### POC-B: 조인 결과 없음

**쿼리**
```sql
SELECT l.id, l.name, r.val
FROM local_nomatch_t l, remote_large_t@cubrid_conn r
WHERE l.id = r.id;
-- outer 10행 (id 100001~100010), remote 100,000행, 매칭 0건
```

| | Before | After | 배율 |
|--|--------|-------|------|
| 실행 시간 | **0.481s** | **0.020s** | **24.5x 빠름** |
| dblink execute | 1회 | 10회 | |
| 전송 행 수 | 100,000행 | 0행 | 0 |

**Before 실행 계획**
```
SELECT (time: 476ms, fetch: 6452)
  SCAN (table: local_nomatch_t, readrows: 10, rows: 10)
    SCAN (hash temp(h), build time: 32ms, readrows: 100000, rows: 0)
    MEMOIZE (hit: 0, miss: 10)
  SUBQUERY (uncorrelated)
    SELECT (time: 428ms)
      SCAN (dblink time: 284ms)
```
매칭 0건임에도 100,000행 전체 fetch. hash temp rows: 0.

**After 실행 계획**
```
SELECT (time: 8ms, fetch: 8)
  SCAN (table: local_nomatch_t, readrows: 10, rows: 10)
    SCAN (dblink time: 0ms)
```
10회 execute, 각 0행 반환 → fetch 자체 없음.

---

### POC-C: 고선택도 (100% 매칭)

**쿼리**
```sql
SELECT COUNT(*) AS result_count
FROM local_hiselectivity_t l, remote_hiselectivity_t@cubrid_conn r
WHERE l.id = r.id;
-- outer 100행 (id당 10행), remote 1,000행 (id당 100행), outer 1행당 100건 매칭
```

| | Before | After | 배율 |
|--|--------|-------|------|
| 실행 시간 | **0.023s** | **0.095s** | **4.1x 느림** |
| dblink execute | 1회 | 100회 | |
| 전송 행 수 | 1,000행 | 10,000행 | 10배 증가 |

**Before 실행 계획**
```
SELECT (time: 8ms, fetch: 8)
  SCAN (table: local_hiselectivity_t, readrows: 100, rows: 100)
    SCAN (hash temp(m), readrows: 2000, rows: 1000)
    MEMOIZE (hit: 90, miss: 10)    ← id 10종류 → 10회 probe, 90회 캐시 히트
  SUBQUERY (uncorrelated)
    SELECT (time: 4ms)
      SCAN (dblink time: 4ms)
```
MEMOIZE hit 90% — 동일 id 반복 outer에서 캐시 효과 극대화.

**After 실행 계획**
```
Query Plan:
  NESTED LOOPS (cross join)
    TABLE SCAN (l)
    TABLE SCAN (r)
rewritten: SELECT * FROM (...) WHERE id = ?

SELECT (time: 80ms, fetch: 8)
  SCAN (table: local_hiselectivity_t, readrows: 100, rows: 100)
    SCAN (dblink time: 0ms)
```
100회 execute × 100행 fetch = 10,000행 전송 (Before의 10배). MEMOIZE 효과 소멸.

---

### POC-D: 다수 outer × 소규모 remote

**쿼리**
```sql
SELECT l.id, l.name, r.val
FROM local_manyouter_t l, remote_smalltable_t@cubrid_conn r
WHERE l.id = r.id;
-- outer 1,000행 (id 1~1,000), remote 5행 (id 1~5), 매칭 5건
```

| | Before | After | 배율 |
|--|--------|-------|------|
| 실행 시간 | **0.017s** | **0.272s** | **15.8x 느림** |
| dblink execute | 1회 | 1,000회 | |
| 전송 행 수 | 5행 | 5행 | 동일 |

**Before 실행 계획**
```
SELECT (time: 8ms, fetch: 20)
  SCAN (table: local_manyouter_t, readrows: 1000, rows: 1000)
    SCAN (hash temp(m), readrows: 10, rows: 5)
    MEMOIZE (hit: 0, miss: 1000)   ← outer 1000행 전부 distinct → 캐시 효과 없음
  SUBQUERY (uncorrelated)
    SELECT (time: 8ms)
      SCAN (dblink time: 0ms)      ← remote 5행, 거의 무비용
```

**After 실행 계획**
```
Query Plan:
  NESTED LOOPS (cross join)
    TABLE SCAN (l)
    TABLE SCAN (r)
rewritten: SELECT * FROM (...) WHERE id = ?

SELECT (time: 492ms, fetch: 20)
  SCAN (table: local_manyouter_t, readrows: 1000, rows: 1000)
    SCAN (dblink time: 4ms)
```
1,000회 execute × ~0행. execute당 약 0.27ms — round-trip이 지배.

---

### POC-E: 손익분기 (전송행 동일)

**쿼리**
```sql
SELECT COUNT(*)
FROM local_breakeven_t l, remote_breakeven_t@cubrid_conn r
WHERE l.id = r.id;
-- outer 10행 (id 1~10), remote 100,000행 (id당 10,000행), 총 100,000건 매칭
```

| | Before | After | 배율 |
|--|--------|-------|------|
| 실행 시간 | **0.228s** | **0.481s** | **2.1x 느림** |
| dblink execute | 1회 | 10회 | |
| 전송 행 수 | 100,000행 | 100,000행 | 동일 |

**Before 실행 계획**
```
SELECT (time: 12ms, fetch: 48)
  SCAN (table: local_breakeven_t, readrows: 10, rows: 10)
    SCAN (hash temp(m), readrows: 2000, rows: 1000)
    MEMOIZE (hit: 0, miss: 10)
  SUBQUERY (uncorrelated)
    SELECT (time: 8ms)
      SCAN (dblink time: 4ms)
```

**After 실행 계획**
```
Query Plan:
  NESTED LOOPS (cross join)
    TABLE SCAN (l)
    TABLE SCAN (r)
rewritten: SELECT * FROM (...) WHERE id = ?

SELECT (time: 492ms, fetch: 8)
  SCAN (table: local_breakeven_t, readrows: 10, rows: 10)
    SCAN (dblink time: 76ms)
```
10회 execute × 10,000행 fetch = 100,000행 (Before와 동일). execute당 약 48ms.
같은 데이터를 10번에 나눠 전송하는 비용이 2.1x 오버헤드로 나타남.

---

## 6. 참고: 테이블 스키마 및 데이터 구성

### 원격 DB (testdb4dblink)

#### remote_large_t — POC-A, POC-B용
```sql
CREATE TABLE remote_large_t (
  id  INT PRIMARY KEY,
  val VARCHAR(100)   -- LPAD(TO_CHAR(id), 50, '0') 형식, 예: '00000...00001'
);
-- 행 수: 100,000행 (id 1~100,000)
-- 셋업: setup_large_data_remote_100k.sql
```

#### remote_hiselectivity_t — POC-C용
```sql
CREATE TABLE remote_hiselectivity_t (
  seq INT PRIMARY KEY,
  id  INT,           -- 1~10 반복 (id당 100행)
  val VARCHAR(100)   -- LPAD(TO_CHAR(seq), 50, '0') 형식
);
-- 행 수: 1,000행 (id 1~10, id당 100행)
-- 셋업: setup_worst_case_remote.sql
```

#### remote_smalltable_t — POC-D용
```sql
CREATE TABLE remote_smalltable_t (
  id  INT PRIMARY KEY,
  val VARCHAR(100)   -- 'R_01'~'R_05' 형식
);
-- 행 수: 5행 (id 1~5)
-- 셋업: setup_worst_case_remote.sql
```

#### remote_breakeven_t — POC-E용
```sql
CREATE TABLE remote_breakeven_t (
  seq INT PRIMARY KEY,
  id  INT,           -- 1~10 반복 (id당 10,000행)
  val VARCHAR(100)   -- LPAD(TO_CHAR(seq), 50, '0') 형식
);
-- 행 수: 100,000행 (id 1~10, id당 10,000행)
-- 셋업: setup_breakeven_remote_100k.sql
-- 예시: seq=1, id=1, val='00000000000000000000000000000000000000000000000001'
```

### 로컬 DB (testdb)

#### local_small_t — POC-A용
```sql
CREATE TABLE local_small_t (
  id   INT PRIMARY KEY,
  name VARCHAR(50)   -- 'L_01'~'L_10' 형식
);
-- 행 수: 10행 (id 1~10) → remote_large_t와 10건 매칭 (선택도 0.01%)
-- 셋업: setup_large_data_local_100k.sql
```

#### local_nomatch_t — POC-B용
```sql
CREATE TABLE local_nomatch_t (
  id   INT PRIMARY KEY,
  name VARCHAR(50)   -- 'N_01'~'N_10' 형식
);
-- 행 수: 10행 (id 100,001~100,010) → remote_large_t와 매칭 0건
-- 셋업: setup_large_data_local_100k.sql
```

#### local_hiselectivity_t — POC-C용
```sql
CREATE TABLE local_hiselectivity_t (
  seq  INT PRIMARY KEY,
  id   INT,          -- 1~10 반복 (id당 10행)
  name VARCHAR(50)   -- LPAD(TO_CHAR(seq), 10, '0') 형식
);
-- 행 수: 100행 (id 1~10, id당 10행)
-- remote_hiselectivity_t와 outer 1행당 100건 매칭 (선택도 100%)
-- 셋업: setup_worst_case_local.sql
```

#### local_manyouter_t — POC-D용
```sql
CREATE TABLE local_manyouter_t (
  id   INT PRIMARY KEY,
  name VARCHAR(50)   -- LPAD(TO_CHAR(id), 10, '0') 형식
);
-- 행 수: 1,000행 (id 1~1,000)
-- remote_smalltable_t와 id 1~5만 매칭 (5건), 나머지 995행은 0건
-- 셋업: setup_worst_case_local.sql
```

#### local_breakeven_t — POC-E용
```sql
CREATE TABLE local_breakeven_t (
  id   INT PRIMARY KEY,
  name VARCHAR(50)   -- 'L_01'~'L_10' 형식
);
-- 행 수: 10행 (id 1~10)
-- remote_breakeven_t와 outer 1행당 10,000건 매칭 → 총 100,000건 = remote 전체
-- 셋업: setup_breakeven_local.sql
```