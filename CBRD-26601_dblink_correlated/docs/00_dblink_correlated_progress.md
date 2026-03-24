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

- **T0-2 (구조체/직렬화)**:
  - `src/query/xasl.h`: `dblink_spec_node`에 `corr_key_count`, `corr_key_regu_list` 추가
  - `src/query/dblink_scan.h`: `DBLINK_SCAN_INFO`에 `corr_key_*` 추가(전방 선언/typedef 포함)
  - `src/query/xasl_to_stream.c`: dblink spec pack/sizeof에 corr 필드 반영
  - `src/query/stream_to_xasl.c`: dblink spec unpack에 corr 필드 반영
  - `src/parser/xasl_generation.c`: dblink spec 생성 시 corr 필드 기본값 초기화(0/NULL)

- **T1-1 (탐지, view_transform)** — `PT_DBLINK_INFO` 저장·`conn_sql`은 T1-2:
  - `src/parser/view_transform.c`: `mq_detect_dblink_corr_eq()` 및 헬퍼(호스트 변수·OR/NOT/서브쿼리 실패, 상관 등치 1개·등식 교환·보수적 AND 규칙)
  - `mq_rewrite_dblink_as_subquery()`에서 DBLink spec 처리 시 호출; 반환값 `ncorr == 1`일 때만 Phase 1 적용(T1-2와 연동)

- **T1-2 (`PT_DBLINK_INFO`·원격 `rewritten`)** — [04 Tasks §T1-2 유의 5](04_dblink_correlated_Tasks.md), 구현: `view_transform.c`·`view_transform.h`
  - **메타만** — `mq_rewrite_dblink_as_subquery`: `ncorr==1` 직후 `mq_dblink_extract_col_name`으로 컬럼명 복사본 저장(`corr_key_col_names[0]`).
  - **혼합** — `pt_copypush_terms` `PT_DBLINK_TABLE` 분기에서 `rewritten` 할당 직후 `mq_dblink_append_corr_pred_sql(parser, di)`.
  - **순수 상관** — `pt_to_dblink_table_spec_list`: `rewritten==NULL && corr_key_count>0`이면 동일 함수(`xasl_generation.c`).
  - `mq_dblink_append_corr_pred_sql` / `mq_dblink_clear_corr_keys` **extern** (`view_transform.h`).
  - **버그픽스**: `corr_key_remote_cols[0]`이 가리키는 PT_NAME 노드가 view 확장(`mq_translate_local`) 단계에서 in-place 수정됨 → `original` 필드가 덮어써져 컬럼명 소실(`where = ?` 증상). 탐지 직후 `pt_append_string(parser, NULL, original)`로 독립 복사본을 `corr_key_col_names[0]`에 저장하는 방식으로 수정. `parse_tree.h`에 `corr_key_col_names[PT_DBLINK_MAX_CORR_KEYS]` 필드 추가.

---

## 3) 진행 로그 (최신이 위)

> 형식 예시:  
> `YYYY-MM-DD` — (태스크) 무엇을 했는지 / 영향 / 다음 액션

- 2026-03-24 — (버그픽스) `corr_key_remote_cols[0]` PT_NAME 노드가 view 확장 중 in-place 수정(`original`→"cubrid.local_t")되어 `where = ?` 오류 발생. `parse_tree.h`에 `corr_key_col_names[]` 추가, 탐지 직후 `pt_append_string` 복사본 저장, `mq_dblink_append_corr_pred_sql(parser, di)` API에서 `remote_col` 파라미터 제거. `mq_dblink_print_remote_col` → `mq_dblink_extract_col_name`으로 대체.
- 2026-03-24 — (코드) §T1-2 유의 5 반영: `pt_copypush_terms(PT_DBLINK_TABLE)`에서 `rewritten` 할당 직후 `mq_dblink_append_corr_pred_sql`; `pt_to_dblink_table_spec_list`에서 `rewritten==NULL && corr_key_count>0` 시 동일; `mq_translate` post-walk 제거. `mq_dblink_append_corr_pred_sql`/`mq_dblink_clear_corr_keys`를 `view_transform.h`에 노출.
- 2026-03-24 — (문서) §T1-2 유의 5: **메타만** / **`pt_copypush_terms` 직후** / **T2-1(`rewritten==NULL`)** — [04 Tasks](04_dblink_correlated_Tasks.md)·Design Doc §3.1.
- 2026-03-20 — (T1-1) `view_transform.c`에 `mq_detect_dblink_corr_eq()` 구현·`mq_rewrite_dblink_as_subquery` 연동. Tasks T1-1 완료 체크, [04 Tasks](04_dblink_correlated_Tasks.md) 문서 이력 반영. 다음: T1-2(`PT_DBLINK_INFO`, `conn_sql`).
- 2026-03-20 — (문서) Tasks §T1-1 설계 결정·T1-1/T1-2 경계·등식 교환; Design Doc §1.1/§3.1 동기; `docs/*.md` 상호 링크를 최신 파일명(`02_*_PRD` 등)으로 통일; `04_dblink_correlated_optimization_tasks.md`는 [04 Tasks](04_dblink_correlated_Tasks.md) 스텁으로 정리.
- 2026-03-20 — (T1-2 전) `mq_detect_dblink_corr_eq`: 저장 버퍼 초과 시 -1; `PT_DBLINK_INFO.corr_key_*`는 비소유 참조라 `pt_apply_dblink_table` 미포함 — `parse_tree.h`/진행서 §4/Tasks T1-2 주석 반영.
- 2026-03-19 — (T0-2) `corr_key_count`/`corr_key_regu_list` 필드 추가 및 XASL pack/unpack 반영 완료. 다음: T1-1 탐지 구현 착수.
- 2026-03-19 — (T0-1) C-1~C-5 확인 결과를 Tasks 문서에 정리 완료. 다음: T0-2 진행.

---

## 4) 신규 추가 함수 목록

> 이 기능에서 **새로 추가**된 함수만 기록. 기존 함수 수정(`mq_rewrite_dblink_as_subquery`, `pt_copypush_terms` 등)은 제외.
> 형식: `파일:라인` — `scope 반환형 함수명(…)` — 한 줄 설명

### T1-1 — 상관 등치 탐지 (`view_transform.c`)

| 라인 | scope | 함수 | 설명 |
|------|-------|------|------|
| 6615 | static | `mq_dblink_corr_strip_cast` | cast 래퍼 제거 헬퍼 (등치 양측 대칭 strip) |
| 6723 | static | `mq_dblink_term_scan_pre` | CNF AND-term 내 pre-walk — outer ref·금지 패턴 감지 |
| 6771 | static | `mq_dblink_term_scan_post` | CNF AND-term 내 post-walk — `remote.col = outer.col` 등치 확인 |
| 6794 | static | `mq_detect_dblink_corr_eq` | WHERE CNF 단위 상관 등치 탐지; 반환 값(count or -1), 배열 채우기 겸용 |

### T1-2 — corr pred SQL append (`view_transform.c`, extern 2개는 `view_transform.h` 노출)

| 라인 | scope | 함수 | 설명 |
|------|-------|------|------|
| 6859 | **extern** | `mq_dblink_clear_corr_keys` | `PT_DBLINK_INFO.corr_key_*` 슬롯 초기화 (`col_names` 포함) |
| 6874 | static | `mq_dblink_sql_has_where_keyword` | SQL 문자열 내 WHERE 키워드 word-boundary 유무 판별 |
| 6921 | static | `mq_dblink_extract_col_name` | 탐지 시점에 PT_NAME/PT_DOT_ 노드에서 컬럼명 복사(`pt_append_string`) — 이후 transform 영향 없음 |
| 6952 | static | `mq_dblink_build_rewritten_base_sql` | `rewritten==NULL` 시 `qstr`에서 베이스 VARCHAR 빌드 |
| 6977 | **extern** | `mq_dblink_append_corr_pred_sql` | `rewritten`에 `WHERE col = ?` 또는 `AND col = ?` append; `di->corr_key_col_names[0]` 사용 (파라미터에서 `remote_col` 제거) |

---

## 5) 결정/가정 기록 (Decision Log)

- **Plan A/B**: `pt_to_dblink_table_spec_list` 경로 진입이 불가한 경우, `pt_to_subquery_table_spec_list`에서 corr 필드 채움/조건 제거(플랜 B).
- **직렬화 함수명**: pack=`xts_save_regu_variable_list`, unpack=`stx_restore_regu_variable_list`.
- **T1-1 탐지(Phase 1)**: 상관 등치 1개만 성공, `l.id = r.id` 교환 허용; AND 비상관 추가 허용; 복합 상관 등치·outer 참조 비등치 비교·OR 등은 실패. 상세는 [04 Tasks §T1-1](04_dblink_correlated_Tasks.md).
- **`mq_detect_dblink_corr_eq` 버퍼·반환**: `remote_cols_out`/`outer_cols_out`/`max_keys`로 저장 시 등치 개수가 `max_keys`를 넘으면 **-1** (부분 채움 없음). detect-only는 `NULL,NULL,0`.
- **`PT_DBLINK_INFO.corr_key_*` 트리 연동**: WHERE와 **동일 노드 비소유** 포인터이므로 **`pt_apply_dblink_table`에 넣지 않음** (복사 시 노드 이중 생성·해제 시 이중 free 위험). `parser_copy_tree` 등 이후에는 슬롯 비우거나 탐지 재실행.
- **`corr_key_col_names[]` 안정성**: `corr_key_remote_cols[0]`이 가리키는 PT_NAME 노드는 view 확장(`mq_translate_local`) 중 `info.name.original` 포인터 필드가 교체(in-place 확장 또는 재할당)될 수 있음. `pt_append_string(parser, NULL, original)`로 탐지 직후 독립 복사본을 만들어 `corr_key_col_names[0]`에 저장; 이 복사 문자열은 parser pool에 단독 할당되어 이후 어떤 extend도 영향 없음.
- **T1-2 `conn_sql`/`rewritten` append 순서(고정)**: `mq_rewrite_dblink_as_subquery`에서는 **메타만**. `rewritten`이 **`pt_copypush_terms`에서 확정**되면 그 할당 **직후** `mq_dblink_append_corr_pred_sql`. **`rewritten == NULL`**이면 **T2-1**에서 append. `mq_dblink_append_corr_pred_sql` 공용 호출을 위해 **헤더 노출 또는 헬퍼 이동**이 필요할 수 있음. 상세는 [04 Tasks §T1-2 유의 5](04_dblink_correlated_Tasks.md).

