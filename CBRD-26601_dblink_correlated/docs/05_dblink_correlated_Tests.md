# DBLink Correlated 서브쿼리 최적화 — Tests

| 항목 | 내용 |
|------|------|
| 이슈 | CBRD-26601 |
| 관련 문서 | [01 소스 분석](01_dblink_correlated_Source_Analysis.md), [02 PRD](02_dblink_correlated_PRD.md), [03 Design Doc](03_dblink_correlated_Desgin_Doc.md), [04 Tasks](04_dblink_correlated_Tasks.md) |

---

## 1. 테스트 개요

- 대상: **SELECT 절 correlated 스칼라 서브쿼리** 안의 DBLink (`remote_t@cubrid_conn`) 최적화.
- 목적:
  - PRD **기능 요구사항** FR-1 ~ FR-8 및 **비기능 요구사항** NFR-1 ~ NFR-3 검증.
  - AS-IS(전체 fetch + 로컬 필터)와 TO-BE(outer 행마다 `WHERE id = ?` 바인딩 후 execute)의 **결과 동등성** 및 **전송량/패턴 차이** 확인.
- 환경:
  - 로컬 DB: `local_t(id INT, name VARCHAR(32))`
  - 원격 DB: `remote_t(id INT, name VARCHAR(32))`
  - DBLink 서버: `cubrid_conn` (`setup_local.sql` 마지막에서 생성)

---

## 2. 환경 셋업

### 2.1 소량 데이터 셋업

- 원격 DB:

```sql
csql -S -u dba <원격DB명> -i test/setup_remote.sql
```

- 로컬 DB:

```sql
csql -S -u dba <로컬DB명> -i test/setup_local.sql
```

### 2.2 대용량 데이터 셋업 (T6-6 / TC-105 용)

- 원격 DB (100,000행):

```sql
csql -S -u dba <원격DB명> -i test/setup_large_remote.sql
```

- 로컬 DB (100행):

```sql
csql -S -u dba <로컬DB명> -i test/setup_large_local.sql
```

> 대용량 셋업은 소량 셋업과 동일 테이블(`remote_t`, `local_t`)을 덮어쓴다.  
> 소량 테스트로 복원하려면 `setup_remote.sql`, `setup_local.sql` 을 다시 실행.

---

## 3. TC 목록 및 PRD/Tasks 매핑

| TC | 시나리오 | 관련 PRD/Design/Tasks | 비고 |
|----|----------|------------------------|------|
| TC-101 | 기본 correlated 스칼라 — 매칭 + NULL 혼합 | FR-1~FR-5, FR-8 / Design 3.1~3.3 / Tasks T1-1, T1-2, T2-1, T3-1/2 / T6-1, T6-2 | 소량 데이터 기준, LIMIT 1 + ORDER BY |
| TC-102 | outer key NULL → 서브쿼리 NULL, re-execute 스킵 | FR-6 / Design 3.5 / Tasks T3-3 / T6-5 | id=NULL 행 임시 추가·삭제 |
| TC-103 | push-down 불가(OR 포함) → 기존 방식 유지 | FR-7 / Design 3.1(보수적 탐지) / Tasks T1-1, T4-1, T6-3 | OR 조건으로 앱 ? 혼합 대체 |
| TC-104 | non-correlated DBLink (상수 WHERE) → 기존 방식 유지 | FR-7 / Design 3.1 / Tasks T1-1, T6-4 | WHERE r.id = 1, outer ref 없음 |
| TC-105 | 대용량 remote/local — 전송 행 수·성능 관찰 | 기대 효과·T6-6 / Design 3.4~3.6 / Tasks T3-1/2, T0-2 | expected 비교 없이 실행 시간/전송량 관찰 |
| TC-106 | FROM 절 correlated dblink 서브쿼리 | 2차 확장 범위(WHERE/SELECT 외 위치) / Design 5.1 참고 | 1차 최적화에서는 AS-IS 유지 검증용 |
| TC-107 | WHERE 절 correlated dblink EXISTS | PRD 4.2 “WHERE 절 correlated 서브쿼리” / Design 3.x 확장 후보 | 1차에서는 최적화 대상 아님, 회귀용 |
| TC-108 | dblink uncorrelated (단독 SELECT) | FR-7, NFR-1: dblink 단독 경로 회귀 | 최적화 전/후 구조·결과 동일 여부 확인 |
| **TC-109** | **outer 중복 키 — 각 행 독립 execute** | Design §3.2 access_pred 제거 검증 | local id=2 중복 3행, 모두 'remote_b1' 반환 확인 |
| **TC-110** | **AND 비상관 LIKE 조건 혼합** | Design §3.2 access_pred 제거 후 비상관 필터 잔존 확인 | correlated 제거 후 LIKE 조건 독립 동작 |
| **TC-111** | **COUNT 집계 서브쿼리** | Design §3.2 access_pred 없이 집계 정확성 | 오매칭 시 COUNT 값으로 버그 감지 가능 |
| **TC-112** | **경계값 outer id (0, negative)** | Design §3.2 오매칭 방지 확인 | remote에 없는 id → NULL 반환 검증 |
| **TC-113** | **LIMIT 없는 서브쿼리 (1:1 케이스)** | Design §3.2 instnum 없이 단일 행 반환 | 1:1 매칭만 사용, 스칼라 에러 없음 확인 |
| **TC-114** | **동일 outer key 다수 + remote N행 — worst case 정합성** | Design §3.2 worst case 정합성 | local id=5 5행, remote id=5 3행, 모두 'remote_e1' |
| **TC-115** | **SELECT 절 복수 correlated 서브쿼리** | Design §3.2 서브쿼리 간 상태 독립성 | 두 서브쿼리 동시 push-down + access_pred 제거 |
| **TC-116** | **AND 비상관 범위 조건 (r.id < 3)** | Design §3.2 비상관 범위 조건 독립 동작 | id=3: r.id=3 NOT < 3 → NULL 확인 |
| **TC-117** | **`use_dblink_corr_pushdown=no` — AS-IS 유지** | FR-9 / Tasks T1-3, T6-7 | 세션 파라미터 OFF 시 push-down 미적용, 결과 TC-101과 동일 확인 |
| **TC-118** | **LIMIT/집계 없음 — 원격 다중 행 반환 → 오류** | Design §3.9 LIMIT append 필요성 | corr 조건 없거나 비선택적 → 원격 다중 행 → 런타임 에러 확인 |
| **TC-119** | **LIMIT/집계 없음 — 원격 1행 반환 → 성공** | Design §3.9 LIMIT append 필요성 | remote.id가 unique key이므로 LIMIT 없이도 1행 보장 → 정상 동작 확인 |
| **TC-120** | **local 추가조건 only — outer WHERE에 local 컬럼 추가필터** | Design §3.2 outer 행 감소 시 execute 횟수 확인 | l.name IN 조건으로 id=1,3,5만 처리 → 3회 execute |
| **TC-121** | **remote 추가조건 only — 조인키 외 remote 컬럼 추가필터 (전체 outer 처리)** | Design §3.2 remote 추가조건 독립 동작 | r.name LIKE 'remote_e%' → id=5만 'remote_e1', 나머지 NULL |
| **TC-122** | **local + remote 추가조건 모두 — outer WHERE + 서브쿼리 WHERE 동시 추가필터** | Design §3.2 복합 조건 정합성 | l.id >= 2 (local) + r.name LIKE 'remote_b%' (remote) 동시 적용 |

---

## 4. TC별 상세

### 4.1 TC-101 — 기본 correlated 스칼라

- 파일: `test/TC-101.sql`
- 전제: `setup_remote.sql`, `setup_local.sql` 선행.
- 쿼리 요약:

```sql
SELECT l.id, l.name,
  (SELECT r.name FROM remote_t@cubrid_conn r
   WHERE r.id = l.id ORDER BY r.name LIMIT 1) AS remote_name
FROM local_t l
ORDER BY l.id;
```

- 기대:
  - 5행.
  - id=4 → remote 매칭 없음 → `remote_name` = NULL.
  - 나머지 id는 `ORDER BY r.name LIMIT 1` 기준 첫 행.
  - 최적화 전/후 결과 **완전히 동일**.

### 4.2 TC-102 — NULL 키

- 파일: `test/TC-102.sql`
- 전제: `setup_remote.sql`, `setup_local.sql` 선행.
- 동작:
  - `local_t`에 `(NULL, 'local_n')` 행 추가 후, id IS NULL 또는 1만 조회.
  - 완료 후 NULL 행 삭제.
- 기대:
  - id=NULL 행 → `remote_name` = NULL (re-execute 스킵).
  - id=1 행 → 정상 매칭.

### 4.3 TC-103 — push-down 불가 (OR)

- 파일: `test/TC-103.sql`
- 전제: `setup_remote.sql`, `setup_local.sql` 선행.
- 쿼리:

```sql
SELECT l.id, l.name,
  (SELECT r.name FROM remote_t@cubrid_conn r
   WHERE r.id = l.id OR r.id = -1
   ORDER BY r.name LIMIT 1) AS remote_name
FROM local_t l
ORDER BY l.id;
```

- 기대:
  - 5행, **TC-101과 결과 동일**.
  - OR 조건으로 인해 correlation 탐지 실패 → `corr_key_count = 0`, 기존 1회 fetch 경로 사용.

### 4.4 TC-104 — non-correlated DBLink

- 파일: `test/TC-104.sql`
- 전제: `setup_remote.sql`, `setup_local.sql` 선행.
- 쿼리:

```sql
SELECT l.id, l.name,
  (SELECT r.name FROM remote_t@cubrid_conn r
   WHERE r.id = 1
   ORDER BY r.name LIMIT 1) AS remote_name
FROM local_t l
ORDER BY l.id;
```

- 기대:
  - 5행, 모든 행에서 `remote_name = 'remote_a1'`.
  - WHERE에 outer 컬럼 없음 → correlated 아님 → push-down 미적용.

### 4.5 TC-105 — 대용량 성능/전송량 관찰

- 파일: `test/TC-105.sql`
- 전제:
  - 원격 DB: `setup_large_remote.sql` (remote_t 100,000행)
  - 로컬 DB: `setup_large_local.sql` (local_t 100행)
- 쿼리:

```sql
SELECT l.id, l.name,
  (SELECT r.name FROM remote_t@cubrid_conn r
   WHERE r.id = l.id
   ORDER BY r.name LIMIT 1) AS remote_name
FROM local_t l
ORDER BY l.id;
```

- 기대:
  - 결과 행 수: 100행.
  - AS-IS: 원격에서 **100회 execute**, 매회 100,000행 전송 → 총 10,000,000행 (conn_sql에 WHERE 없음).
  - TO-BE: id 1~100에 대해 **100회 execute**, 각 최대 100행씩 전송 → 총 최대 10,000행 (WHERE 조건으로 필터).
  - 실제 실행 시간/네트워크 전송량 비교는 `./run_tc.sh --no-compare TC-105` 또는 별도 프로파일링으로 수행.

### 4.6 TC-108 — dblink uncorrelated (단독 SELECT)

- 파일: `test/TC-108.sql`
- 전제: 원격 DB에 `setup_remote.sql` 선행.
- 쿼리:

```sql
SELECT id, name
FROM remote_t@cubrid_conn
ORDER BY id, name;
```

- 기대:
  - remote_t 의 전체 행(7행)이 id, name 순으로 반환.
  - 로컬 테이블/outer ref 가 전혀 없으므로 correlated 최적화와 무관해야 하며,
    - 최적화 전/후 `conn_sql`, XASL, 실행 패턴 등에서 dblink 단독 경로에 **회귀가 없어야 함**.

### 4.7 TC-109 — outer 중복 키

- 파일: `test/TC-109.sql`
- 전제: `setup_remote.sql`, `setup_local.sql` 선행.
- 동작: `local_t`에 `id=2` 행 2개 임시 추가 → 동일 outer key 3행 생성 후 쿼리 실행, 이후 삭제.
- 검증 포인트: access_pred(`r.id = l.id`) 제거 상태에서 outer 행마다 독립 execute가 수행되고 각각 올바른 결과 반환.
- 기대: 3행(`local_2`, `local_2b`, `local_2c`), 모두 `remote_name = 'remote_b1'`.

### 4.8 TC-110 — AND 비상관 LIKE 조건 혼합

- 파일: `test/TC-110.sql`
- 전제: `setup_remote.sql`, `setup_local.sql` 선행.
- 쿼리: `WHERE r.id = l.id AND r.name LIKE 'remote_b%'`
- 검증 포인트: correlated 조건(`r.id = l.id`)만 제거/대체한 뒤, 비상관 조건(`LIKE 'remote_b%'`)이 올바르게 남아 필터링되는지 확인.
- 기대: id=2 → `'remote_b1'`, 나머지 모두 NULL.

### 4.9 TC-111 — COUNT 집계 서브쿼리

- 파일: `test/TC-111.sql`
- 전제: `setup_remote.sql`, `setup_local.sql` 선행.
- 쿼리: `(SELECT COUNT(*) FROM remote_t@cubrid_conn r WHERE r.id = l.id)`
- 검증 포인트: access_pred 제거 후 remote가 올바른 행만 수신하고 COUNT가 정확한지 확인. 오매칭 행이 있으면 COUNT가 기대보다 커져 버그 감지 가능.
- 기대: id=1→1, id=2→2, id=3→1, id=4→0, id=5→3.

### 4.10 TC-112 — 경계값 outer id (0, negative)

- 파일: `test/TC-112.sql`
- 전제: `setup_remote.sql`, `setup_local.sql` 선행.
- 동작: `local_t`에 `id=0`, `id=-1` 행 임시 추가 후 서브쿼리 실행, 이후 삭제.
- 검증 포인트: access_pred 제거 후에도 remote가 올바르게 0행을 반환하여 결과가 NULL인지 확인. 오매칭 행이 있으면 NULL 대신 값이 나와 버그 감지 가능.
- 기대: 2행(`id=-1`, `id=0`), 모두 `remote_name = NULL`.

### 4.11 TC-113 — LIMIT 없는 서브쿼리 (1:1 케이스)

- 파일: `test/TC-113.sql`
- 전제: `setup_remote.sql`, `setup_local.sql` 선행.
- 쿼리: LIMIT 없는 correlated 서브쿼리, outer id를 1:1 매칭(`id IN (1, 3)`)으로 제한.
- 검증 포인트: instnum 없이 remote 필터만으로 단일 행을 반환하는지 확인. access_pred 제거 후 스칼라 서브쿼리 오류 없이 정확히 1행 반환.
- 기대: id=1 → `'remote_a1'`, id=3 → `'remote_c1'`.
- 비고: 1:N 케이스(id=2, id=5)는 LIMIT 없는 스칼라 서브쿼리에서 에러이므로 제외.

### 4.12 TC-114 — 동일 outer key 다수 + remote N행 (worst case 정합성)

- 파일: `test/TC-114.sql`
- 전제: `setup_remote.sql`, `setup_local.sql` 선행.
- 동작: `local_t`에 `id=5` 행 4개 임시 추가 → 5행. `remote_t`에 `id=5`는 3행. 쿼리 실행 후 삭제.
- 검증 포인트: outer 5행 × remote 3행 수신 → instnum(LIMIT 1)으로 1건 취득. access_pred 제거 후 5행 모두 동일하게 올바른 결과 반환. 오매칭 또는 상태 오염 시 NULL이거나 다른 값이 나와 버그 감지 가능.
- 기대: 5행(`local_5` ~ `local_5e`), 모두 `remote_name = 'remote_e1'`.

### 4.13 TC-115 — SELECT 절 복수 correlated 서브쿼리

- 파일: `test/TC-115.sql`
- 전제: `setup_remote.sql`, `setup_local.sql` 선행.
- 쿼리: 같은 SELECT 절에 correlated DBLink 서브쿼리 두 개(LIMIT 1 서브쿼리 + COUNT 서브쿼리).
- 검증 포인트: 각 서브쿼리가 독립적으로 push-down 및 access_pred 제거를 적용하는지, 서브쿼리 간 상태 오염(공유 리스트·바인딩 혼선 등) 없이 각자 올바른 결과를 반환하는지 확인.
- 기대: id=1→(`'remote_a1'`, 1), id=2→(`'remote_b1'`, 2), id=3→(`'remote_c1'`, 1), id=4→(NULL, 0), id=5→(`'remote_e1'`, 3).

### 4.14 TC-116 — AND 비상관 범위 조건

- 파일: `test/TC-116.sql`
- 전제: `setup_remote.sql`, `setup_local.sql` 선행.
- 쿼리: `WHERE r.id = l.id AND r.id < 3`
- 검증 포인트: correlated 조건(`r.id = l.id`)만 제거한 뒤 비상관 범위 조건(`r.id < 3`)이 독립적으로 올바르게 동작하는지 확인. id=3은 `r.id = l.id = 3`이지만 `r.id < 3` 불만족 → NULL이어야 함. 비상관 조건이 제거되었거나 잘못 처리되면 id=3에 `'remote_c1'`이 나와 버그 감지 가능.
- 기대: id=1→`'remote_a1'`, id=2→`'remote_b1'`, id=3→NULL, id=4→NULL, id=5→NULL.

### 4.16 TC-118 — LIMIT/집계 없음, 원격 다중 행 → 오류

- 파일: `test/TC-118.sql`
- 전제: `setup_remote.sql`, `setup_local.sql` 선행.
- 쿼리:
  1. correlated 조건 없이 `remote_t` 전체 반환 → 다중 행 에러
  2. 범위 조건(`r.id >= l.id`)으로 다중 행 반환 → 다중 행 에러
- 검증 포인트: LIMIT/집계 없이 원격에서 2행 이상이 반환되면 스칼라 서브쿼리 에러가 발생함을 확인. AS-IS/TO-BE 모두 동일하게 에러.
- 기대: 두 쿼리 모두 런타임 에러 (`more than 1 row returned by a subquery`).

### 4.17 TC-119 — LIMIT/집계 없음, 원격 1행 보장 → 성공

- 파일: `test/TC-119.sql`
- 전제: `setup_remote.sql`, `setup_local.sql` 선행.
- 쿼리: `WHERE r.id = l.id` — LIMIT 없음, 집계 없음.
- 검증 포인트: `remote_t.id`가 unique key이므로 correlated 조건이 항상 최대 1행을 반환한다. LIMIT 없이도 데이터 구조상 스칼라 에러가 발생하지 않음을 확인. push-down 적용 시에도 `conn_sql = 'SELECT name, id FROM remote_t WHERE id = ?'`로 1행 반환.
- 기대: 5행, TC-101과 동일 값 (id=4 → NULL, 나머지 → 해당 remote name).

### 4.15 TC-117 — `use_dblink_corr_pushdown=no` (AS-IS 유지)

- 파일: `test/TC-117.sql`
- 전제: `setup_remote.sql`, `setup_local.sql` 선행.
- 동작: 세션 파라미터 `use_dblink_corr_pushdown=no` 설정 → correlated 서브쿼리 실행 → `yes`로 복원.
- 검증 포인트:
  - 파라미터 OFF 시 push-down이 적용되지 않아야 함 (`conn_sql`에 `WHERE id = ?` 없음, N회 실행 경로 유지).
  - 결과는 TC-101과 **완전히 동일** (push-down 여부와 무관하게 정확성 유지).
  - 파라미터 복원 후 재실행 시 push-down이 다시 적용됨.
- 기대: 각 쿼리 모두 5행, TC-101과 동일 값.

### 4.18 TC-120 — local 추가조건 only

- 파일: `test/TC-120.sql`
- 전제: `setup_remote.sql`, `setup_local.sql` 선행.
- 쿼리: `FROM local_t l WHERE l.name IN ('local_1', 'local_3', 'local_5')`
  - 서브쿼리: `WHERE r.id = l.id ORDER BY r.name LIMIT 1` (조인키만, remote 추가조건 없음)
- 검증 포인트: outer WHERE에 local 컬럼 추가조건이 있어도 push-down 탐지에 영향 없음을 확인. id=2,4는 outer 단계에서 제외되어 서브쿼리 execute 대상에서 제외됨.
- 기대: 3행. id=1→`'remote_a1'`, id=3→`'remote_c1'`, id=5→`'remote_e1'`.

### 4.19 TC-121 — remote 추가조건 only (전체 outer 처리)

- 파일: `test/TC-121.sql`
- 전제: `setup_remote.sql`, `setup_local.sql` 선행.
- 쿼리: `WHERE r.id = l.id AND r.name LIKE 'remote_e%'`
  - outer 필터 없음 — 전체 5행 처리.
- 검증 포인트: TC-110(`LIKE 'remote_b%'`), TC-116(`r.id < 3`)과 보완 관계. 조인키와 다른 컬럼(`r.name`)에 LIKE 추가조건이 있을 때 각 outer 행마다 remote 추가조건이 독립적으로 올바르게 적용되는지 확인.
- 기대: 5행. id=5→`'remote_e1'`, 나머지 모두 NULL.

### 4.20 TC-122 — local + remote 추가조건 모두

- 파일: `test/TC-122.sql`
- 전제: `setup_remote.sql`, `setup_local.sql` 선행.
- 쿼리:
  - outer: `WHERE l.id >= 2` (local 추가조건 — id=1 제외)
  - 서브쿼리: `WHERE r.id = l.id AND r.name LIKE 'remote_b%'` (remote 추가조건)
- 검증 포인트: local 필터(TC-120)와 remote 필터(TC-121)가 동시에 적용되어도 각각 독립적으로 올바르게 동작하는지 확인. push-down 시 outer 4회 execute, 각 회차에서 remote 추가조건도 정확히 처리.
- 기대: 4행. id=2→`'remote_b1'`, id=3→NULL, id=4→NULL, id=5→NULL.

---

## 5. 실행 방법 요약

### 5.1 기능/정합성 TC 실행

```bash
cd CBRD-26601_dblink_correlated/test

# TC-101~104 모두 실행 + expected 비교
./run_tc.sh all

# 특정 TC만
./run_tc.sh TC-101
./run_tc.sh TC-102
```

정답지가 없으면 `--gen-expected` 옵션으로 최초 정답을 생성한 뒤, 이후부터 diff 기반 회귀 테스트에 사용한다.

### 5.2 XASL / 런타임 확인

```bash
# TC-101 XASL 덤프 (xasl_debug_dump=on/off 자동 래핑)
./run_tc.sh --xasl TC-101
```

상세 gdb/XASL 디버깅은 `test/debug.sql` 의 주석과 쿼리를 참고한다.

### 5.3 대용량 케이스 (TC-105)

```bash
cd CBRD-26601_dblink_correlated/test

# 대용량 셋업 후 TC-105 실행 (비교 없이 실행만)
./run_tc.sh --no-compare TC-105
```

실행 전후로 원격/로컬 셋업 파일을 관리하여 소량/대용량 환경을 전환한다.

### 5.4 dblink 단독 경로 (TC-108)

```bash
cd CBRD-26601_dblink_correlated/test

# dblink 단독 SELECT 회귀 확인 (정답 비교는 필요 시 --gen-expected 로 생성)
./run_tc.sh TC-108
```

TC-108은 correlated 최적화와 무관한 **기본 dblink 경로**가 깨지지 않는지 확인하기 위한 회귀용 테스트이다.

