# DBLINK 조인 최적화 — 작업 요약

| 항목 | 내용 |
|------|------|
| 이슈 | CBRD-26553 |
| 관련 문서 | [TASKS](dblink_join_optimization_tasks.md), [PRD](dblink_join_optimization_prd.md), [구현 계획](dblink_join_optimization_plan.md), [T0-1 검증](T0-1_verification.md) |

이 문서는 CBRD-26553 DBLINK 조인 키 푸시 최적화 작업의 **구현 요약**을 담는다. 완료된 태스크별로 변경 파일·내용·빌드 결과를 정리한다.

---

## Step 0: 사전 확인 및 인프라

### T0-1 (완료)

**목표**: "원격 컬럼 = 로컬 컬럼" 조건이 푸시에서 제외되는지 `view_transform.c`에서 코드로 확인.

**결과**:
- 해당 조건은 **푸시 대상에서 제외됨**.
- 제외 경로는 `correlated_found`가 아니라 **`PT_PUSHABLE_TERM`의 `!others_found`** (로컬 컬럼이 others_spec_list에 있어 `others_found = true`).
- 상세: [T0-1_verification.md](T0-1_verification.md).

**코드 변경**: 없음 (검증만 수행).

---

### T0-2 (완료)

**목표**: `xasl.h`의 dblink 스펙에 `join_key_count`, `join_key_regu_list` 추가 및 직렬화/역직렬화 반영.

**변경 파일**:

| 파일 | 변경 내용 |
|------|-----------|
| `src/query/xasl.h` | `dblink_spec_node`에 `int join_key_count`, `REGU_VARIABLE_LIST join_key_regu_list` 추가 |
| `src/parser/xasl_generation.c` | `pt_make_dblink_access_spec()`에서 `join_key_count = 0`, `join_key_regu_list = NULL` 초기화 |
| `src/query/xasl_to_stream.c` | `xts_process_dblink_spec_type`에 join_key_count·join_key_regu_list 패킹, `xts_sizeof_dblink_spec_type`에 크기 반영 |
| `src/query/stream_to_xasl.c` | `stx_build_dblink_spec_type`에 join_key_count·join_key_regu_list 언패킹 |

**빌드**: `cubrid` 타깃 성공.

---

### T0-3 (완료)

**목표**: inner 판별 인프라. dblink가 NL/IDX join **inner**일 때만 `join_key_count` 설정 및 `rewritten` SQL 사용. dblink가 outer/hash/merge일 때는 `join_key_count = 0` 유지, `qstr`(원본) 사용으로 unbound `?` 방지.

**변경 파일**:

| 파일 | 변경 내용 |
|------|-----------|
| `src/parser/parse_tree.h` | `PARSER_CONTEXT.flag`에 `unsigned is_generating_dblink_inner_scan:1` 추가 (이미 완료) |
| `src/query/query_executor.c` | `dblink` open 시 `join_key_count <= 0`일 때만 `val_list->val_cnt != col_cnt` 검사 (이미 완료) |
| `src/optimizer/plan_generation.c` | `gen_inner()` case QO_PLANTYPE_SCAN: spec이 `PT_DERIVED_DBLINK_TABLE`일 때 `init_class_scan_proc` 호출 전후 `is_generating_dblink_inner_scan` set/clear |
| `src/parser/xasl_generation.c` | `pt_to_dblink_table_spec_list()`에 두 가지 guard: (1) `join_key_count` 설정을 `is_generating_dblink_inner_scan == 1`일 때만, (2) `conn_sql` 선택을 `is_generating_dblink_inner_scan == 1`일 때만 `rewritten` 사용(아니면 `qstr`) |

**효과**:

| dblink 위치 | 플래그 | join_key_count | conn_sql | 동작 |
|------------|--------|----------------|----------|------|
| NL/IDX join inner | 1 | 설정됨 | rewritten | push-down 적용 ✓ |
| NL/IDX join outer | 0 | 0 유지 | qstr | AS-IS fallback ✓ |
| Hash/Merge join | 0 | 0 유지 | qstr | AS-IS fallback ✓ |
| 단일 dblink (join 없음) | 0 | 0 유지 | qstr | AS-IS ✓ |

**참고**: T4-3(rewrite 건너뛰기) 적용 전에는 dblink spec이 `PT_IS_SUBQUERY`로 남아 있어 T0-3 guard는 실제로 거의 타지 않음. T4-3 적용 후 의미 있게 동작.

**빌드**: `cubrid` 타깃 성공.

---

## Step 1: 푸시 조건 식별 (Parser / View transform)

### T1-1 (완료)

**목표**: "원격 컬럼 = 로컬 컬럼" 단일 등치를 푸시 **허용**. `pt_find_dblink_side_refs`, `pt_is_dblink_join_key_equality` 추가, `pt_check_pushable_term()`에서 예외 처리.

**변경 파일**: `src/parser/view_transform.c`

**추가·변경 내용**:

1. **구조체 `PT_DBLINK_SIDE_REFS`**
   - 한쪽 서브트리 참조 분류용: `dblink_spec_id`, `others_spec_list`, `has_dblink_ref`, `has_outer_ref`, `has_others`.

2. **`pt_find_dblink_side_refs_walk()`**
   - 서브트리 leaf walk 콜백.
   - `PT_NAME`: spec_id가 dblink → `has_dblink_ref`, others_spec_list → `has_outer_ref`, 그 외 → `has_others`.
   - `PT_SELECT`, `PT_METHOD_CALL`, `PT_UNION`, rownum/inst_num/orderby_num/groupby_num 등 → `has_others`.
   - `PT_HOST_VAR` (앱 `?` 바인드 변수) → `has_others` (조인 키 푸시와 혼합하지 않음, PRD FR-6).

3. **`pt_find_dblink_side_refs()`**
   - 주어진 노드 서브트리에 대해 walk 수행 후 `has_dblink_ref` / `has_outer_ref` / `has_others` 설정.

4. **`pt_is_dblink_join_key_equality()`**
   - `term`이 `PT_EXPR`이고 `op == PT_EQ`인지 확인.
   - arg1/arg2 각각에 `pt_find_dblink_side_refs` 적용.
   - (한쪽만 dblink ref, 다른 쪽만 outer ref, 둘 다 others 없음)이면 `true` 반환.

5. **`pt_check_pushable_term()` 수정**
   - 기존: `return PT_PUSHABLE_TERM(infop) && !is_correlated_with_agg && !is_correlated_with_dblink;`
   - 변경: 위 조건이 참이면 `return true`. 거짓이어도 **spec이 dblink**이고 **term이 단일 등치**이며 **`pt_is_dblink_join_key_equality(parser, term, infop)`가 true**이면 `return true` (푸시 허용). 그 외 `return false`.

**빌드**: `cubrid`, `cubridsa` 타깃 성공.

---

### T1-1a (완료)

**목표**: T1-1 조건 보완. Predicate push는 dblink rewrite **이후**에 수행되므로 `derived`가 이미 PT_SELECT(래퍼)인 경우도 dblink로 인식.

**변경 파일**: `src/parser/view_transform.c` — `pt_check_pushable_term()`

**변경 내용**: dblink spec 판별 시 (1) `derived->node_type == PT_DBLINK_TABLE` (rewrite 전) 뿐 아니라 (2) `derived->node_type == PT_SELECT` 이고 `derived->info.query.q.select.from->info.spec.derived_table->node_type == PT_DBLINK_TABLE` (rewrite 후 래퍼 구조)인 경우도 `is_dblink_spec = true`로 두고, 동일하게 `pt_is_dblink_join_key_equality` 호출 후 푸시 허용.

**빌드**: `cubridsa` 타깃 성공.

---

### T1-2 (완료)

**목표**: 푸시 시 rewritten에 `remote.col = ?` 반영, `PT_DBLINK_INFO`에 `join_key_local_ref_count`, `join_key_local_refs` 추가 및 매핑.

**변경 파일**:

| 파일 | 변경 내용 |
|------|-----------|
| `src/parser/parse_tree.h` | `PT_DBLINK_INFO`에 `int join_key_local_ref_count`, `PT_NODE **join_key_local_refs` 추가 |
| `src/parser/view_transform.c` | `pt_get_remote_side_of_join_key()` 추가, `pt_copypush_terms()`에 dblink wrapper 감지 및 join key 처리 로직 추가 |
| `src/parser/parse_tree_cl.c` | `pt_apply_dblink_table()`에서 `join_key_local_refs` walk 추가 |

**추가·변경 내용**:

1. **`pt_get_remote_side_of_join_key()`**
   - `remote.col = local.col` 형태의 조인 키 등치에서 원격 측/로컬 측 노드 식별.
   - 반환: 원격 측 노드. `*local_side_out`에 로컬 측 노드 저장.

2. **`pt_copypush_terms()` 수정**
   - `FIND_ID_INFO *infop` 파라미터 추가 (선택, NULL 가능).
   - **PT_SELECT (dblink wrapper) 처리**: `from`이 단일 spec이고 `derived_table`이 `PT_DBLINK_TABLE`이면 dblink wrapper로 판단.
   - 조인 키 등치만 추출하여 `"remote.col = ?"` 문자열 생성, `join_key_local_refs`에 로컬 측 노드 복사본 저장.
   - `rewritten`에 `SELECT * FROM (원본쿼리) cublink WHERE id = ?` 형태로 설정.
   - 호출부: `mq_copypush_sargable_terms_helper`에서 `infop` 전달.

3. **`PT_DBLINK_INFO` 확장**
   - `join_key_local_ref_count`: i번째 `?`에 대응하는 조인 키 개수.
   - `join_key_local_refs[i]`: i번째 `?`에 바인딩할 로컬 측 노드 (예: `l.id`).

**빌드**: `cubridsa` 타깃 성공.

---

## Step 2: XASL 생성 (pt_to_dblink_table_spec_list)

### T2-1 (완료)

**목표**: `join_key_local_ref_count > 0`이고 PT_HOST_VAR가 없을 때 `join_key_count`, `join_key_regu_list`를 채우고, `conn_sql`에 푸시된 WHERE 반영.

**변경 파일**: `src/parser/xasl_generation.c`

**추가·변경 내용**:

1. **조건**: `access`가 존재하고, `pdblink->join_key_local_ref_count > 0`이며, `count == 0`(PT_HOST_VAR 없음)일 때만 처리.
2. **리스트 구성**: `join_key_local_refs`를 역순으로 `parser_append_node`로 연결해 `node_list` 생성.
3. **REGU 변환**: `pt_to_regu_variable_list()`로 `join_key_regu_list` 생성.
4. **설정**: `access->s.dblink_node.join_key_count`, `access->s.dblink_node.join_key_regu_list`에 저장.

**참고**:
- `conn_sql`은 T1-2에서 `pdblink->rewritten`이 설정되면 이미 `sql` 변수에 반영되어 사용됨.
- `xasl_to_stream.c` / `stream_to_xasl.c`의 직렬화/역직렬화는 T0-2에서 이미 구현됨.

---

## Step 3: 실행기 (Open / Reset / Next)

### T3-1 (완료)

**목표**: Open 시 spec에서 `join_key_count`, `join_key_regu_list`를 scan_info에 복사; `join_key_count > 0`이면 `cci_prepare`만, execute는 생략.

**변경 파일**:

| 파일 | 변경 내용 |
|------|-----------|
| `src/query/dblink_scan.h` | `DBLINK_SCAN_INFO`에 `int join_key_count`, `struct regu_variable_list_node *join_key_regu_list` 추가 |
| `src/query/dblink_scan.c` | `dblink_open_scan()`에서 spec→scan_info 복사; `join_key_count > 0`이면 prepare만 수행, bind/execute 생략, `col_info`/`col_cnt`는 reset에서 설정 예정(T3-2) |

**빌드**: `cubrid`, `cubridsa` 타깃 성공.

---

### T3-2 (완료)

**목표**: Reset 시 `dblink_scan_reset(scan_info, vd)` 시그니처 변경; 호출부에서 vd 전달; outer dependent이면 vd로 bind 후 `cci_execute`. 실패 시 에러 설정·상위 전파.

**변경 파일**:

| 파일 | 변경 내용 |
|------|-----------|
| `src/query/dblink_scan.c` | `dblink_bind_param_dbvalue()` 추가 (단일 DB_VALUE 바인딩); `dblink_scan_reset(scan_info, vd)` 시그니처 변경, `join_key_count > 0`이면 regu에서 DB_VALUE 추출 후 bind → execute, 첫 execute 시 `col_info`/`col_cnt` 설정 |
| `src/query/dblink_scan.h` | `dblink_scan_reset(scan_info, vd)` 선언 변경 |
| `src/query/scan_manager.c` | `scan_reset_scan_block()`에서 `dblink_scan_reset(&s_id->s.dblid.scan_info, s_id->vd)` 호출 |

**REGU 값 추출**: `vfetch_to`, `TYPE_POS_VALUE`(vd->dbval_ptr[val_pos]), `dbvalptr`, `TYPE_ATTR_ID` 등(`cache_dbvalp`) 순으로 시도.

**빌드**: `cubridsa` 타깃 성공.

---

### T3-3 (완료)

**목표**: Next 시 푸시된 경우 fetch 경로 유지, 로컬 predicate 평가는 일단 유지 (추후 스킵 검토).

**결과**: 코드 변경 없음. 기존 경로가 이미 요구사항을 충족함.
- **fetch 경로**: `dblink_scan_next()`가 `col_info`/`col_cnt`로 cci_fetch 수행. `join_key_count > 0`일 때 T3-2 reset에서 `col_info`/`col_cnt` 설정 후 next 호출되므로 동일 경로 사용.
- **로컬 predicate**: `scan_next_dblink_scan()`의 `vaidp->scan_pred.pr_eval_fnc` 평가 유지 (추후 스킵 검토).

---

## Step 4: 플랜·스펙 검증

### T4-1 (완료)

**목표**: `join_key_regus[i]->value.vfetch_to`가 outer `val_list` 엔트리를 가리키도록 하여, `dblink_scan_reset` 시 현재 outer 행 값을 읽을 수 있게 함.

**변경 파일**: `src/parser/xasl_generation.c` `pt_to_dblink_table_spec_list()`

**추가·변경 내용**:

1. **기존 문제**: `pt_to_regu_variable_list(parser, node_list, UNBOX_AS_VALUE, NULL, NULL)`로 생성 시 `value_list`가 NULL이라 `vfetch_to`가 설정되지 않음. `dblink_scan_reset`에서 outer 행 값을 얻기 어려움.

2. **해결**: outer 테이블의 `table_info->value_list`와 `attribute_list`를 사용해 `pt_to_position_regu_variable_list()`로 REGU 생성.
   - `join_key_local_refs[0]`에서 outer spec_id 추출 (PT_DOT이면 arg2, PT_NAME이면 해당 노드의 `info.name.spec_id`).
   - `pt_find_table_info(outer_spec_id, parser->symbols->table_info)`로 outer `table_info` 획득.
   - 각 `join_key_local_refs[i]`에 대해 `pt_find_attribute(parser, attr_node, outer_tbl_info->attribute_list)`로 `attr_offsets[i]` 계산.
   - `pt_to_position_regu_variable_list(parser, node_list, outer_tbl_info->value_list, attr_offsets)` 호출 → `vfetch_to`가 outer `val_list` 슬롯을 가리킴.

3. **Fallback**: outer `table_info`가 없거나 `pt_find_attribute`가 -1을 반환하면 기존 `pt_to_regu_variable_list` 경로 유지.

**결과**: `dblink_scan_reset`에서 `regu_node->value.vfetch_to`로 현재 outer 행의 DB_VALUE를 읽어 bind 가능.

---

### T4-2 (T0-3으로 흡수됨)

**T4-2 삭제, T0-3 흡수**: dblink outer 시 `join_key_count` 오설정 버그 수정은 `is_generating_dblink_inner_scan` 플래그로 해결. [T0-3](#t0-3-완료) 참고.

---

### T4-3 (완료)

**목표**: push-down 후보 dblink spec에 대해 `mq_rewrite_dblink_as_subquery`에서 rewrite 생략. `PT_DERIVED_DBLINK_TABLE` 유지 → XASL 생성 시 `pt_to_dblink_table_spec_list` 직접 호출 → dblink scan이 `scan_ptr`에 직접 위치.

**변경 파일**:

| 파일 | 변경 내용 |
|------|-----------|
| `src/parser/view_transform.c` | `mq_has_dblink_join_key_equality_term()` 신규; `mq_rewrite_dblink_as_subquery()`에서 후보 시 rewrite 생략 |

**추가·변경 내용**:

1. **`mq_has_dblink_join_key_equality_term()`** (신규): WHERE 절을 순회하며 `pt_is_dblink_join_key_equality`로 "remote.col = local.col" 조건 탐지. PT_AND 중첩 시 arg1/arg2 재귀 탐색.

2. **`mq_rewrite_dblink_as_subquery()`** 수정: 각 dblink spec에 대해 `mq_has_dblink_join_key_equality_term()`이 true이면 rewrite 생략(continue). 비후보는 기존대로 `mq_rewrite_dblink_as_derived` 호출 후 `PT_IS_SUBQUERY` 설정.

**효과**: push-down 경로에서 `outer → scan_ptr → dblink_scan` 구조로 `scan_reset_scan_block`이 dblink까지 전달 → rebind+execute 가능.

**빌드**: `cubrid` 타깃 성공.

---

### T4-4 (완료)

**목표**: T4-3 적용 후 `pt_check_pushable_term`의 dblink 인식 로직 검토. T1-1 원래 조건(`derived->node_type == PT_DBLINK_TABLE`)이 push-down 후보에 충분한지, T1-1a(wrapper PT_SELECT)가 비후보 fallback으로 유지되는지 확인.

**결과**: 두 분기 모두 필요. push-down 후보는 T4-3으로 `derived`가 PT_DBLINK_TABLE 유지 → 첫 번째 분기. 비후보는 rewrite로 `derived`가 PT_SELECT → T1-1a 분기. 코드 변경 없이 주석만 보완.

**변경 파일**: `src/parser/view_transform.c` — `pt_check_pushable_term()` 주석에 T4-4 검토 결과 반영.

---

## 미완료 태스크 (참고)

- **T5-1** ~ **T5-3**: [dblink_join_optimization_tasks.md](dblink_join_optimization_tasks.md) 참고.

---

## 문서 이력

| 일자 | 작성/수정 | 내용 |
|------|-----------|------|
| TBD | TBD | Step 0·T1-1 작업 요약 작성 |
| TBD | TBD | T1-2 완료 요약 추가 |
| TBD | TBD | T2-1 완료 요약 추가 |
| TBD | TBD | T3-1 완료 요약 추가 |
| TBD | TBD | T3-2 완료 요약 추가 |
| TBD | TBD | T3-3 완료 요약 추가 (코드 변경 없음) |
| TBD | TBD | T4-1 완료 요약 추가 (pt_to_position_regu_variable_list로 vfetch_to 설정) |
| TBD | TBD | T4-2 완료 요약 추가 (is_generating_dblink_inner_scan 플래그로 outer/hash/merge join 시 join_key_count 오설정 버그 수정) |
| TBD | TBD | T0-3 완료 요약 추가 (T4-2 흡수, gen_inner 플래그 set/clear + pt_to_dblink_table_spec_list 두 guard) |
| TBD | TBD | T4-3 완료 요약 추가 (mq_rewrite_dblink_as_subquery rewrite 건너뜀) |
| TBD | TBD | T4-4 완료 요약 추가 (pt_check_pushable_term T1-1/T1-1a 분기 검토) |
