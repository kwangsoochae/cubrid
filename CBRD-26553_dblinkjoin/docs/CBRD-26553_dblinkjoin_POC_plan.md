# CBRD-26553 DBLink 조인 키 푸시 최적화 — POC 계획

| 항목 | 내용 |
|------|------|
| 이슈 | CBRD-26553 |
| 목적 | 조인 키 push-down 최적화의 **효과 확인** 및 **성능 저하 케이스 파악** |
| 관련 문서 | [PRD](dblink_join_optimization_prd.md), [TESTS](dblink_join_optimization_tests.md) |

---

## 1. POC 목표

다음 두 가지를 실측으로 확인한다.

1. **효과 있음**: 낮은 선택도(remote 크고 매칭 적을 때) → 전송 행 수 감소, 실행 시간 개선
2. **역효과**: 높은 선택도 또는 outer가 매우 많을 때 → execute round-trip 비용이 지배적

Before(AS-IS) / After(최적화 적용)를 **동일 쿼리·동일 데이터**로 비교한다.

---

## 2. 측정 지표

| 지표 | 측정 방법 | 비고 |
|------|-----------|------|
| 실행 시간 | csql `;time on` | 주요 지표 |
| 원격 execute 횟수 | `cubrid statdump -c <remote_db> \| grep Num_query_selects` | Before +1, After +N |
| 전송 행 수 | execute 횟수 × avg 반환 행 | 간접 측정 |
| 결과 정확성 | Before/After 결과 행 수·값 일치 | 필수 확인 |

---

## 3. 환경 구성

### 3.1 DB 구성

```
단일 머신
├── testdb          (로컬 DB — 조인 outer 측, csql 접속 대상)
└── testdb4dblink   (원격 DB — dblink inner 측, @cubrid_conn 으로 접근)
```

두 DB 모두 같은 머신에서 실행. dblink 연결 이름은 `cubrid_conn`.

### 3.2 Before / After 빌드

| 구분 | 브랜치 | 설치 경로 |
|------|--------|-----------|
| Before (AS-IS) | `develop` | `/home/kchae/CUBRID_before/` |
| After (최적화) | `dblink_join_improve` | `/home/kchae/CUBRID/` |

Before 빌드는 `cubrid_pr` 디렉토리를 활용:

```bash
cd /home/kchae/GitHub/cubrid_pr
git checkout develop && git pull

cmake --preset debug -DCMAKE_INSTALL_PREFIX=/home/kchae/CUBRID_before
cmake --build --preset debug -- -j$(nproc)
cmake --install build_preset_debug
```

After 빌드(현재 브랜치)는 이미 `/home/kchae/CUBRID/`에 설치되어 있다고 가정.

---

## 4. 환경 셋업 절차

### 4.1 DB 생성 및 시작 (최초 1회)

```bash
cd /home/kchae/GitHub/cubrid/CBRD-26553_dblinkjoin/test/

# testdb4dblink (원격), testdb (로컬) 생성 및 서버 시작
./test_setup_dblink_databases.sh

# 기본 스키마·데이터 적재 (remote_t 7행, local_t 5행)
./test_run_dblink_join.sh
```

### 4.2 성능 측정용 데이터 적재 (최초 1회)

```bash
# POC-A, POC-B 용 (large data)
csql testdb4dblink -i setup_large_data_remote.sql  # remote_large_t 10,000행
csql testdb        -i setup_large_data_local.sql   # local_small_t 10행, local_nomatch_t 10행

# POC-C, POC-D 용 (worst case)
csql testdb4dblink -i setup_worst_case_remote.sql  # remote_hiselectivity_t 1,000행, remote_smalltable_t 5행
csql testdb        -i setup_worst_case_local.sql   # local_hiselectivity_t 100행, local_manyouter_t 1,000행

# POC-E 용 (break-even: 전송 행 수 동일)
csql testdb4dblink -i setup_breakeven_remote.sql   # remote_breakeven_t 1,000행 (id당 100행)
csql testdb        -i setup_breakeven_local.sql    # local_breakeven_t 10행
```

### 4.3 Before / After 전환 방법

빌드를 교체하면 **반드시 서버 재시작** 필요 (`cub_server` 바이너리가 교체되어야 함).

```bash
# Before 로 전환
export CUBRID=/home/kchae/CUBRID_before
export PATH=$CUBRID/bin:$PATH
cubrid server stop testdb4dblink && cubrid server stop testdb
cubrid server start testdb4dblink && cubrid server start testdb

# After 로 전환
export CUBRID=/home/kchae/CUBRID
export PATH=$CUBRID/bin:$PATH
cubrid server stop testdb4dblink && cubrid server stop testdb
cubrid server start testdb4dblink && cubrid server start testdb
```

---

## 5. 시나리오 및 예상 결과

### POC-A: 낮은 선택도 — 최적화 유리 케이스

| 항목 | 내용 |
|------|------|
| SQL 파일 | `test/TC-501.sql` |
| 로컬 테이블 | `local_small_t` — 10행 (id 1~10) |
| 원격 테이블 | `remote_large_t` — 10,000행 (id 1~10,000) |
| 매칭 | 10건 (선택도 0.1%) |

```sql
SELECT l.id, l.name, r.val
FROM local_small_t l, remote_large_t@cubrid_conn r
WHERE l.id = r.id
ORDER BY l.id;
```

| 구분 | 원격 execute | 전송 행 | 예상 시간 |
|------|-------------|---------|-----------|
| Before | 1회 | 10,000행 전송 → 로컬 filter | 느림 |
| After | 10회 | 10행만 전송 | 빠름 |

**기대**: After가 Before 대비 전송량 1/1,000 → 실행 시간 대폭 감소.

---

### POC-B: Zero-match — 최적화 압도 케이스

| 항목 | 내용 |
|------|------|
| SQL 파일 | `test/TC-502.sql` |
| 로컬 테이블 | `local_nomatch_t` — 10행 (id 10,001~10,010) |
| 원격 테이블 | `remote_large_t` — 10,000행 (id 1~10,000) |
| 매칭 | 0건 |

```sql
SELECT l.id, l.name, r.val
FROM local_nomatch_t l, remote_large_t@cubrid_conn r
WHERE l.id = r.id
ORDER BY l.id;
```

| 구분 | 원격 execute | 전송 행 | 로컬 predicate 평가 | 예상 시간 |
|------|-------------|---------|---------------------|-----------|
| Before | 1회 | 10,000행 | 10 × 10,000 = 100,000회 모두 실패 | 느림 |
| After | 10회 | 0행 (즉시 S_END) | 0회 | 매우 빠름 |

**기대**: After가 가장 극적인 개선. fetch 자체가 없으므로 거의 즉시 완료.

---

### POC-E: 전송 행 수 동일 — round-trip overhead 케이스

| 항목 | 내용 |
|------|------|
| SQL 파일 | `test/TC-POC-E.sql` (신규) |
| 로컬 테이블 | `local_breakeven_t` — 10행 (id 1~10) |
| 원격 테이블 | `remote_breakeven_t` — 1,000행 (id 1~10, id당 100행) |
| 매칭 | outer 1행당 100건 → 총 1,000건 = remote 전체 행 수 |

```sql
SELECT l.id, r.val
FROM local_breakeven_t l, remote_breakeven_t@cubrid_conn r
WHERE l.id = r.id
ORDER BY l.id;
```

| 구분 | 원격 execute | 전송 행 | round-trip | 예상 시간 |
|------|-------------|---------|------------|-----------|
| Before | 1회 | 1,000행 | 1회 | 기준 |
| After | 10회 | 1,000행 (동일) | 10회 | Before보다 느림 |

**핵심**: 전송 행 수는 같은데 execute round-trip이 10배 → **데이터 절약 없이 overhead만 증가**.
WAN 환경에서는 round-trip latency가 커져 격차가 더 벌어진다.

이 케이스가 시사하는 것:
- 전송 행 감소분이 round-trip 비용을 상쇄해야 실질 이득이 생긴다.
- `outer_count × avg_match < remote_total` 조건만으로는 부족하고,
  절약되는 전송량이 `outer_count × round_trip_cost`를 넘어야 실제 이득.
- 로컬 환경(latency ≈ 0)에서는 POC-A(0.1%)처럼 절약이 압도적인 경우에만 확실히 유리.

---

### POC-C: 높은 선택도 — 최적화 불리 케이스

| 항목 | 내용 |
|------|------|
| SQL 파일 | `test/TC-601.sql` |
| 로컬 테이블 | `local_hiselectivity_t` — 100행 (id 1~10, id당 10행) |
| 원격 테이블 | `remote_hiselectivity_t` — 1,000행 (id 1~10, id당 100행) |
| 매칭 | outer 1행당 100건 (선택도 100%) |

```sql
SELECT COUNT(*) AS result_count
FROM local_hiselectivity_t l, remote_hiselectivity_t@cubrid_conn r
WHERE l.id = r.id;
```

| 구분 | 원격 execute | 전송 행 | 예상 시간 |
|------|-------------|---------|-----------|
| Before | 1회 | 1,000행 (전체 1회) | 빠름 |
| After | 100회 | 10,000행 (100 × 100) | 느림 (fetch 10배 + execute 100배) |

**기대**: After가 Before보다 느림. cost 기반 최적화 미적용 시의 역효과 확인.
결과 COUNT = 10,000 (정확성 확인).

---

### POC-D: 다수 outer + 소규모 remote — round-trip 오버헤드 케이스

| 항목 | 내용 |
|------|------|
| SQL 파일 | `test/TC-602.sql` |
| 로컬 테이블 | `local_manyouter_t` — 1,000행 (id 1~1,000) |
| 원격 테이블 | `remote_smalltable_t` — 5행 (id 1~5) |
| 매칭 | 5건 (id 1~5만 매칭, 나머지 995행은 0건) |

```sql
SELECT l.id, l.name, r.val
FROM local_manyouter_t l, remote_smalltable_t@cubrid_conn r
WHERE l.id = r.id
ORDER BY l.id;
```

| 구분 | 원격 execute | 전송 행 | 예상 시간 |
|------|-------------|---------|-----------|
| Before | 1회 | 5행 (전체, 이미 매우 빠름) | 매우 빠름 |
| After | 1,000회 | 5행 | 느림 (execute round-trip 1,000배) |

**기대**: After가 Before보다 훨씬 느림. remote가 작고 outer가 많을 때 최악의 케이스.
고지연 네트워크(WAN) 환경에서는 더욱 심각.
결과 5행 (정확성 확인).

---

## 6. 측정 절차 (단계별)

### Step 1: Before 측정

```bash
# 1-1. Before 빌드로 전환
export CUBRID=/home/kchae/CUBRID_before
export PATH=$CUBRID/bin:$PATH
cubrid server stop testdb4dblink && cubrid server stop testdb
cubrid server start testdb4dblink && cubrid server start testdb

# 1-2. statdump 기준값 기록 (execute 횟수 측정용)
cubrid statdump -c testdb4dblink | grep Num_query_selects > /tmp/stat_before_base.txt

# 1-3. 각 시나리오 실행·시간 기록
csql testdb << 'EOF'
;time on

-- POC-A
\i CBRD-26553_dblinkjoin/test/TC-501.sql
;run

-- POC-B
\i CBRD-26553_dblinkjoin/test/TC-502.sql
;run

-- POC-C
\i CBRD-26553_dblinkjoin/test/TC-601.sql
;run

-- POC-D
\i CBRD-26553_dblinkjoin/test/TC-602.sql
;run
EOF

# 1-4. statdump 이후값 기록
cubrid statdump -c testdb4dblink | grep Num_query_selects > /tmp/stat_before_after.txt
```

### Step 2: After 측정

```bash
# 2-1. After 빌드로 전환
export CUBRID=/home/kchae/CUBRID
export PATH=$CUBRID/bin:$PATH
cubrid server stop testdb4dblink && cubrid server stop testdb
cubrid server start testdb4dblink && cubrid server start testdb

# 2-2. statdump 기준값 기록
cubrid statdump -c testdb4dblink | grep Num_query_selects > /tmp/stat_after_base.txt

# 2-3. 동일한 시나리오 실행 (Step 1과 동일)

# 2-4. statdump 이후값 기록
cubrid statdump -c testdb4dblink | grep Num_query_selects > /tmp/stat_after_after.txt
```

### Step 3: 결과 비교

```bash
# execute 횟수 delta 확인
echo "=== Before execute delta ==="
diff /tmp/stat_before_base.txt /tmp/stat_before_after.txt

echo "=== After execute delta ==="
diff /tmp/stat_after_base.txt /tmp/stat_after_after.txt
```

---

## 7. 결과 기록 양식

측정 후 아래 표를 채운다.

| 시나리오 | 지표 | Before | After | 비율 | 판정 |
|--------|------|--------|-------|------|------|
| POC-A (선택도 0.1%) | 실행 시간 (ms) | | | | |
| | 원격 execute 횟수 | | | | |
| | 결과 행 수 | | 10 | | 일치 여부 |
| POC-B (zero-match) | 실행 시간 (ms) | | | | |
| | 원격 execute 횟수 | | | | |
| | 결과 행 수 | | 0 | | 일치 여부 |
| POC-C (선택도 100%) | 실행 시간 (ms) | | | | |
| | 원격 execute 횟수 | | | | |
| | 결과 행 수 (COUNT) | | 10,000 | | 일치 여부 |
| POC-D (outer 1,000 × remote 5) | 실행 시간 (ms) | | | | |
| | 원격 execute 횟수 | | | | |
| | 결과 행 수 | | 5 | | 일치 여부 |
| POC-E (전송 행 수 동일) | 실행 시간 (ms) | | | | |
| | 원격 execute 횟수 | 1 | 10 | ×10 | |
| | 결과 행 수 | | 1,000 | | 일치 여부 |

---

## 8. 예상 결론 및 의미

### 최적화가 유리한 조건 (After 승)

```
원격 테이블 크기 >> outer 행 수 × 평균 매칭 수
즉, 선택도(selectivity)가 낮을수록 유리
```

- POC-A: 원격 10,000행, 매칭 10건 → **1/1,000 전송** → 실행 시간 대폭 감소
- POC-B: 매칭 0건 → **fetch 자체 없음** → 가장 극적인 개선

### 최적화가 불리한 조건 (Before 승)

```
outer 행 수 × 평균 매칭 수 >= 원격 테이블 크기
즉, 선택도가 높거나 outer 행이 매우 많을 때
```

- POC-C: 선택도 100% → After 전송량 Before의 10배 + execute 100배
- POC-D: remote가 작아 Before는 이미 빠른데, After는 execute 1,000배
- POC-E: 전송 행 수 동일 → 데이터 절약 없이 execute round-trip만 10배 증가

### POC-E가 주는 핵심 통찰

```
전송량이 같으면 After는 항상 Before보다 불리하다.
  → After가 유리해지려면 "전송량 감소분 > round-trip 비용 증가분" 이어야 한다.
  → 단순히 outer_count × avg_match < remote_total 로는 부족하다.
```

break-even 지점:
```
절약된 전송량 = remote_total - outer_count × avg_match
round-trip 추가 비용 ∝ outer_count × latency

After 실질 유리 조건:
  (remote_total - outer_count × avg_match) × row_transfer_cost
  > outer_count × round_trip_latency
```

로컬 환경(latency ≈ 0): 전송량 절약이 조금만 있어도 After 유리.
WAN 환경(latency 큼): 전송량이 크게 줄어야 After 유리 → POC-E에서 After가 Before보다 현저히 느릴 수 있음.

### POC가 주는 메시지

| 결론 | 후속 작업 |
|------|-----------|
| POC-A, POC-B: 효과 있음 확인 | 최적화 방향 유효성 입증 |
| POC-C, POC-D: 역효과 확인 | **cost 기반 push-down 적용 판단 필요** → Phase 2 과제 |

cost 기반 판단 기준 (향후 검토):
```
push-down 적용 조건:
  원격 테이블 cardinality × 조인 선택도 > 임계값
  즉, "원격에서 걸러지는 행이 충분히 많을 때"만 적용
```

---

## 9. 체크리스트

### 셋업
- [ ] Before 빌드 완료 (`/home/kchae/CUBRID_before/`)
- [ ] After 빌드 완료 (`/home/kchae/CUBRID/`)
- [ ] `testdb`, `testdb4dblink` 생성 및 시작
- [ ] 기본 스키마·데이터 적재 (`test_run_dblink_join.sh`)
- [ ] 대용량 데이터 적재 (`setup_large_data_*.sql`)
- [ ] Worst case 데이터 적재 (`setup_worst_case_*.sql`)
- [ ] Break-even 데이터 적재 (`setup_breakeven_*.sql`)
- [ ] dblink 연결(`cubrid_conn`) 로컬 DB에 등록 확인

### Before 측정
- [ ] Before 빌드로 전환 + 서버 재시작
- [ ] POC-A 실행 시간 기록
- [ ] POC-B 실행 시간 기록
- [ ] POC-C 실행 시간 기록
- [ ] POC-D 실행 시간 기록
- [ ] POC-E 실행 시간 기록
- [ ] statdump execute 횟수 기록

### After 측정
- [ ] After 빌드로 전환 + 서버 재시작
- [ ] POC-A 실행 시간 기록
- [ ] POC-B 실행 시간 기록
- [ ] POC-C 실행 시간 기록
- [ ] POC-D 실행 시간 기록
- [ ] POC-E 실행 시간 기록
- [ ] statdump execute 횟수 기록

### 결과 확인
- [ ] 4개 시나리오 결과 행 수 Before = After (정확성)
- [ ] POC-A, POC-B: After 실행 시간 < Before
- [ ] POC-C, POC-D, POC-E: After 실행 시간 > Before
- [ ] 결과 기록 양식(§7) 채우기

---

## 10. 참고: 선택도별 break-even 지점

push-down이 유리해지는 경계:

```
After 전송 행 = outer_count × avg_match
Before 전송 행 = remote_total

After 유리 조건: outer_count × avg_match < remote_total
→ 평균 매칭 수 < remote_total / outer_count

예) remote 10,000행, outer 10행 → avg_match < 1,000이면 After 유리
    선택도 10% 이하면 After 유리 (전송 행 기준)
    단, execute round-trip latency를 포함하면 실제 임계값은 낮아짐
```

로컬 환경(latency ≈ 0)에서는 round-trip 비용이 작아 After가 더 넓은 범위에서 유리할 수 있다.
WAN 환경에서는 execute 횟수가 더 중요해지므로 POC-C, POC-D 결과가 더 나빠질 가능성이 있다.

---

## 11. 참고: 테이블 스키마 및 데이터 구성

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

### 시나리오별 데이터 규모 요약

| POC | local 테이블 | 행 수 | remote 테이블 | 행 수 | 매칭 |
|-----|------------|------|-------------|------|------|
| A | local_small_t | 10 | remote_large_t | 100,000 | 10건 (0.01%) |
| B | local_nomatch_t | 10 | remote_large_t | 100,000 | 0건 |
| C | local_hiselectivity_t | 100 | remote_hiselectivity_t | 1,000 | 10,000건 (100%) |
| D | local_manyouter_t | 1,000 | remote_smalltable_t | 5 | 5건 |
| E | local_breakeven_t | 10 | remote_breakeven_t | 100,000 | 100,000건 (100%) |
