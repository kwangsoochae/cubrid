# DBLINK 조인 최적화 — 테스트 (TC)

PRD·TESTS 문서의 테스트 케이스를 실행 가능한 파일로 둔 디렉터리입니다.

## 전제 조건

- 로컬 DB·원격 DB 생성 및 서버 시작: `./test_setup_dblink_databases.sh`
- 원격·로컬 스키마·데이터 적재: `./test_run_dblink_join.sh` (또는 원격에 `test_dblink_join_remote.sql`, 로컬에 `test_dblink_join_local.sql` 실행)
- dblink 서버 이름 `cubrid_conn` (로컬 스크립트에서 생성됨)

### TC-501, TC-502, TC-503 추가 전제 (기대 효과 측정용)

대용량 데이터 셋업 필요 (TC-101~TC-401과 별도):
```bash
csql -u cubrid -p cubrid <remote_db> -i setup_large_data_remote.sql
csql -u cubrid -p cubrid <local_db>  -i setup_large_data_local.sql
```

### TC-104, TC-205 추가 전제 (edge case 검증용)

```bash
csql -u cubrid -p cubrid <local_db>  -i setup_edge_cases_local.sql
csql -u cubrid -p cubrid <remote_db> -i setup_edge_cases_remote.sql  # TC-205만 필요
```

### TC-601, TC-602 추가 전제 (worst case 측정용)

```bash
csql -u cubrid -p cubrid <remote_db> -i setup_worst_case_remote.sql
csql -u cubrid -p cubrid <local_db>  -i setup_worst_case_local.sql
```

## TC 파일

| 파일 | 설명 | 기대 |
|------|------|------|
| TC-101.sql | 단일 등치 조인 결과 일치 (FR-7) | 7행 |
| TC-102.sql | 0건 매칭(inner join) (FR-7) | id=4 없음, 7행 |
| TC-103.sql | 1:N 매칭 행 수 (FR-7) | 7행 |
| TC-201.sql | 푸시 불가 쿼리 (FR-6, NFR-1) | 7행, regression 없음 |
| TC-202.sql | 단일 dblink 조인 없음 (FR-6) | 원격 전체 7행 |
| TC-203.sql | 앱 ? 시 푸시 미적용 (NFR-2) | 앱 바인딩으로 별도 검증, 여기서는 7행 기준선 |
| TC-204.sql | LEFT JOIN ON (FR-6) | 8행, 기존 동작 |
| TC-205.sql | 복합 조인 키(AND) — 1차 미지원 regression | 2행 |
| TC-301.md | reset 시 rebind/execute 실패 (NFR-3) | 수동·스크립트 검증 |
| TC-104.sql | NULL 조인 키 — execute 스킵, 결과 제외 | 3행 |
| TC-401.sql | 성능·실행 계획 (선택) | 선택 검증 |
| TC-501.sql | 원격 전송 행 수 감소 (PRD 3.2 효과1) | 10행, 실행 시간 비교 |
| TC-502.sql | 로컬 필터 부담 감소, zero-match (PRD 3.2 효과2) | 0행, 실행 시간 비교 |
| TC-503.sql | 원격 execute 횟수 (PRD 3.2 효과3) | 7행, statdump 비교 |
| TC-601.sql | Worst case: 고선택도 (fetch 10배 증가) | COUNT=10000, 실행 시간 After≥Before |
| TC-602.sql | Worst case: 다수 outer + 소규모 remote (execute 1,000배) | 5행, 실행 시간 After>>Before |

정답지(비교용): `TC-101.expected` ~ `TC-401.expected` (TC-301 제외). `run_tc.sh` 실행 시 자동 비교.

## 실행

```bash
# 전체 TC 실행 후 각 정답지(TC-xxx.expected)와 비교. 불일치 시 [FAIL] 및 diff 출력
./run_tc.sh all

# 지정 TC만 실행·비교
./run_tc.sh TC-101 TC-102

# 비교 없이 실행만 (정답지 미비교)
./run_tc.sh --no-compare all
```

- **정답지**: 각 TC마다 `TC-101.expected`, `TC-102.expected` 등이 있으면 실행 결과의 Result 블록과 diff로 비교한다. 정답지가 없으면 비교만 생략한다.
- 환경 변수: `CUBRID_DBLINK_LOCAL_DB`(로컬 DB명, 기본 `testdb`), `CSQL_OPTS`(예: `-u user -p pass`).

## 정답지 (Expected Results)

`expected_results.md` 에 각 TC의 기대 행 수와 결과 집합을 정리해 두었음.  
`./run_tc.sh all` 실행 후 출력과 비교해 regression 검증 시 참고.

## 참고

- [docs/dblink_join_optimization_tests.md](../docs/dblink_join_optimization_tests.md) — 테스트 케이스 상세
- [docs/dblink_join_optimization_prd.md](../docs/dblink_join_optimization_prd.md) — 요구사항
