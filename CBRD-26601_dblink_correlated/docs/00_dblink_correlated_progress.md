# CBRD-26601 — DBLink Correlated 최적화 작업 진행서

> 목적: 구현/문서/테스트 진행 상황을 한 파일에서 추적한다.  
> 원칙: **작업 단위가 끝날 때마다** 아래 “진행 로그”에 1~3줄로 업데이트한다.

## 0) 문서 트리(권장 읽기 순서)

- [01 소스 분석](01_dblink_correlated_Source_Analysis.md)
- [02 PRD](02_dblink_correlated_PRD.md)
- [03 Design Doc](03_dblink_correlated_Desgin_Doc.md)
- [04 Tasks](04_dblink_correlated_Tasks.md)
- [05 Tests](05_dblink_correlated_Tests.md)
- [06 Guide](06_dblink_correlated_Guide.md)

---

## 1) 목표(Phase 1)

- **범위**: SELECT 절 correlated 스칼라 서브쿼리 안의 DBLink
- **핵심 변화**:
  - correlation 키(`remote.col = outer.col`)를 탐지
  - 원격 `conn_sql`을 `WHERE col = ?` 형태로 만들고
  - outer 행마다 값을 bind + execute 하도록 런타임 경로를 확장

---

## 2) 변경 사항 요약(코드)

> 아래는 “변경이 끝난 뒤” 확인용. 작업 중에는 진행 로그에 더 자세히 적는다.

### 완료됨

- **T0-2 (구조체/직렬화)** — commit `5ed355f35`:
  - `src/query/xasl.h`: `dblink_spec_node`에 `corr_key_count`, `corr_key_regu_list` 추가
  - `src/query/dblink_scan.h`: `DBLINK_SCAN_INFO`에 `corr_key_*` 추가(전방 선언/typedef 포함)
  - `src/query/xasl_to_stream.c`: dblink spec pack/sizeof에 corr 필드 반영
  - `src/query/stream_to_xasl.c`: dblink spec unpack에 corr 필드 반영
  - `src/parser/xasl_generation.c`: dblink spec 생성 시 corr 필드 기본값 초기화(0/NULL)

- **T1-1 (탐지, view_transform)** — commit `1cefbb3b3` / `PT_DBLINK_INFO` 저장·`conn_sql`은 T1-2:
  - `src/parser/view_transform.c`: `mq_detect_dblink_corr_eq()` 및 헬퍼(호스트 변수·OR/NOT/서브쿼리 실패, 상관 등치 1개·등식 교환·보수적 AND 규칙)
  - `mq_rewrite_dblink_as_subquery()`에서 DBLink spec 처리 시 호출; 반환값 `ncorr == 1`일 때만 Phase 1 적용(T1-2와 연동)

- **T1-2 (`PT_DBLINK_INFO`·원격 `rewritten`)** — commit `4934574ec` · bugfix `2186bd830` / [04 Tasks §T1-2 유의 5](04_dblink_correlated_Tasks.md), 구현: `view_transform.c`·`view_transform.h`
  - **메타만** — `mq_rewrite_dblink_as_subquery`: `ncorr==1` 직후 `mq_dblink_extract_col_name`으로 컬럼명 복사본 저장(`corr_key_col_names[0]`).
  - **혼합** — `pt_copypush_terms` `PT_DBLINK_TABLE` 분기에서 `rewritten` 할당 직후 `mq_dblink_append_corr_pred_sql(parser, di)`.
  - **순수 상관** — `pt_to_dblink_table_spec_list`: `rewritten==NULL && corr_key_count>0`이면 동일 함수(`xasl_generation.c`).
  - `mq_dblink_append_corr_pred_sql` / `mq_dblink_clear_corr_keys` **extern** (`view_transform.h`).
  - **버그픽스**: `corr_key_remote_cols[0]`이 가리키는 PT_NAME 노드가 view 확장(`mq_translate_local`) 단계에서 in-place 수정됨 → `original` 필드가 덮어써져 컬럼명 소실(`where = ?` 증상). 탐지 직후 `pt_append_string(parser, NULL, original)`로 독립 복사본을 `corr_key_col_names[0]`에 저장하는 방식으로 수정. `parse_tree.h`에 `corr_key_col_names[PT_DBLINK_MAX_CORR_KEYS]` 필드 추가.
  - **outer 상관 컬럼 스냅샷**: `corr_key_outer_refs[]`도 비소유라 이후 transform 후 주소/노드 타입이 무효화될 수 있음. `ncorr==1`·`corr_key_col_names[0]` 성공 직후 `parser_copy_tree(parser, corr_key_outer_refs[0])`로 `corr_key_outer_copy[0]`에 소유 복사본 저장. `mq_dblink_clear_corr_keys(parser, di)`에서 `parser_free_tree`로 해제. XASL 성공 경로에서는 해제하지 않음 — 파스 트리/문 수명 동안 유지(`pt_to_regu_variable` 결과가 copy 서브트리를 참조할 수 있음). `parse_tree.h`·`view_transform.c`·`xasl_generation.c` 주석 반영.

- **T1-3 (세션 파라미터 `use_dblink_corr_pushdown`, FR-9)** — commit `0f3bb3b6f`:
  - `src/base/system_parameter.h` / `system_parameter.c`: `PRM_ID_USE_DBLINK_CORR_PUSHDOWN`, 이름 `use_dblink_corr_pushdown`, `PRM_BOOLEAN` 기본값 `yes`, 플래그 `PRM_FOR_CLIENT | PRM_USER_CHANGE | PRM_FOR_SESSION | PRM_FOR_QRY_STRING` (플랜/쿼리 문자열 반영).
  - `src/parser/view_transform.c`: `mq_rewrite_dblink_as_subquery`에서 `prm_get_bool_value(PRM_ID_USE_DBLINK_CORR_PUSHDOWN)`가 false이면 `mq_detect_dblink_corr_eq` 및 `corr_key_*` 메타 기록 전체 스킵 — `pt_copypush_terms` / T2-1 append 경로로 이어지지 않음(AS-IS). `#include "system_parameter.h"` 추가.

- **T2-1 (XASL `dblink_spec_node` corr 필드, `xasl_generation.c`)** — commit `e064a4603` · bugfix `4908707e0`:
  - `pt_to_dblink_table_spec_list`: HOST_VAR 검사·`corr_key_outer_copy[0]`로 `pt_to_regu_variable` → `corr_key_regu_list`(이전: 비소유 `corr_key_outer_refs[0]` 직접 사용); 실패 시 `mq_dblink_clear_corr_keys(parser, pdblink)` + `pt_reset_error` + `has_internal_error=0`.
  - `mq_dblink_append_corr_pred_sql`(순수 상관)·`pt_make_dblink_access_spec` 이후 `dblink_node.corr_key_*` 반영.

- **T3-1 (런타임 open — FR-4, prepare만)** — commit `5024fe120` / `dblink_scan.c`, `query_executor.c`:
  - `dblink_open_scan`: `cci_prepare` 성공 후 `spec->s.dblink_node`의 `corr_key_count`, `corr_key_regu_list`를 `DBLINK_SCAN_INFO`로 복사. `corr_key_count > 0`이면 `col_info=NULL`, `col_cnt=0`, `cursor=CCI_CURSOR_FIRST`로 반환 — `cci_execute`·호스트 `dblink_bind_param`·`cci_get_result_info` 생략.
  - `query_executor.c` `scan_open_scan` 분기 `TARGET_DBLINK`: `corr_key_count <= 0`일 때만 `val_list->val_cnt`와 `scan_info.col_cnt` 일치 검사(상관 push 시 open 직후 `col_cnt` 미확정).
  - 테스트 문서: [05 Tests §5.5](05_dblink_correlated_Tests.md) T3 gdb·최소 SQL.

- **T3-2 (런타임 rebind + execute — FR-5)** — commit `5024fe120` / `dblink_scan.c`, `scan_manager.c`:
  - `dblink_bind_one_param`: 단일 `DB_VALUE` → `cci_bind_param` (기존 `dblink_bind_param` 루프에서 재사용).
  - `dblink_scan_reset(thread_p, scan_info, vd)`: `corr_key_count>0`이면 `corr_key_regu_list`에 대해 `fetch_peek_dbval` → `dblink_bind_one_param` → `cci_execute` → `col_info` 없으면 `cci_get_result_info`.
  - `scan_reset_scan_block` `S_DBLINK_SCAN`: `dblink_scan_reset(thread_p, …, s_id->vd)`.
  - `scan_next_dblink_scan`: `corr_key_count>0 && col_info==NULL`이면 첫 `dblink_scan_next` 전에 reset 호출(첫 outer 행에서도 메타·결과 준비).
  - 다음: **T3-3**(NULL 키 시 execute 스킵 등).

---

## 3) 진행 로그 (최신이 위)

> 형식 예시:  
> `YYYY-MM-DD` — (태스크) 무엇을 했는지 / 영향 / 다음 액션

- 2026-03-25 — (**T3-2**) `dblink_bind_one_param` / `dblink_scan_reset(thread_p,…,vd)`(fetch_peek_dbval+corr bind+execute+get_result_info), `scan_manager` reset·`scan_next_dblink_scan` 첫 fetch 보강. 다음: **T3-3** NULL 키.
- 2026-03-25 — (**T3-1**) `dblink_open_scan` prepare-only 분기·`query_executor.c` TARGET_DBLINK 컬럼 수 검사 완화·[05 §5.5](05_dblink_correlated_Tests.md).
- 2026-03-24 — (T1-2/T2-1) 상관 **outer** 컬럼도 비소유 `corr_key_outer_refs`만으로는 XASL 단계에서 노드가 무효화될 수 있어, 탐지 직후 `corr_key_outer_copy[0] = parser_copy_tree(...)` 저장. `mq_dblink_clear_corr_keys(parser, di)` 시그니처에 `parser` 추가·`parser_free_tree`로 copy 해제. `pt_to_dblink_table_spec_list`는 `corr_key_outer_copy[0]`만 사용; 성공 시에는 clear 호출 안 함(파스 트리 수명). `parse_tree.h`/`view_transform.c`/`xasl_generation.c` 주석.
- 2026-03-24 — (T2-1) `pt_to_dblink_table_spec_list` 재구현: HOST_VAR·pred/rest 매칭·폴백·`has_internal_error` 클리어. [04 Tasks](04_dblink_correlated_Tasks.md) Step 2 완료. 다음: T3-1 등.
- 2026-03-24 — (T1-3) `use_dblink_corr_pushdown` 세션 파라미터 추가(`system_parameter.h/c`, 기본 `yes`, `PRM_FOR_QRY_STRING`). `mq_rewrite_dblink_as_subquery`에서 OFF 시 상관 탐지·`corr_key_*` 메타 스킵. [04 Tasks](04_dblink_correlated_Tasks.md) T1-3 완료.
- 2026-03-24 — (버그픽스) `corr_key_remote_cols[0]` PT_NAME 노드가 view 확장 중 in-place 수정(`original`→"cubrid.local_t")되어 `where = ?` 오류 발생. `parse_tree.h`에 `corr_key_col_names[]` 추가, 탐지 직후 `pt_append_string` 복사본 저장, `mq_dblink_append_corr_pred_sql(parser, di)` API에서 `remote_col` 파라미터 제거. `mq_dblink_print_remote_col` → `mq_dblink_extract_col_name`으로 대체.
- 2026-03-24 — (코드) §T1-2 유의 5 반영: `pt_copypush_terms(PT_DBLINK_TABLE)`에서 `rewritten` 할당 직후 `mq_dblink_append_corr_pred_sql`; `pt_to_dblink_table_spec_list`에서 `rewritten==NULL && corr_key_count>0` 시 동일; `mq_translate` post-walk 제거. `mq_dblink_append_corr_pred_sql`/`mq_dblink_clear_corr_keys`를 `view_transform.h`에 노출.
- 2026-03-24 — (문서) §T1-2 유의 5: **메타만** / **`pt_copypush_terms` 직후** / **T2-1(`rewritten==NULL`)** — [04 Tasks](04_dblink_correlated_Tasks.md)·Design Doc §3.1.
- 2026-03-20 — (T1-1) `view_transform.c`에 `mq_detect_dblink_corr_eq()` 구현·`mq_rewrite_dblink_as_subquery` 연동. Tasks T1-1 완료 체크, [04 Tasks](04_dblink_correlated_Tasks.md) 문서 이력 반영. 다음: T1-2(`PT_DBLINK_INFO`, `conn_sql`).
- 2026-03-20 — (문서) Tasks §T1-1 설계 결정·T1-1/T1-2 경계·등식 교환; Design Doc §1.1/§3.1 동기; `docs/*.md` 상호 링크를 최신 파일명(`02_*_PRD` 등)으로 통일; `04_dblink_correlated_optimization_tasks.md`는 [04 Tasks](04_dblink_correlated_Tasks.md) 스텁으로 정리.
- 2026-03-20 — (T1-2 전) `mq_detect_dblink_corr_eq`: 저장 버퍼 초과 시 -1; `PT_DBLINK_INFO.corr_key_*`는 비소유 참조라 `pt_apply_dblink_table` 미포함 — `parse_tree.h`/진행서 §4/Tasks T1-2 주석 반영.
- 2026-03-19 — (T0-2) `corr_key_count`/`corr_key_regu_list` 필드 추가 및 XASL pack/unpack 반영 완료. 다음: T1-1 탐지 구현 착수.
- 2026-03-19 — (T0-1) C-1~C-5 확인 결과를 Tasks 문서에 정리 완료. 다음: T0-2 진행.

---

## 4) 함수 변경 목록

> **신규** = 이 기능에서 새로 추가된 함수 / **수정** = 기존 함수에 corr push-down 로직 추가

### T0-2 — XASL 직렬화 (`xasl_to_stream.c`, `stream_to_xasl.c`, `xasl_generation.c`)

| 파일 | scope | 구분 | 함수 | 설명 |
|------|-------|------|------|------|
| `xasl_to_stream.c` | static | 수정 | `xts_process_dblink_spec_type` | `corr_key_count` + `corr_key_regu_list` offset pack |
| `xasl_to_stream.c` | static | 수정 | `xts_sizeof_dblink_spec_type` | sizeof에 corr 필드 크기 반영 |
| `stream_to_xasl.c` | static | 수정 | `stx_build_dblink_spec_type` | `corr_key_count` + `corr_key_regu_list` unpack |
| `xasl_generation.c` | static | 수정 | `pt_make_dblink_access_spec` | 신규 corr 필드 `0/NULL` 초기화 |

### T1-1 — 상관 등치 탐지 (`view_transform.c`)

| 파일 | scope | 구분 | 함수 | 설명 |
|------|-------|------|------|------|
| `view_transform.c` | static | 신규 | `mq_dblink_corr_strip_cast` | cast 래퍼 제거 헬퍼 (등치 양측 대칭 strip) |
| `view_transform.c` | static | 신규 | `mq_dblink_term_scan_pre` | CNF AND-term 내 pre-walk — outer ref·금지 패턴 감지 |
| `view_transform.c` | static | 신규 | `mq_dblink_term_scan_post` | CNF AND-term 내 post-walk — `remote.col = outer.col` 등치 확인 |
| `view_transform.c` | static | 신규 | `mq_detect_dblink_corr_eq` | WHERE CNF 단위 상관 등치 탐지; 반환 값(count or -1), 배열 채우기 겸용 |
| `view_transform.c` | static | 수정 | `mq_rewrite_dblink_as_subquery` | `mq_detect_dblink_corr_eq` 호출·`corr_key_*` 메타 저장 추가 |

### T1-2 — corr pred SQL append (`view_transform.c`, `xasl_generation.c`)

| 파일 | scope | 구분 | 함수 | 설명 |
|------|-------|------|------|------|
| `view_transform.c` | extern | 신규 | `mq_dblink_clear_corr_keys(parser, dinfo)` | 푸시다운 포기 시 슬롯 초기화; `corr_key_outer_copy[]` `parser_free_tree` 해제 |
| `view_transform.c` | static | 신규 | `mq_dblink_sql_has_where_keyword` | SQL 문자열 내 WHERE 키워드 word-boundary 유무 판별 |
| `view_transform.c` | static | 신규 | `mq_dblink_extract_col_name` | 탐지 시점에 PT_NAME/PT_DOT 노드에서 컬럼명 복사(`pt_append_string`) |
| `view_transform.c` | static | 신규 | `mq_dblink_build_rewritten_base_sql` | `rewritten==NULL` 시 `qstr`에서 베이스 VARCHAR 빌드 |
| `view_transform.c` | extern | 신규 | `mq_dblink_append_corr_pred_sql` | `rewritten`에 `WHERE col = ?` 또는 `AND col = ?` append |
| `view_transform.c` | static | 수정 | `mq_rewrite_dblink_as_subquery` | `corr_key_col_names[0]` 저장; `corr_key_outer_copy[0]` `parser_copy_tree` 추가 |
| `view_transform.c` | static | 수정 | `pt_copypush_terms` | `PT_DBLINK_TABLE` 분기에서 `rewritten` 확정 직후 `mq_dblink_append_corr_pred_sql` 호출 |
| `xasl_generation.c` | static | 수정 | `pt_to_dblink_table_spec_list` | `rewritten==NULL && corr_key_count>0` 시 `mq_dblink_append_corr_pred_sql` 호출 |

### T1-3 — 세션 파라미터 (`view_transform.c`, `system_parameter.c/h`)

| 파일 | scope | 구분 | 함수 | 설명 |
|------|-------|------|------|------|
| `view_transform.c` | static | 수정 | `mq_rewrite_dblink_as_subquery` | `prm_get_bool_value(PRM_ID_USE_DBLINK_CORR_PUSHDOWN)` guard 추가 |

### T2-1 — XASL gen corr 필드 세팅 (`xasl_generation.c`)

| 파일 | scope | 구분 | 함수 | 설명 |
|------|-------|------|------|------|
| `xasl_generation.c` | static | 수정 | `pt_to_dblink_table_spec_list` | HOST_VAR 검사·`corr_key_outer_copy[0]`→`pt_to_regu_variable`→`corr_key_regu_list` 빌드; `dblink_node.corr_key_*` 세팅 |

### T3-1 — DBLink 런타임 open (`dblink_scan.c`, `query_executor.c`)

| 파일 | scope | 구분 | 함수 | 설명 |
|------|-------|------|------|------|
| `dblink_scan.c` | extern | 수정 | `dblink_open_scan` | `corr_key_count>0` 시 prepare만·`corr_key_*` scan_info 복사·조기 반환; 그 외 기존 bind+execute+`get_result_info` |
| `query_executor.c` | — | 수정 | `scan_open_scan` 내 `TARGET_DBLINK` 분기 | `corr_key_count<=0`일 때만 `val_list->val_cnt` vs `scan_info.col_cnt` 검사 |

### T3-2 — corr rebind + execute (`dblink_scan.c`, `scan_manager.c`)

| 파일 | scope | 구분 | 함수 | 설명 |
|------|-------|------|------|------|
| `dblink_scan.c` | static | 신규 | `dblink_bind_one_param` | 단일 `DB_VALUE` → CCI bind |
| `dblink_scan.c` | static | 수정 | `dblink_bind_param` | host var 루프에서 `dblink_bind_one_param` 호출 |
| `dblink_scan.c` | extern | 수정 | `dblink_scan_reset` | `corr_key_count>0`: `fetch_peek_dbval`+bind+execute+`get_result_info`; 그 외 cursor만 |
| `scan_manager.c` | — | 수정 | `scan_reset_scan_block` / `scan_next_dblink_scan` | `dblink_scan_reset(thread_p,…,vd)`; 첫 next 전 `col_info` 보강 |

---

## 5) 결정/가정 기록 (Decision Log)

- **Plan A/B**: `pt_to_dblink_table_spec_list` 경로 진입이 불가한 경우, `pt_to_subquery_table_spec_list`에서 corr 필드 채움/조건 제거(플랜 B).
- **직렬화 함수명**: pack=`xts_save_regu_variable_list`, unpack=`stx_restore_regu_variable_list`.
- **T1-1 탐지(Phase 1)**: 상관 등치 1개만 성공, `l.id = r.id` 교환 허용; AND 비상관 추가 허용; 복합 상관 등치·outer 참조 비등치 비교·OR 등은 실패. 상세는 [04 Tasks §T1-1](04_dblink_correlated_Tasks.md).
- **`mq_detect_dblink_corr_eq` 버퍼·반환**: `remote_cols_out`/`outer_cols_out`/`max_keys`로 저장 시 등치 개수가 `max_keys`를 넘으면 **-1** (부분 채움 없음). detect-only는 `NULL,NULL,0`.
- **`PT_DBLINK_INFO.corr_key_*` 트리 연동**: `corr_key_remote_cols`/`corr_key_outer_refs`는 WHERE와 **동일 노드 비소유** 포인터이므로 **`pt_apply_dblink_table`에 넣지 않음** (복사 시 노드 이중 생성·해제 시 이중 free 위험). **`corr_key_outer_copy`**는 탐지 직후 `parser_copy_tree`로 만든 **소유** 트리이나, 여전히 dblink 노드 밖의 독립 복사본이므로 `pt_apply_dblink_table`에는 넣지 않는다(일반 parse-tree walk와 중복 walk 방지). 해제는 `mq_dblink_clear_corr_keys`에서만.
- **`corr_key_col_names[]` 안정성**: `corr_key_remote_cols[0]`이 가리키는 PT_NAME 노드는 view 확장(`mq_translate_local`) 중 `info.name.original` 포인터 필드가 교체(in-place 확장 또는 재할당)될 수 있음. `pt_append_string(parser, NULL, original)`로 탐지 직후 독립 복사본을 만들어 `corr_key_col_names[0]`에 저장; 이 복사 문자열은 parser pool에 단독 할당되어 이후 어떤 extend도 영향 없음.
- **`corr_key_outer_copy[]` 안정성·수명**: `corr_key_outer_refs[]`는 부모 WHERE의 비소유 포인터로, 이후 transform으로 같은 주소가 다른 노드 타입으로 재사용되거나 무효화될 수 있음. 탐지 직후 `parser_copy_tree`로 `corr_key_outer_copy[]`에 소유 복사본을 둔다. `mq_dblink_clear_corr_keys`는 푸시다운 **포기** 시에만 호출해 copy를 `parser_free_tree`한다. **XASL 성공 경로에서는 clear하지 않음** — `pt_to_regu_variable` 결과 regu가 copy 서브트리를 참조할 수 있으며, 노드는 파스 트리/문 해제 시점까지 유지한다.
- **T1-2 `conn_sql`/`rewritten` append 순서(고정)**: `mq_rewrite_dblink_as_subquery`에서는 **메타만**. `rewritten`이 **`pt_copypush_terms`에서 확정**되면 그 할당 **직후** `mq_dblink_append_corr_pred_sql`. **`rewritten == NULL`**이면 **T2-1**에서 append. `mq_dblink_append_corr_pred_sql` 공용 호출을 위해 **헤더 노출 또는 헬퍼 이동**이 필요할 수 있음. 상세는 [04 Tasks §T1-2 유의 5](04_dblink_correlated_Tasks.md).
- **FR-9 / T1-3 `use_dblink_corr_pushdown`**: 세션 파라미터 기본 `yes`. `no`이면 `mq_rewrite_dblink_as_subquery`에서 탐지·메타를 건너뛰어 correlated push-down 경로 미진입(AS-IS). `PRM_FOR_QRY_STRING`으로 플랜 캐시와 정합.
- **T3-1 / `col_info` 지연**: 상관 push(`corr_key_count>0`) 시 open에서는 `cci_get_result_info`를 호출하지 않음. 결과 컬럼 메타는 **T3-2**에서 첫 `cci_execute` 직후(또는 동등 경로) 채우는 전제. 참고: `dblink_join_improve` 브랜치의 `join_key_*` 패턴과 동일.
- **T3-1 / query_executor**: open 직후 `scan_info.col_cnt==0`이 정상이므로 `TARGET_DBLINK`에서 `corr_key_count>0`이면 val_list 대비 컬럼 개수 검증을 하지 않음.

