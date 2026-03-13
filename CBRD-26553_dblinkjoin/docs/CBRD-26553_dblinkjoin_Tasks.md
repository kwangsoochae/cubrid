# DBLINK 조인 최적화 — TASKS

| 항목 | 내용 |
|------|------|
| 이슈 | CBRD-26553 |

**의존 관계**: Step 1 → Step 2 → Step 3. Step 0은 병렬 가능. Step 4는 2·3과 병행. **Step 4에 XASL dblink spec 변경 포함.** Step 5는 3·4 완료 후.

**주의 (실행 순서)**: Parser에서 `mq_rewrite_dblink_as_subquery`가 **predicate push보다 먼저** 수행되므로, `pt_check_pushable_term` 실행 시점에는 dblink spec의 `derived_table`이 이미 **PT_SELECT**(래퍼)로 바뀌어 있음. 따라서 `derived->node_type == PT_DBLINK_TABLE`만 보면 **항상 false**가 되어 T1-1 예외 로직이 한 번도 타지 않음. **T1-1a**에서 이 조건을 보완함. → **T4-3 완료 후**: push-down 후보 spec은 변환이 생략되어 predicate push 시점에도 `PT_DERIVED_DBLINK_TABLE` 유지 → T1-1 원래 조건으로 충분해질 수 있음. T1-1a 역할은 T4-4에서 재검토.

---

## 설계: XASL dblink spec 변경



`mq_rewrite_dblink_as_subquery` (`view_transform.c:6936`, 호출 위치 `view_transform.c:8584`)가 optimizer/XASL 생성 **이전에** 실행되어, 모든 dblink spec의 `derived_table_type`을 `PT_DERIVED_DBLINK_TABLE` → `PT_IS_SUBQUERY`(wrapper PT_SELECT)로 변환한다.

결과적으로 XASL 생성 시 `pt_to_spec_list`(`xasl_generation.c:13247`)가 `PT_IS_SUBQUERY` 분기인 `pt_to_subquery_table_spec_list`를 호출하여, dblink ACCESS_SPEC이 `aptr_list`(uncorrelated buildlist) 내부에 위치하게 된다. 

> **참고**: `qo_scan_new`(`query_planner.c:1635`)는 모든 scan plan에 `well_rooted = true`를 설정하므로, NL join 내 `VALID_INNER(inner)` = true → SORT_TEMP는 dblink에 적용되지 않는다. list 구조의 원인은 SORT_TEMP가 아니라 `mq_rewrite_dblink_as_subquery`이다.

**현재 XASL 구조**:
```
outer (class scan)
  └── scan_ptr → list_scan  ← scan_reset_scan_block 여기서 멈춤
                  └── aptr_list → wrapper PT_SELECT XASL
                                    └── spec_list → dblink ACCESS_SPEC (join_key_count 있음)
                                                      └── dblink_scan  ← reset 불가
```

**목표 구조 (XASL dblink spec 변경)**:
```
outer (class scan)
  └── scan_ptr → dblink_scan  ← scan_reset_scan_block(S_DBLINK_SCAN) → dblink_scan_reset() → rebind+execute
```

**핵심**: `mq_rewrite_dblink_as_subquery`에서 push-down 후보 dblink spec은 rewrite를 건너뛰어 `PT_DERIVED_DBLINK_TABLE` 유지 → XASL 생성 시 `pt_to_dblink_table_spec_list` 직접 호출 → dblink scan이 `scan_ptr`에 직접 위치.

| 현재 구조 | 목표 구조 (XASL dblink spec 변경) |
|-----------|-------------------|
| `mq_rewrite_dblink_as_subquery` → `PT_IS_SUBQUERY` → `pt_to_subquery_table_spec_list` | rewrite 건너뜀 → `PT_DERIVED_DBLINK_TABLE` → `pt_to_dblink_table_spec_list` |
| outer → scan_ptr → list_scan ← aptr_list → dblink_scan | outer → scan_ptr → dblink_scan |
| `scan_reset_scan_block`이 list_scan까지만 전달 | reset이 dblink_scan까지 전달 → rebind+execute |

**범위**: push-down 후보 dblink가 NL/IDX inner일 때만 적용. 후보가 아니거나 dblink가 outer인 경우 기존 rewrite 동작 유지.

---

### PRD 요구사항 매핑

| PRD 요구사항 | 대응 태스크 |
|--------------|-------------|
| FR-1 푸시 후보 식별·원격에 `?` 반영 | T1-1, T1-2 |
| FR-3 `join_key_count > 0` 분기 조건 (PT_HOST_VAR 시 join_key_count = 0 유지) | T2-1 |
| FR-8 XASL dblink spec 변경 (inner 판별 flag + guard + rewrite 우회) | T0-3, T4-3 |
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
| T0-3 | **inner 판별 인프라**: `PARSER_CONTEXT.flag`에 `is_generating_dblink_inner_scan` 비트 추가; `gen_inner()` case QO_PLANTYPE_SCAN에서 spec이 `PT_DERIVED_DBLINK_TABLE`일 때 `init_class_scan_proc` 호출 전후 set/clear; `pt_to_dblink_table_spec_list()`에 두 가지 guard 추가: (1) `join_key_count` 설정을 `is_generating_dblink_inner_scan = 1`일 때만, (2) `conn_sql` 선택을 `is_generating_dblink_inner_scan = 1`일 때만 `rewritten` 사용(아니면 원본 `qstr` 사용, dblink가 outer일 때 unbound `?` 방지); `qexec_open_scan` col_cnt guard 추가 | `src/parser/parse_tree.h`, `src/query/query_executor.c`, `src/optimizer/plan_generation.c`, `src/parser/xasl_generation.c` | [x] |

### Step 0 점검

- **T0-2**: `xasl.h`에 `join_key_count`, `join_key_regu_list` 필드 존재 확인; `xasl_to_stream.c` / `stream_to_xasl.c`에 직렬화·역직렬화 코드 존재 확인
- **T0-3**: `gen_inner` 내 breakpoint → `PT_DERIVED_DBLINK_TABLE` spec 처리 시 `is_generating_dblink_inner_scan = 1` set/clear 확인
- **T0-3**: `pt_to_dblink_table_spec_list` 내 두 guard 동작 확인
  - dblink inner: `rewritten` SQL 사용, `join_key_count > 0` 설정
  - dblink outer: `qstr`(원본) SQL 사용, `join_key_count = 0` 유지

---

## Step 1: 푸시 조건 식별 (Parser / View transform)

| ID | 작업 | 파일/위치 | 완료 |
|----|------|-----------|:----:|
| T1-1 | "원격 컬럼 = 로컬 컬럼" 등치를 푸시 허용: `pt_find_dblink_side_refs`, `pt_is_dblink_join_key_equality` 추가, `pt_check_pushable_term()`에서 예외 처리 | `src/parser/view_transform.c` | [x] |
| T1-1a | **T1-1 조건 보완**: predicate push가 dblink rewrite **이후**에 수행되므로, `derived->node_type == PT_DBLINK_TABLE`만으로는 한 번도 true가 되지 않음. rewrite 이후 구조(derived가 PT_SELECT이고 내부 from의 derived_table이 PT_DBLINK_TABLE인 경우)도 dblink로 인식하도록 조건 추가. 또는 predicate push를 dblink rewrite보다 먼저 수행하도록 실행 순서 변경 검토. | `src/parser/view_transform.c` `pt_check_pushable_term()` | [x] |
| T1-2 | 푸시 시 dblink 테이블(`PT_DBLINK_TABLE`)에 대해 join-key 등치(`remote.col = local.col`)를 식별하고, 원격 쿼리 rewritten에 `remote.col = ?`를 반영한다. `PT_DBLINK_INFO`에 `join_key_local_ref_count`, `join_key_local_refs`를 채워 XASL(`join_key_count`, `join_key_regu_list`)과 매핑한다. 래퍼 `PT_SELECT` 기반 푸시 초안은 폐기하고, 최종 설계는 PT_DBLINK_TABLE 기준으로 일원화한다. | `src/parser/parse_tree.h`, `view_transform.c` `pt_copypush_terms()` | [x] |

### Step 1 점검

- **T1-1 / T1-1a — 코드 경로 확인** (T1-2 완료 전까지는 런타임 동작 변화 없으므로 gdb로 확인):
  ```sql
  -- 점검 쿼리 (push 후보 조건)
  SELECT l.id, l.name, r.name FROM local_t l, 
  DBLINK ('localhost:33000:testdb4dblink:cubrid:cubrid:','SELECT id, name from remote_t') AS r(id int, name varchar(32))
  WHERE l.id = r.id;
  ```
  - gdb: `pt_check_pushable_term`에 breakpoint → `l.id = r.id` term에서 `return true` 확인
  - gdb: `pt_is_dblink_join_key_equality` → `has_dblink_2=true`, `has_outer_1=true` 확인

- **T1-1 — 푸시 불가 조건 (false 리턴 확인)**:
  ```sql
  -- PT_HOST_VAR 혼합: push 불가여야 함
  WHERE l.id = r.id AND r.val = ?
  -- 서브쿼리 포함: push 불가여야 함
  WHERE l.id = r.id AND r.val = (SELECT MAX(x) FROM t)
  ```
  - gdb: 위 조건에서 `pt_is_dblink_join_key_equality` → `false` 리턴 확인

- **T1-2 완료 후 추가 점검**: `pt_copypush_terms` 호출 여부 및 `join_key_local_refs` 채워짐 확인

---

## Step 2: XASL에 반영

| ID | 작업 | 파일/위치 | 완료 |
|----|------|-----------|:----:|
| T2-1 | `join_key_local_ref_count > 0`이고 PT_HOST_VAR 없을 때 `join_key_count`, `join_key_regu_list` 채우기; `conn_sql`에 푸시된 WHERE 포함 (`join_key_count > 0`이 이후 open/reset 분기 조건) | `src/parser/xasl_generation.c` `pt_to_dblink_table_spec_list()` | [x] |

### Step 2 점검

- **XASL 내용 확인**:
  - gdb: `pt_to_dblink_table_spec_list()` 리턴 직후 `dblink_node->join_key_count > 0` 확인
  - gdb: `dblink_node->conn_sql`에 `WHERE id = ?` 형태 포함 여부 확인
  - gdb: `dblink_node->join_key_regu_list` 첫 엔트리가 `l.id`에 해당하는 REGU_VARIABLE인지 확인

- **푸시 불가 경우 (join_key_count = 0 유지)**:
  - 앱 `?` 포함 쿼리에서 `join_key_count == 0` 확인
  - 단순 dblink (join 없음) 쿼리에서 `join_key_count == 0` 확인

---

## Step 3: 실행기 (Open / Reset / Next)

| ID | 작업 | 파일/위치 | 완료 |
|----|------|-----------|:----:|
| T3-1 | Open: spec에서 `join_key_count`, `join_key_regu_list`를 scan_info에 복사; `join_key_count > 0`이면 `cci_prepare`만, execute는 생략 | `src/query/dblink_scan.c` `dblink_open_scan()`, `dblink_scan.h` `DBLINK_SCAN_INFO` | [x] |
| T3-2 | Reset: `dblink_scan_reset(scan_info, vd)` 시그니처 변경; 호출부에서 vd 전달; outer dependent이면 vd로 `dblink_bind_param` 후 `cci_execute`. 실패 시 에러 설정·상위 전파, 필요 시 stmt/conn 정리 (NFR-3) | `dblink_scan.c`, `scan_manager.c` `scan_reset_scan_block()` | [x] |
| T3-3 | Next: 푸시된 경우 fetch 경로 유지, 로컬 predicate 평가는 일단 유지 (추후 스킵 검토) | `src/query/scan_manager.c` `scan_next_dblink_scan()` | [x] |

### Step 3 점검

- **T3-1 — open 시 execute 생략 확인**:
  - gdb: `dblink_open_scan()` 내 `join_key_count > 0` 분기에서 `cci_execute` 미호출 확인
  - gdb: `scan_info->join_key_count`, `scan_info->join_key_regus` 복사됨 확인

- **T3-2 — reset 시 rebind+execute 확인**:
  - gdb: `dblink_scan_reset()` 내 `dblink_bind_param` → `cci_execute` 순서 호출 확인
  - gdb: outer 행 값이 bind parameter로 전달되는지 `vd` 통해 확인

- **T3 통합 — SQL 결과 동등성**:
  ```sql
  -- push-down 경로
  SELECT l.id, l.name, r.name
  FROM local_t l,
    DBLINK('localhost:33000:testdb:cubrid:cubrid:', 'SELECT id, name FROM remote_t')
    AS r(id int, name varchar(32))
  WHERE l.id = r.id;
  ```
  - AS-IS(push-down 전) 결과와 행 수·값 동일한지 비교
  - 원격으로 전송된 SQL에 `WHERE id = ?` 포함 여부 확인 (원격 DB slow query log 또는 gdb `conn_sql`)

- **T3-2 — 에러 전파 (NFR-3)**:
  - 원격 DB 연결 끊은 상태에서 reset 시 `ER_DBLINK` 에러 상위 전파 확인

---

## Step 4: 플랜·스펙 검증 및 XASL dblink spec 변경

### 4.1 기존 검증

| ID | 작업 | 파일/위치 | 완료 |
|----|------|-----------|:----:|
| T4-1 | NL inner dblink 스펙에 `join_key_count`, `join_key_regu_list` 유지 여부 확인; `scan_open_dblink_scan` 호출 경로에서 `join_key_regus[i]->value.dbvalptr`가 outer val_list 엔트리를 가리키는지 확인 | `xasl_generation.c` `pt_to_dblink_table_spec_list()` | [x] |

### 4.2 XASL dblink spec 변경: dblink를 scan_ptr에 직접 inner로 두기

| ID | 작업 | 파일/위치 | 완료 |
|----|------|-----------|:----:|
| T4-3 | **rewrite 건너뜀**: `mq_rewrite_dblink_as_subquery`에서 push-down 후보 dblink spec은 `PT_IS_SUBQUERY` 변환 생략. 외부 SELECT의 WHERE 절에서 `pt_is_dblink_join_key_equality`로 join-key 등치 조건 탐지; 후보이면 rewrite 생략하여 spec의 `derived_table_type = PT_DERIVED_DBLINK_TABLE` 유지. 비후보는 기존 rewrite 수행 | `src/parser/view_transform.c` `mq_rewrite_dblink_as_subquery()` | [x] |
| T4-4 | **T1-1a 역할 검토**: T4-3 적용 후 push-down 후보 spec은 rewrite가 생략되므로 `pt_check_pushable_term`이 `PT_DERIVED_DBLINK_TABLE`을 직접 보게 됨 → T1-1의 원래 조건(`derived->node_type == PT_DBLINK_TABLE`)으로 충분한지 확인. T1-1a(wrapper PT_SELECT 구조 인식)는 비후보 spec에서 predicate push가 시도될 경우를 위한 fallback으로 유지 가능 | `src/parser/view_transform.c` `pt_check_pushable_term()` | [x] |
| T4-5 | **end-to-end 검증**: T4-3 적용 후 push-down 경로에서 `scan_reset_scan_block(S_DBLINK_SCAN)` → `dblink_scan_reset()` → rebind+execute 흐름 동작 확인; 비후보(rewrite 유지) 경로에서 AS-IS 동작(cursor rewind) regression 없음 확인 | `src/query/scan_manager.c`, `src/query/query_executor.c` | [ ] |

### Step 4 점검

- **T4-1 기존 검증**:
  - gdb: `scan_open_dblink_scan()` 진입 시점에 `spec->s.dblink_node.join_key_count > 0` 확인
  - gdb: `join_key_regus[i]->value.dbvalptr`가 outer scan의 val_list 슬롯 주소와 동일한지 확인
  - outer 행이 바뀔 때 `dbvalptr`가 가리키는 값도 자동으로 바뀌는지 확인 (포인터 연결 유효성)
  - dblink가 outer인 쿼리에서 `join_key_count == 0` 유지 및 AS-IS 동작(cursor rewind) 확인

**XASL dblink spec 변경 점검 (T4-3 ~ T4-5)**:
- **T4-3**: `mq_rewrite_dblink_as_subquery` 내 breakpoint → push-down 후보 spec에서 rewrite 생략 확인; 비후보는 기존대로 `PT_IS_SUBQUERY` 변환 확인
- **T0-3**: `gen_inner` 내 breakpoint → `PT_DERIVED_DBLINK_TABLE` spec 처리 시 `is_generating_dblink_inner_scan = 1` set/clear 확인; `pt_to_dblink_table_spec_list` 내 guard 통과로 `join_key_count > 0` 설정 확인
- **XASL 구조**: push-down 경로에서 `scan_ptr` 체인이 `outer (class) → dblink_scan` 형태인지 확인 (aptr_list에 wrapper PT_SELECT XASL 없음)
- **T4-5 — 실행 흐름**:
  ```sql
  SELECT l.id, l.name, r.name
  FROM local_t l,
    DBLINK('localhost:33000:testdb:cubrid:cubrid:', 'SELECT id, name FROM remote_t')
    AS r(id int, name varchar(32))
  WHERE l.id = r.id;
  ```
  - outer 행마다 `scan_reset_scan_block(dblink_scan_id)` → `dblink_scan_reset()` → bind+execute 확인
  - 비후보 쿼리(단순 dblink, 앱 `?` 혼합): `PT_IS_SUBQUERY` 경로 유지, regression 없음 확인

---

## Step 5: 테스트·검증

| ID | 작업 | 설명 | 완료 |
|----|------|------|:----:|
| T5-1 | 푸시 가능 조인 | `WHERE local.id = remote.id` 등 결과 행 수·값이 기존(전체 fetch 후 로컬 조인)과 동일한지 | [ ] |
| T5-2 | 푸시 불가 / 단일 dblink | regression 없음 확인 | [ ] |
| T5-3 | Gateway 경유 (선택) | 원격 전송 행 수 감소, 실행 계획 반영 여부 | [ ] |

### Step 5 점검 SQL

```sql
-- [T5-1] push-down 대상: 결과 동등성
SELECT l.id, l.name, r.name
FROM local_t l,
  DBLINK('localhost:33000:testdb:cubrid:cubrid:', 'SELECT id, name FROM remote_t')
  AS r(id int, name varchar(32))
WHERE l.id = r.id;

-- [T5-1] 다중 조인 키 (향후 확장 시)
WHERE l.id = r.id AND l.code = r.code

-- [T5-2] 단순 dblink (join 없음): AS-IS 동작 유지
SELECT * FROM DBLINK('...', 'SELECT id FROM remote_t') AS r(id int);

-- [T5-2] 앱 ? 혼합: push 안 되고 AS-IS 동작
SELECT l.id, r.name
FROM local_t l,
  DBLINK('...', 'SELECT id, name FROM remote_t WHERE val > ?') AS r(id int, name varchar(32))
WHERE l.id = r.id;

-- [T5-2] outer join: push 안 되고 AS-IS 동작
SELECT l.id, r.name
FROM local_t l LEFT JOIN
  DBLINK('...', 'SELECT id, name FROM remote_t') AS r(id int, name varchar(32))
  ON l.id = r.id;
```

- 모든 쿼리에서 AS-IS 결과와 행 수·값 일치 확인
- T5-2 쿼리에서 `join_key_count == 0` 유지 및 기존 cursor rewind 경로 동작 확인

---

## 완료 체크리스트 (Step별)

- [x] **Step 0** — T0-1 [x], T0-2 [x], T0-3 [x]
- [ ] **Step 1** — T1-1 [x], T1-1a [x], T1-2 [x] (빌드·기존 테스트 통과)
- [ ] **Step 2** — T2-1 [x]
- [ ] **Step 3** — T3-1 [x], T3-2 [x], T3-3 [x]
- [ ] **Step 4** — T4-1 [x], T4-3 [x], T4-4 [x], **T4-5 (XASL dblink spec 변경)**
- [ ] **Step 5** — T5-1, T5-2(, T5-3)

---

## 문서 이력

| 일자 | 작성/수정 | 내용 |
|------|-----------|------|
| TBD | TBD | TASKS 초안 작성 (plan/work 기반) |
| TBD | TBD | 실행 순서 반영: T1-1a 추가, 주의 문구 추가 |
| TBD | TBD | 각 Step별 점검 항목 추가 |
| TBD | TBD | T4-2 추가: dblink outer 시 join_key_count 오설정 버그 수정 |
| TBD | TBD | TASKS2 생성: XASL dblink spec 변경(T4-3~T4-6) Step 4에 통합 |
| TBD | TBD | T4-3~T4-6 재설계: root cause = `mq_rewrite_dblink_as_subquery` (SORT_TEMP 아님); T4-3 타깃을 `query_planner.c` → `view_transform.c`로 변경; T4-4를 gen_inner 플래그 set/clear + T4-2 완성으로 재정의; T4-5를 T1-1a 역할 검토로 변경; 섹션명 "방향 A" → "XASL dblink spec 변경"으로 변경 |
| TBD | TBD | T0-3 신설 (Step 0 인프라): is_generating_dblink_inner_scan flag set/clear 및 xasl_generation guard를 T0-3으로 이동; T2-1에서 guard 언급 제거; T4-2 삭제 (T0-3 흡수); T4-4 삭제 (T0-3 흡수); T4-5→T4-4, T4-6→T4-5로 재번호 |
