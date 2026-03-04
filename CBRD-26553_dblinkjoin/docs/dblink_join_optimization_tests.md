# DBLINK 조인 최적화 — TESTS

| 항목 | 내용 |
|------|------|
| 이슈 | CBRD-26553 |
| 관련 문서 | [PRD](dblink_join_optimization_prd.md), [TASKS](dblink_join_optimization_tasks.md), [작업 설명서](dblink_join_optimization_work.md) |

---

## TDD 활용

이 문서의 테스트를 **먼저 정의**하고, 가능하면 **실패하는 테스트를 먼저 작성**한 뒤 구현(T1-1 ~ T3-3)으로 통과시키면 **TDD에 가깝게** 진행할 수 있다.

- **선행 조건**: Step 0·1이 일부라도 반영되어야 “푸시 가능” 쿼리가 식별되므로, TC-1xx(푸시 가능)는 T1 완료 후 본격 검증. TC-2xx(regression)는 기존 동작이므로 구현 전에도 기준선(baseline) 측정 가능.
- **권장**: TC-2xx로 기준선 확보 → TC-1xx 실패 확인 → 구현 → TC-1xx 통과, TC-2xx regression 없음 확인.

---

## 환경 및 데이터

- **환경**: 로컬 DB, 원격 DB(또는 Gateway 경유), dblink 연결 설정.
- **기준 데이터**: 로컬 소량(예: id 1~5), 원격 id별 0건/1건/다건 매칭 혼합.

---

## 테스트 케이스 요약

| ID | PRD | TASK | 구분 | 요약 |
|----|-----|------|------|------|
| TC-101 | FR-7 | T5-1 | 푸시 가능 | WHERE local.id = remote.id 결과 일치 |
| TC-102 | FR-7 | T5-1 | 푸시 가능 | 0건 매칭(inner join) |
| TC-103 | FR-7 | T5-1 | 푸시 가능 | 1:N 매칭 행 수 일치 |
| TC-104 | FR-7 | T5-1 | 푸시 가능 | outer 조인 키가 NULL — execute 스킵, 결과 제외 |
| TC-201 | FR-6, NFR-1 | T5-2 | regression | 푸시 불가 쿼리 기존 동작 |
| TC-202 | FR-6, NFR-1 | T5-2 | regression | 단일 dblink(조인 없음) 기존 동작 |
| TC-203 | NFR-2 | T5-2 | regression | 앱 `?` 있는 predicate 시 조인 키 푸시 미적용·기존 방식 |
| TC-204 | FR-6 | T5-2 | regression | LEFT JOIN(ON 조건) 푸시 미적용·기존 동작 |
| TC-205 | FR-6 | T5-2 | regression | 복합 조인 키(AND) — 1차 미지원, 기존 방식으로 올바른 결과 |
| TC-301 | NFR-3 | T3-2 | 에러 | reset 구간 rebind/execute 실패 시 에러 전파 |
| TC-401 | — | T5-3 | 성능(선택) | 원격 전송 행 수 감소·실행 계획 반영 |
| TC-501 | PRD 3.2 효과1 | T5-3 | 기대 효과 측정 | 원격 전송 행 수 감소 (실행 시간) |
| TC-502 | PRD 3.2 효과2 | T5-3 | 기대 효과 측정 | 로컬 필터 부담 감소 — zero-match (실행 시간) |
| TC-503 | PRD 3.2 효과3 | T5-3 | 기대 효과 측정 | 원격 execute 횟수 변화 (statdump) |
| TC-601 | — | — | worst case | 고선택도: After가 fetch 10배, execute 100배 증가 |
| TC-602 | — | — | worst case | 다수 outer + 소규모 remote: execute round-trip 1,000배 증가 |

---

## 1. 푸시 가능 조인 (FR-7 ↔ T5-1)

### TC-101: 단일 등치 조인 결과 일치

| 항목 | 내용 |
|------|------|
| PRD | FR-7 |
| TASK | T5-1 |
| Given | 로컬 테이블 `local_t(id, a)`, 원격 dblink `remote_t@conn(id, b)`, 동일 id로 1:1 또는 1:N 매칭 가능한 데이터 |
| When | `SELECT ... FROM local_t, remote_t@conn WHERE local_t.id = remote_t.id` (또는 동등한 조인) 실행. 옵티마이저가 dblink를 inner로 선택한 경우. |
| Then | 결과 행 수·값이 **기존 구현**(푸시 없이 전체 fetch 후 로컬 조인)과 **동일**하다. |
| TDD | 푸시 경로 구현 전: 기존 결과를 golden으로 저장. 구현 후: 동일 결과 또는 비교 쿼리로 일치 검증. |

### TC-102: 0건 매칭(inner join)

| 항목 | 내용 |
|------|------|
| PRD | FR-7 |
| TASK | T5-1 |
| Given | 일부 로컬 id에 대해 원격에 매칭 행이 없음 |
| When | inner join 형태로 `WHERE local_t.id = remote_t.id` 푸시 적용된 쿼리 실행 |
| Then | 해당 outer 행은 결과에 나타나지 않으며, 전체 결과 행 수·집합이 기존과 동일하다. |

### TC-103: 1:N 매칭 행 수

| 항목 | 내용 |
|------|------|
| PRD | FR-7 |
| TASK | T5-1 |
| Given | 한 로컬 id에 대해 원격에 여러 행이 매칭됨 |
| When | 푸시 적용된 조인 쿼리 실행 |
| Then | 행 수가 기존(전체 fetch 후 로컬 조인)과 동일하다. |

### TC-104: outer 조인 키가 NULL인 경우

| 항목 | 내용 |
|------|------|
| PRD | FR-7 |
| TASK | T5-1 |
| Given | `local_null_key_t`에 id=NULL 행 포함. 기존 `remote_t` 사용. |
| When | `WHERE l.id = r.id` 푸시 적용 쿼리 실행 |
| Then | Before: NULL = any → false → 결과 제외. After: join_key_regus[0] 평가 결과 NULL → execute 스킵(no_result=true) → S_END. **두 경우 모두 NULL key 행은 결과에 없어야 함.** 총 3행 (id=1: 1행, id=2: 2행). |
| 전제 | `setup_edge_cases_local.sql` (로컬) |

---

## 2. regression·호환성 (FR-6, NFR-1, NFR-2 ↔ T5-2)

### TC-201: 푸시 불가 쿼리

| 항목 | 내용 |
|------|------|
| PRD | FR-6, NFR-1 |
| TASK | T5-2 |
| Given | 조인 조건이 "원격=로컬" 단일 등치가 아니어서 푸시되지 않는 쿼리 (예: 복합 조건, OR, 함수 등) |
| When | 해당 쿼리 실행 |
| Then | **기존과 동일**하게 원격 1회 execute 후 로컬에서 조인 평가. 동작·결과 regression 없음. |

### TC-202: 단일 dblink(조인 없음)

| 항목 | 내용 |
|------|------|
| PRD | FR-6, NFR-1 |
| TASK | T5-2 |
| Given | `SELECT ... FROM remote_t@conn` 처럼 dblink만 있고 로컬 조인 없음 |
| When | 실행 |
| Then | 기존과 동일(1회 execute, fetch). regression 없음. |

### TC-203: 앱 `?` 있을 때 조인 키 푸시 미적용

| 항목 | 내용 |
|------|------|
| PRD | NFR-2, FR-6 |
| TASK | T5-2 |
| Given | 푸시된 predicate에 앱 host 변수(PT_HOST_VAR)가 포함된 쿼리 (예: `remote.col = ?` 에서 앱이 넘기는 `?`) |
| When | 실행 |
| Then | 조인 키 푸시 최적화가 **적용되지 않고** 기존 방식(open에서 bind+execute)으로 동작. 결과는 기존과 동일. |

### TC-204: LEFT JOIN (ON 조건, 푸시 미적용)

| 항목 | 내용 |
|------|------|
| PRD | FR-6 |
| TASK | T5-2 |
| Given | `LEFT JOIN remote_t@conn ON local_t.id = remote_t.id` 등 ON 조건만 있고 WHERE에 동일 등치가 없음 (현재 ON 푸시 미지원) |
| When | 실행 |
| Then | 기존 동작 유지. 푸시 적용되지 않음, regression 없음. |

### TC-205: 복합 조인 키 (AND) — 1차 미지원 경계 검증

| 항목 | 내용 |
|------|------|
| PRD | FR-6 |
| TASK | T5-2 |
| Given | `local_compound_t(id, code)`, `remote_compound_t(id, code)`. id만 같고 code가 다른 행 포함. |
| When | `WHERE l.id = r.id AND l.code = r.code` 실행 |
| Then | push 미적용(기존 방식) 또는 id만 push 후 code 로컬 필터 — 어느 경우든 결과 2행 일치. remote execute count = 1 (push 미적용 확인). |
| 검증 포인트 | id만 매칭되는 행(rc_1C, rc_2D)이 code 조건에 걸려 최종 결과에서 제외되는지 |
| 전제 | `setup_edge_cases_local.sql` (로컬), `setup_edge_cases_remote.sql` (원격) |

---

## 3. 에러 처리 (NFR-3 ↔ T3-2)

### TC-301: reset 구간 rebind/execute 실패

| 항목 | 내용 |
|------|------|
| PRD | NFR-3 |
| TASK | T3-2 |
| Given | outer dependent dblink가 reset 시점에 rebind 후 cci_execute 호출하는 경로 |
| When | rebind 또는 cci_execute가 실패하는 상황(예: 원격 연결 끊김, 타임아웃) |
| Then | 에러가 설정되어 상위로 전파되고, 필요 시 stmt/conn이 정리된다. 클라이언트에는 명확한 오류 응답. |

---

## 4. 성능·동작 (선택, T5-3)

### TC-401: 원격 전송 행 수·실행 계획

| 항목 | 내용 |
|------|------|
| PRD | — |
| TASK | T5-3 |
| Given | 푸시 가능 조인 쿼리, 원격에 많은 행 존재 |
| When | 푸시 적용된 경로로 실행 |
| Then | (선택) 원격으로 전송·수신되는 행 수가 기존(전체 fetch) 대비 감소함. 실행 계획 또는 트레이스에 rebind/execute 반영 여부 확인 가능. |

---

## 5. 기대 효과 측정 (PRD 3.2)

소규모 데이터(7행)로는 측정 불가. 대용량 셋업 후 Before/After 비교로 측정한다.

**전제**: `test/setup_large_data_remote.sql`(원격 DB), `test/setup_large_data_local.sql`(로컬 DB) 실행 완료.
원격: `remote_large_t` 10,000행 (id 1-10,000). 로컬: `local_small_t` 10행 (id 1-10), `local_nomatch_t` 10행 (id 10,001-10,010).

### TC-501: 원격 전송 행 수 감소 (효과 1)

| 항목 | 내용 |
|------|------|
| PRD | PRD 3.2 효과 1 |
| 시나리오 | outer 10행 (id 1-10), remote 10,000행 → 10건 매칭 (선택도 0.1%) |
| Before | remote_large_t 10,000행 전체 fetch → 로컬 predicate → 10행 반환. **전송: 10,000행** |
| After | outer 행마다 1 execute × 1행 반환. **전송: 10행** |
| 측정 | `\timing on` 후 실행 시간 비교 (Before vs After). 결과 행 수 = 10행 (정확성) |
| 기대 | 실행 시간 대폭 감소 (전송 행 수 1/1,000) |

### TC-502: 로컬 필터 부담 감소 — zero-match (효과 2)

| 항목 | 내용 |
|------|------|
| PRD | PRD 3.2 효과 2 |
| 시나리오 | outer 10행 (id 10,001-10,010), remote 10,000행 (id 1-10,000) → **매칭 0건** |
| Before | 10,000행 fetch → outer 10행 × 10,000행 predicate 평가 → 전부 실패. **총 100,000회 로컬 평가** |
| After | 10 execute × 0행 반환 → 즉시 S_END. **로컬 predicate 평가 0회** |
| 측정 | `\timing on` 후 실행 시간 비교. 결과 0행 (정확성) |
| 기대 | 가장 극적인 개선. After는 fetch 자체가 없으므로 거의 즉시 완료 |

### TC-503: 원격 execute 횟수 변화 (효과 3)

| 항목 | 내용 |
|------|------|
| PRD | PRD 3.2 효과 3 |
| 시나리오 | outer 5행 (local_t), remote 7행 (remote_t) — 기존 소규모 데이터 사용 |
| Before | remote_t에서 SELECT **1회** 실행 → cursor reset 5회 |
| After | outer 행마다 execute → remote_t에서 SELECT **5회** 실행 |
| 측정 | 쿼리 전·후 `cubrid statdump -c <remote_db> \| grep Num_query_executions` 비교. delta = Before: 1, After: 5 |
| 기대 | execute 횟수 증가 (1 → 5)하되, 각 execute당 반환 행 수 감소로 총 전송량 감소 |

---

## 6. Worst Case 시나리오

최적화가 **오히려 불리**해지는 조건을 측정한다. 결과 정확성은 동일하지만 실행 시간이 Before보다 증가하는 케이스다.

**핵심 조건**: `outer_count × avg_matching > remote_count` 이거나 `outer_count`가 매우 클 때.

**전제**: `test/setup_worst_case_remote.sql`(원격 DB), `test/setup_worst_case_local.sql`(로컬 DB) 실행 완료.

### TC-601: 고선택도 — fetch 증가 (outer_count × avg_matching >> remote_count)

| 항목 | 내용 |
|------|------|
| 시나리오 | outer 100행 (id 1-10, 10개씩), remote 1,000행 (id 1-10, 100개씩) |
| avg_matching | 100행/outer (선택도 100%) |
| Before | 1 execute + **1,000행 fetch** (전체 1회) + 100,000번 로컬 평가 |
| After | 100 executes + **10,000행 fetch** (Before의 **10배**) + 100회 execute 오버헤드 |
| 측정 | `\timing on` 실행 시간 비교. COUNT = 10,000 (정확성) |
| 시사점 | avg_matching이 높을수록 After가 오히려 더 많은 행을 전송. cost 기반 최적화 적용 판단 근거 |

### TC-602: 다수 outer + 소규모 remote — execute round-trip 오버헤드

| 항목 | 내용 |
|------|------|
| 시나리오 | outer 1,000행 (id 1-1,000), remote 5행 (id 1-5) |
| avg_matching | 0.005행/outer (id 1-5만 매칭, 나머지 995행은 0건) |
| Before | 1 execute + **5행 fetch** + 5,000번 로컬 평가 |
| After | **1,000 executes** (Before의 **1,000배**) + 5행 fetch |
| 측정 | `\timing on` 실행 시간 비교. statdump `Num_query_executions` delta: Before +1, After +1,000. 결과 5행 (정확성) |
| 시사점 | remote가 작아 전체 fetch가 이미 빠를 때, execute round-trip이 지배적 비용이 됨. 고지연 WAN 환경에서 더욱 심각 |

---

## TASKS·실행 순서와의 대응

| 완료 시점 | 검증할 테스트 |
|-----------|----------------|
| T1-1, T1-2 완료 | 푸시 후보 식별·rewritten `?` 반영 단위 검증(필요 시); TC-2xx 기준선 |
| T2-1, T2-2 완료 | TC-203(앱 `?` 미적용) 등 플래그 분기 확인 가능 |
| T3-1, T3-2, T3-3 완료 | TC-101, TC-102, TC-103, TC-201, TC-202, TC-204, TC-301 |
| T5-1, T5-2, T5-3 | TC-1xx, TC-2xx, TC-301, TC-401 정리 실행 |

---

## TC 실행 파일

각 TC에 대응하는 실행 가능 파일은 `CBRD-26553_dblinkjoin/test/` 에 있다.

| TC | 파일 | 비고 |
|----|------|------|
| TC-101 ~ TC-103 | TC-101.sql, TC-102.sql, TC-103.sql | 푸시 가능 조인 |
| TC-201 ~ TC-204 | TC-201.sql ~ TC-204.sql | regression·호환 |
| TC-301 | TC-301.md | 수동/스크립트 검증 (에러 전파) |
| TC-401 | TC-401.sql | 성능(선택) |

실행: 전제 조건 충족 후 `test/run_tc.sh all` 또는 `run_tc.sh TC-101 TC-102` …  
자세한 사용법은 `test/README.md` 참고.

---

## 문서 이력

| 일자 | 작성/수정 | 내용 |
|------|-----------|------|
| TBD | TBD | TESTS 초안 작성 (PRD·TASKS·work 기반, TDD 활용 가이드 포함) |
| TBD | TBD | TC별 실행 파일(TC-101.sql 등) 및 run_tc.sh, test/README.md 추가 |
