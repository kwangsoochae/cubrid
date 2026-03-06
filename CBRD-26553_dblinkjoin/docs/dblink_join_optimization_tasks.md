# DBLINK 조인 최적화 — TASKS

| 항목 | 내용 |
|------|------|
| 이슈 | CBRD-26553 |
| 관련 문서 | [PRD](dblink_join_optimization_prd.md), [요약](dblink_join_optimization_summary.md), [작업 설명서](dblink_join_optimization_work.md), [구현 계획](dblink_join_optimization_plan.md), [T0-1 검증](T0-1_verification.md) |

**의존 관계**: Step 1 → Step 2 → Step 3. Step 0은 병렬 가능. Step 4는 2·3과 병행. Step 5는 3 완료 후.

### PRD 요구사항 매핑

| PRD 요구사항 | 대응 태스크 |
|--------------|-------------|
| FR-1 푸시 후보 식별·원격에 `?` 반영 | T1-1, T1-2 |
| FR-3 `join_key_count > 0` 분기 조건 (PT_HOST_VAR 시 join_key_count = 0 유지) | T2-1 |
| FR-4 open 시 prepare만·spec→scan_info 복사 | T3-1 |
| FR-5 reset 시 vd rebind 후 execute·시그니처 변경 | T3-2 |
| FR-6 푸시 불가/앱 `?` 기존 방식·regression 없음 | T2-1/T2-2 설계, T5-2 검증 |
| FR-7 푸시 조인 결과 = 기존 결과 | T5-1 |
| NFR-1 기존 경로 호환 유지 | T3-1/T3-2 분기, T5-2 |
| NFR-2 불명확 시 기존 방식 유지 | T1-1 조건, T5-2 |
| NFR-3 rebind/execute 실패 시 에러 전파·정리 | T3-2 |

---

## Step 0: 사전 확인 및 인프라

| ID | 작업 | 파일/위치 | 완료 |
|----|------|-----------|:----:|
| T0-1 | "원격 컬럼 = 로컬 컬럼" 조건이 correlated로 제외되는지 `view_transform.c`에서 코드로 확인 | `src/parser/view_transform.c`, `pt_check_pushable_term()` | [x] |
| T0-2 | `xasl.h`의 `dblink_node`에 `host_var_count`, `host_var_index` 등 확인; `join_key_count` (int), `join_key_regu_list` (REGU_VARIABLE_LIST) 추가, 직렬화/역직렬화 반영 | `src/query/xasl.h`, `xasl_to_stream.c`, `stream_to_xasl.c` | [x] |

---

## Step 1: 푸시 조건 식별 (Parser / View transform)

| ID | 작업 | 파일/위치 | 완료 |
|----|------|-----------|:----:|
| T1-1 | "원격 컬럼 = 로컬 컬럼" 등치를 푸시 허용: `pt_find_dblink_side_refs`, `pt_is_dblink_join_key_equality` 추가, `pt_check_pushable_term()`에서 예외 처리 | `src/parser/view_transform.c` | [ ] |
| T1-2 | 푸시 시 rewritten에 `remote.col = ?` 반영, `PT_DBLINK_INFO`에 `join_key_local_ref_count`, `join_key_local_refs` 추가 및 매핑 | `src/parser/parse_tree.h`, `view_transform.c` `pt_copypush_terms()` | [ ] |

---

## Step 2: XASL에 반영

| ID | 작업 | 파일/위치 | 완료 |
|----|------|-----------|:----:|
| T2-1 | `join_key_local_ref_count > 0`이고 PT_HOST_VAR 없을 때 `join_key_count`, `join_key_regu_list` 채우기; `conn_sql`에 푸시된 WHERE 포함 (`join_key_count > 0`이 이후 open/reset 분기 조건) | `src/parser/xasl_generation.c` `pt_to_dblink_table_spec_list()` | [ ] |

---

## Step 3: 실행기 (Open / Reset / Next)

| ID | 작업 | 파일/위치 | 완료 |
|----|------|-----------|:----:|
| T3-1 | Open: spec에서 `join_key_count`, `join_key_regu_list`를 scan_info에 복사; `join_key_count > 0`이면 `cci_prepare`만, execute는 생략 | `src/query/dblink_scan.c` `dblink_open_scan()`, `dblink_scan.h` `DBLINK_SCAN_INFO` | [ ] |
| T3-2 | Reset: `dblink_scan_reset(scan_info, vd)` 시그니처 변경; 호출부에서 vd 전달; outer dependent이면 vd로 `dblink_bind_param` 후 `cci_execute`. 실패 시 에러 설정·상위 전파, 필요 시 stmt/conn 정리 (NFR-3) | `dblink_scan.c`, `scan_manager.c` `scan_reset_scan_block()` | [ ] |
| T3-3 | Next: 푸시된 경우 fetch 경로 유지, 로컬 predicate 평가는 일단 유지 (추후 스킵 검토) | `src/query/scan_manager.c` `scan_next_dblink_scan()` | [ ] |

---

## Step 4: 플랜·스펙 검증

| ID | 작업 | 파일/위치 | 완료 |
|----|------|-----------|:----:|
| T4-1 | NL inner dblink 스펙에 `join_key_count`, `join_key_regu_list` 유지 여부 확인; `scan_open_dblink_scan` 호출 경로에서 `join_key_regus[i]->value.dbvalptr`가 outer val_list 엔트리를 가리키는지 확인 | `scan_manager.c`, `query_executor.c` | [ ] |

---

## Step 5: 테스트·검증

| ID | 작업 | 설명 | 완료 |
|----|------|------|:----:|
| T5-1 | 푸시 가능 조인 | `WHERE local.id = remote.id` 등 결과 행 수·값이 기존(전체 fetch 후 로컬 조인)과 동일한지 | [ ] |
| T5-2 | 푸시 불가 / 단일 dblink | regression 없음 확인 | [ ] |
| T5-3 | Gateway 경유 (선택) | 원격 전송 행 수 감소, 실행 계획 반영 여부 | [ ] |

---

## 완료 체크리스트 (Step별)

- [ ] **Step 0** — T0-1, T0-2
- [ ] **Step 1** — T1-1, T1-2 (빌드·기존 테스트 통과)
- [ ] **Step 2** — T2-1
- [ ] **Step 3** — T3-1, T3-2, T3-3
- [ ] **Step 4** — T4-1
- [ ] **Step 5** — T5-1, T5-2(, T5-3)

---

## 문서 이력

| 일자 | 작성/수정 | 내용 |
|------|-----------|------|
| TBD | TBD | TASKS 초안 작성 (plan/work 기반) |
