# CBRD-26553 DBLINK 조인 최적화

이슈 **CBRD-26553** (dblink 조인 키 푸시 최적화) 관련 문서·테스트·자료의 진입점이다.

---

## 1. 문서 (docs)

상세 문서는 [docs/](docs/) 폴더에 있다. 바로 열 수 있는 링크만 정리한다.

### 1.1 DBLINK 조인 최적화

| 문서 | 설명 |
|------|------|
| [docs/dblink_join_optimization_summary.md](docs/dblink_join_optimization_summary.md) | 한 줄 요약, 현재 vs 목표 |
| [docs/dblink_join_optimization_prd.md](docs/dblink_join_optimization_prd.md) | PRD (제품 요구사항) |
| [docs/dblink_join_optimization_work.md](docs/dblink_join_optimization_work.md) | 작업 설명서 (목적, 기대 효과, 상세) |
| [docs/dblink_join_optimization_plan.md](docs/dblink_join_optimization_plan.md) | 상세 구현 계획 (단계, 자료 구조) |
| [docs/dblink_join_optimization_tasks.md](docs/dblink_join_optimization_tasks.md) | TASKS (태스크·PRD 매핑, 의존 관계) |
| [docs/dblink_join_optimization_tests.md](docs/dblink_join_optimization_tests.md) | TESTS (테스트 케이스, TDD 활용) |

### 1.2 Regular Variable(REGU) 코드 분석

| 문서 | 설명 |
|------|------|
| [docs/regu_var_code_analysis.md](docs/regu_var_code_analysis.md) | Regular variable 코드 분석서 (역할, 구조, 다이어그램) |
| [docs/regu_var_example_queries.md](docs/regu_var_example_queries.md) | REGU 종류별 예제 SQL (스키마 링크 포함) |
| [docs/regu_var_example_schema.sql](docs/regu_var_example_schema.sql) | 예제 실행용 테이블·데이터·SP 생성 스크립트 |

---

## 2. 테스트 (test)

DBLINK 조인 최적화 기능을 검증하는 실행 가능한 테스트들이 들어 있는 폴더다.

### 2.1 역할

- PRD·[TESTS 문서](docs/dblink_join_optimization_tests.md)에 정의된 테스트 케이스를 **실행 가능한 SQL/스크립트**로 둠.
- 푸시 가능(TC-1xx), 회귀(TC-2xx), reset/rebind(TC-3xx), 성능/실행계획(TC-4xx) 등을 실행·비교해 동작을 검증.

### 2.2 전제 조건

- **로컬 DB·원격 DB 생성 및 서버 시작:** `test/test_setup_dblink_databases.sh`
- **원격·로컬 스키마·데이터 적재:** `test/test_run_dblink_join.sh`  
  (또는 원격에 `test_dblink_join_remote.sql`, 로컬에 `test_dblink_join_local.sql` 실행)
- dblink 서버 이름 `cubrid_conn` (로컬 스크립트에서 생성)

### 2.3 주요 파일

| 파일 | 설명 |
|------|------|
| [test/README.md](test/README.md) | 테스트 폴더 사용법, TC 목록, 실행 방법 |
| [test/expected_results.md](test/expected_results.md) | 각 TC 기대 행 수·결과 집합 정리 (정답지 참고) |
| [test/run_tc.sh](test/run_tc.sh) | TC 실행·정답지(TC-xxx.expected)와 비교 |
| test/TC-101.sql ~ TC-401.sql | 테스트 쿼리 (TC-301은 .md로 수동 검증) |
| test/TC-101.expected ~ TC-401.expected | 정답지 (run_tc.sh 비교용) |

### 2.4 TC 요약

| TC | 설명 | 기대 |
|----|------|------|
| TC-101 | 단일 등치 조인 결과 일치 (FR-7) | 7행 |
| TC-102 | 0건 매칭 inner join (FR-7) | 7행 (id=4 없음) |
| TC-103 | 1:N 매칭 행 수 (FR-7) | 7행 |
| TC-201 | 푸시 불가 쿼리 (FR-6, NFR-1) | 7행, regression 없음 |
| TC-202 | 단일 dblink 조인 없음 (FR-6) | 원격 전체 7행 |
| TC-203 | 앱 ? 시 푸시 미적용 (NFR-2) | 7행 기준선 |
| TC-204 | LEFT JOIN ON (FR-6) | 8행, 기존 동작 |
| TC-301 | reset 시 rebind/execute (NFR-3) | 수동·스크립트 검증 |
| TC-401 | 성능·실행 계획 (선택) | 선택 검증 |

### 2.5 실행 예시

```bash
cd test

# 전체 TC 실행 후 정답지와 비교 (불일치 시 [FAIL] 및 diff)
./run_tc.sh all

# 지정 TC만 실행·비교
./run_tc.sh TC-101 TC-102

# 비교 없이 실행만
./run_tc.sh --no-compare all
```

- 환경 변수: `CUBRID_DBLINK_LOCAL_DB`(로컬 DB명, 기본 `testdb`), `CSQL_OPTS`(예: `-u user -p pass`).
