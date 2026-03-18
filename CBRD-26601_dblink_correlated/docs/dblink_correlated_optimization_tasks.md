# DBLink Correlated 서브쿼리 최적화 — TASKS

| 항목 | 내용 |
|------|------|
| 이슈 | CBRD-26601 |
| 관련 문서 | [PRD](dblink_correlated_optimization_prd.md), [Design Doc](dblink_correlated_optimization_design_doc.md), [소스 분석](dblink_correlated_source_analysis.md) |

**의존 관계**: Step 0 → Step 1 → Step 2 → Step 3 → Step 4. Step 5(직렬화)는 Step 2 완료 후 병행 가능. Step 6(테스트)는 Step 4 완료 후.

---

## PRD 요구사항 매핑

| PRD 요구사항 | 대응 태스크 |
|--------------|-------------|
| FR-1 `remote.col = outer.col` 등치 탐지 | T1-1 |
| FR-2 `conn_sql`에 `WHERE col = ?` append | T1-2 |
| FR-3 `corr_key_count` / `corr_key_regu_list` 추가 | T0-2, T2-1 |
| FR-4 open 시 prepare만, execute 지연 | T3-1 |
| FR-5 outer 행 평가 시 bind + execute | T3-2 |
| FR-6 NULL 처리 — re-execute 스킵 | T3-3 |
| FR-7 push-down 불가 시 기존 방식 유지 | T1-1 (보수적 탐지), T6-3 (regression) |
| FR-8 push-down된 조건 access_pred 제거 | T4-1 |
| FR-9 `use_dblink_corr_pushdown` 세션 파라미터 | T1-3, T6-7 |
| NFR-1 기존 경로 호환성 | T3-1/T3-2 분기, T6-3 |
| NFR-2 re-execute 실패 시 에러 전파 | T3-2 |
| NFR-3 직렬화 반영 | T5-1 |

---

## Step 0: 사전 확인 및 인프라

| ID | 작업 | 파일/위치 | 완료 |
|----|------|-----------|:----:|
| T0-1 | Design Doc 미결 사항(C-1~C-5) 사전 코드 확인. (C-1) `pt_to_subquery_table_spec_list`에서 원본 PT_DBLINK_INFO 접근 경로. (C-2) 래퍼 재실행 시 DBLink spec에 `scan_close_scan`/`scan_open_scan` 호출 여부. (C-3) `conn_sql` 기존 WHERE 절 존재 여부 판별. (C-4) aptr DBLink 판별 조건(`ACCESS_SPEC_TYPE` 등). (C-5) `REGU_VARIABLE_LIST` pack/unpack 기존 함수명. | `src/parser/xasl_generation.c`, `src/query/dblink_scan.c`, `src/query/xasl_to_stream.c` | [ ] |
| T0-2 | `dblink_spec_node`에 `corr_key_count`(int), `corr_key_regu_list`(REGU_VARIABLE_LIST) 추가. `DBLINK_SCAN_INFO`에 동일 필드 추가. 직렬화(`xasl_to_stream.c` / `stream_to_xasl.c`) pack/unpack 반영. | `src/query/xasl.h`, `src/query/dblink_scan.h`, `src/query/xasl_to_stream.c`, `src/query/stream_to_xasl.c` | [ ] |

### Step 0 점검

- **T0-1 (C-1)**: gdb: `pt_to_subquery_table_spec_list` 인자 `subquery` → `info.query.from` → `spec->derived_table` 체인으로 원본 PT_DBLINK_INFO 접근 가능 여부 확인
- **T0-1 (C-2)**: gdb: `scan_open_scan(S_DBLINK_SCAN)` breakpoint, 2번째 outer 행 평가 시 히트 여부 확인 → 히트 시 prepare 핸들 보존 방식 검토 필요
- **T0-1 (C-3)**: `pdblink->qstr` 또는 `pdblink->rewritten` 문자열에서 `WHERE` 키워드 유무 확인
- **T0-1 (C-4)**: `xasl.h`의 `ACCESS_SPEC_TYPE` 또는 `spec->type` 으로 dblink 판별 방법 확인
- **T0-1 (C-5)**: `xasl_to_stream.c`에서 `dblink_regu_list_pred` pack 코드 패턴 확인
- **T0-2**: `xasl.h` 필드 추가 후 빌드 통과, stream pack/unpack 대칭 확인

---

## Step 1: 탐지 (Parser / View transform)

**배경**: `mq_rewrite_dblink_as_subquery`(`view_transform.c:6607`)에서 correlation 조건(`remote.col = outer.col`)을 탐지하고 `PT_DBLINK_INFO`에 기록한다. **rewrite는 기존과 동일하게 PT_IS_SUBQUERY로 변환 유지(옵션 B)**. 이후 XASL 생성 단계에서 래퍼 안의 `PT_DERIVED_DBLINK_TABLE` spec을 `pt_to_dblink_table_spec_list`로 처리하는 것을 목표로 하고, 접근이 어렵다면 Step 4에서처럼 `where_part` 재탐지로 fallback 한다. (설계 근거: Design Doc 5.1, C-1)

| ID | 작업 | 파일/위치 | 완료 |
|----|------|-----------|:----:|
| T1-1 | 서브쿼리 WHERE에서 `remote.col = outer.col` 단일 등치 조건 탐지 함수 추가. 탐지 조건: (1) 한 쪽이 DBLink 컬럼 ref, (2) 반대쪽이 outer query 컬럼 ref(TYPE_CONSTANT / correlation). 앱 `?`(PT_HOST_VAR) 포함 시 탐지 실패(기존 방식 유지). | `src/parser/view_transform.c` | [ ] |
| T1-2 | 탐지된 correlation 조건을 `PT_DBLINK_INFO`에 기록: `corr_key_remote_col`, `corr_key_outer_ref` 저장. `conn_sql`(원격 SQL)에 `WHERE remote.col = ?` append. 이미 WHERE가 있는 경우 `AND remote.col = ?` append. | `src/parser/parse_tree.h` `PT_DBLINK_INFO`, `src/parser/view_transform.c` | [ ] |
| T1-3 | `use_dblink_corr_pushdown` 세션 파라미터 추가 (boolean, 기본값 `yes`). `mq_rewrite_dblink_as_subquery` 탐지 진입부에서 파라미터 값을 확인하여 `no`이면 탐지 로직 전체를 스킵하고 기존 방식 유지. | `src/base/system_parameter.h/c`, `src/parser/view_transform.c` | [ ] |

### Step 1 점검

- **T1-3 세션 파라미터**:
  ```sql
  -- push-down OFF 설정 후 correlated 쿼리 실행
  SET SYSTEM PARAMETERS 'use_dblink_corr_pushdown=no';
  SELECT l.id, (SELECT r.name FROM remote_t@cubrid_conn r WHERE r.id = l.id LIMIT 1)
  FROM local_t l;
  -- gdb: 탐지 함수 진입 전 스킵 확인, conn_sql에 WHERE 없음 확인
  SET SYSTEM PARAMETERS 'use_dblink_corr_pushdown=yes';
  ```

- **T1-1 탐지 성공**:
  ```sql
  SELECT l.id, (SELECT r.name FROM remote_t@conn r WHERE r.id = l.id LIMIT 1)
  FROM local_t l
  ```
  - gdb: 탐지 함수에서 `remote.id = l.id` → 탐지 성공, `corr_key` 기록 확인

- **T1-1 탐지 실패 (기존 방식 유지)**:
  ```sql
  -- 앱 ? 혼합
  WHERE r.id = l.id AND r.val = ?
  -- OR 조건
  WHERE r.id = l.id OR r.code = l.code
  -- correlated 아님
  WHERE r.id = 1
  ```

- **T1-2**: 원격 SQL(conn_sql 또는 `pdblink->rewritten` 기반 문자열)에 `WHERE id = ?` 포함 여부 확인 (gdb 또는 `query_alias` 로그)

---

## Step 2: XASL 생성

| ID | 작업 | 파일/위치 | 완료 |
|----|------|-----------|:----:|
| T2-1 | `pt_to_dblink_table_spec_list()`에서 `PT_DBLINK_INFO.corr_key_count > 0`이고 PT_HOST_VAR 없을 때, `dblink_spec_node.corr_key_count` 및 `corr_key_regu_list` 채우기. `corr_key_regu_list`의 각 엔트리는 outer val_list 슬롯을 가리키는 TYPE_CONSTANT regu (현재 `access_pred`에서 쓰이는 것과 동일 슬롯). | `src/parser/xasl_generation.c` `pt_to_dblink_table_spec_list()` | [ ] |

### Step 2 점검

- **T2-1**: gdb `pt_to_dblink_table_spec_list` 리턴 후
  - `dblink_node->corr_key_count > 0` 확인
  - `dblink_node->conn_sql`에 `WHERE id = ?` 포함 확인
  - `corr_key_regu_list[0]`이 outer val_list의 `l.id` 슬롯을 참조하는지 확인
- **push-down 불가**: PT_HOST_VAR 포함 시 `corr_key_count == 0` 유지 확인

---

## Step 3: 런타임 (Open / Re-execute / Fetch)

**배경**: 현재 DBLink는 `0x40269c00`(래퍼)의 `aptr_list`에 배치되어 있으나 `XASL_ZERO_CORR_LEVEL`이 없어 `qexec_clear_head_lists`에서 매 래퍼 실행 후 CLEARED로 리셋된다. `IS_XASL_INITIAL_STATUS` 체크에서 매번 true가 되어 **N회 실행**된다. corr_key_count > 0인 경우(TO-BE), 이 재실행 시 DBLink가 새 outer 값으로 rebind + re-execute 하도록 처리한다.

| ID | 작업 | 파일/위치 | 완료 |
|----|------|-----------|:----:|
| T3-1 | `dblink_open_scan()`: `corr_key_count > 0`이면 `cci_prepare`만 수행, `cci_execute` 생략. spec → scan_info로 `corr_key_count`, `corr_key_regu_list` 복사. | `src/query/dblink_scan.c` `dblink_open_scan()`, `src/query/dblink_scan.h` `DBLINK_SCAN_INFO` | [ ] |
| T3-2 | corr DBLink aptr 재실행 메커니즘 구현: `qexec_execute_mainblock_internal`의 aptr 처리 루프(`query_executor.c:15292`)에서, `IS_CORR_DBLINK_XASL(aptr)`가 true인 aptr의 INITIAL/SUCCESS 분기 처리. (a) INITIAL: `qexec_execute_mainblock`으로 `dblink_open_scan`(prepare만) 후 `scan_reset_scan_block(&aptr->spec_list->s_id)` 호출. (b) SUCCESS: list 파괴 후 `scan_reset_scan_block` 호출. `scan_reset_scan_block`은 `dblink_scan_reset(scan_info, s_id->vd)`를 호출하며, 이 함수에서 `corr_key_regu_list`를 현재 outer 행 값으로 `cci_bind_param` + `cci_execute`한다. 실패 시 에러 설정·상위 전파(NFR-2). | `src/query/query_executor.c`, `src/query/dblink_scan.c` (`dblink_scan_reset` 확장), `src/query/scan_manager.c` (`s_id->vd` 전달 추가) | [ ] |
| T3-3 | NULL 처리: re-execute 직전 corr_key 값이 NULL이면 execute 스킵 → 빈 list → 0건(NULL 스칼라) 반환. | `src/query/dblink_scan.c` 또는 `query_executor.c` T3-2 내 | [ ] |

### Step 3 점검

- **T3-1 — open 시 execute 생략**:
  - gdb: `dblink_open_scan()` 내 corr_key_count > 0 분기에서 `cci_execute` 미호출 확인
  - gdb: `scan_info->corr_key_count`, `scan_info->corr_key_regu_list` 복사 확인

- **T3-2 — rebind + execute**:
  - gdb: 2번째 outer 행 평가 시 `cci_bind_param` → `cci_execute` 순서 호출 확인
  - gdb: `corr_key_regu_list[0]`에서 읽은 값이 현재 outer 행의 `l.id`와 일치하는지 확인

- **T3-2 에러 전파 (NFR-2)**:
  - 원격 DB 연결 끊긴 상태에서 re-execute → `ER_DBLINK` 에러 상위 전파 확인

- **T3-3 NULL**:
  ```sql
  -- l.id가 NULL인 행 포함 데이터
  SELECT l.id, (SELECT r.name FROM remote_t@conn r WHERE r.id = l.id LIMIT 1)
  FROM local_t l WHERE l.id IS NULL;
  ```
  - NULL 반환 확인, 에러 없음 확인

---

## Step 4: access_pred 제거 (FR-8)

| ID | 작업 | 파일/위치 | 완료 |
|----|------|-----------|:----:|
| T4-1 | push-down 적용 시(`corr_key_count > 0`) list access spec의 `access_pred`에서 push-down된 조건(`remote.col = outer.col`)을 제거. `pt_to_subquery_table_spec_list`에서 `where_part`에서 해당 PT_EQ 노드 제거 후 PRED_EXPR 생성. 전제: T0-1(C-1)에서 PT_DBLINK_INFO 접근 경로 확인 필요. 접근 불가 시 대안: `where_part`에서 corr 패턴 재탐지 후 제거. | `src/parser/xasl_generation.c` `pt_to_subquery_table_spec_list()` | [ ] |

### Step 4 점검

- **T4-1**: XASL 덤프에서 `access pred` 항목에 `_dbl.id = l.id` 조건이 없는지 확인
- **T4-1 전제**: T0-1(C-1) 확인 결과에 따라 구현 방식 확정
- push-down 불가 케이스에서 `access_pred` 기존 유지 확인 (제거 범위 최소화)

---

## Step 5: 직렬화

| ID | 작업 | 파일/위치 | 완료 |
|----|------|-----------|:----:|
| T5-1 | `xasl_to_stream.c`에서 `corr_key_count` / `corr_key_regu_list` pack; `stream_to_xasl.c`에서 unpack. `dblink_spec_node` 직렬화 기존 코드와 대칭 맞춤. | `src/query/xasl_to_stream.c`, `src/query/stream_to_xasl.c` | [ ] |

### Step 5 점검

- pack → unpack 후 `corr_key_count`, `corr_key_regu_list` 값 일치 확인

---

## Step 6: 테스트·검증

| ID | 케이스 | 검증 항목 | 완료 |
|----|--------|-----------|:----:|
| T6-1 | 기본 correlated 스칼라 서브쿼리 | 결과 행 수·값이 AS-IS(push-down 전)와 동일 | [ ] |
| T6-2 | outer 행에 매칭 없음 (0건) | NULL 반환, 에러 없음 | [ ] |
| T6-3 | 앱 `?` 포함 서브쿼리 | 기존 방식(1회 fetch) 유지, regression 없음 | [ ] |
| T6-4 | correlated 아닌 DBLink (단독) | 기존 방식 유지, regression 없음 | [ ] |
| T6-5 | correlation 키 = NULL | NULL 반환, re-execute 스킵 | [ ] |
| T6-6 | 대용량 원격 테이블 | 원격 전송 행 수 감소 확인 | [ ] |
| T6-7 | `use_dblink_corr_pushdown=no` 설정 | push-down 미적용, AS-IS(1회 전체 fetch) 동작 및 결과 동등성 확인 | [ ] |

### Step 6 점검 SQL

```sql
-- [T6-1] 기본 케이스: 결과 동등성
SELECT l.id, l.name,
  (SELECT r.name FROM remote_t@cubrid_conn r WHERE r.id = l.id LIMIT 1) AS remote_name
FROM local_t l;

-- [T6-2] 매칭 없음: NULL 반환
SELECT l.id,
  (SELECT r.name FROM remote_t@cubrid_conn r WHERE r.id = l.id LIMIT 1)
FROM local_t l WHERE l.id = 99999;

-- [T6-3] 앱 ? 혼합: 기존 방식 유지
SELECT l.id,
  (SELECT r.name FROM remote_t@cubrid_conn r WHERE r.id = l.id AND r.id > ? LIMIT 1)
FROM local_t l;

-- [T6-4] correlated 아닌 DBLink: 기존 방식 유지
SELECT l.id,
  (SELECT r.name FROM remote_t@cubrid_conn r WHERE r.id = 1 LIMIT 1)
FROM local_t l;

-- [T6-5] NULL 키
SELECT l.id,
  (SELECT r.name FROM remote_t@cubrid_conn r WHERE r.id = l.id LIMIT 1)
FROM local_t l WHERE l.id IS NULL;
```

---

## 완료 체크리스트

- [ ] **Step 0** — T0-1 [ ], T0-2 [ ]
- [ ] **Step 1** — T1-1 [ ], T1-2 [ ], T1-3 [ ]
- [ ] **Step 2** — T2-1 [ ]
- [ ] **Step 3** — T3-1 [ ], T3-2 [ ], T3-3 [ ]
- [ ] **Step 4** — T4-1 [ ]
- [ ] **Step 5** — T5-1 [ ]
- [ ] **Step 6** — T6-1 [ ], T6-2 [ ], T6-3 [ ], T6-4 [ ], T6-5 [ ], T6-6 [ ], T6-7 [ ]

---

## 문서 이력

| 일자 | 내용 |
|------|------|
| 2026-03-13 | 초안 작성 |
| 2026-03-13 | Design Doc 기준 정합성 반영: T0-1 내용 교체(C-1~C-5), Step 1 배경 확정(rewrite 유지 옵션 B), T3-2 판별 조건·신규 함수명 명확화, T4-1 전제 조건 추가 |
| 2026-03-16 | FR-9 반영: T1-3(`use_dblink_corr_pushdown` 세션 파라미터), T6-7(파라미터 OFF 시 AS-IS 유지 검증) 추가; PRD 매핑·체크리스트 업데이트 |
| 2026-03-18 | T3-4 제거: 이전 행 키 비교 최적화는 Phase 2 추가 개선 사항 (Design Doc §7.1) — Tasks 범위 밖 |
