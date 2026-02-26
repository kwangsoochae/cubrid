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
| TC-201 | FR-6, NFR-1 | T5-2 | regression | 푸시 불가 쿼리 기존 동작 |
| TC-202 | FR-6, NFR-1 | T5-2 | regression | 단일 dblink(조인 없음) 기존 동작 |
| TC-203 | NFR-2 | T5-2 | regression | 앱 `?` 있는 predicate 시 조인 키 푸시 미적용·기존 방식 |
| TC-204 | FR-6 | T5-2 | regression | LEFT JOIN(ON 조건) 푸시 미적용·기존 동작 |
| TC-301 | NFR-3 | T3-2 | 에러 | reset 구간 rebind/execute 실패 시 에러 전파 |
| TC-401 | — | T5-3 | 성능(선택) | 원격 전송 행 수 감소·실행 계획 반영 |

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
