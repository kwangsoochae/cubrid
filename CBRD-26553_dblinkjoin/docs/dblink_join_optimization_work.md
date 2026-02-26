# DBLINK 조인 최적화 — 작업 설명서

상세 요약은 [dblink_join_optimization_summary.md](dblink_join_optimization_summary.md) 참고. 구현 단계·자료 구조(구조체·Step)는 [dblink_join_optimization_plan.md](dblink_join_optimization_plan.md) 참고.

---

## 1. 개요

### 1.1 목적
로컬 테이블과 dblink(원격) 테이블을 조인할 때, **원격 테이블 전체**를 한 번에 가져와 로컬에서 조인 조건을 평가하는 대신, **조인 키를 원격 쿼리에 바인딩**해 **조인 조건을 만족하는 행만** 원격에서 가져오도록 변경한다.

### 1.2 기대 효과
- 원격으로 전송·수신하는 데이터량 감소.
- 로컬에서의 조인 조건 평가(필터) 부담 감소.
- Nested loop에서 inner가 dblink일 때, outer 행마다 “해당 키만” 원격 execute → 네트워크·원격 부하 감소.

---

## 2. 현재 동작 정리

### 2.1 리모트·로컬 조인 흐름
- 로컬에서 `remote_t@conn` 과 로컬 테이블을 조인하면, **원격 쿼리**는 (푸시된 WHERE가 없다면) `SELECT * FROM remote_t` 형태로 **한 번** 실행되고, 결과셋 전체가 로컬로 넘어온다.
- 조인 조건(예: `local_t.id = remote_t.id`)은 **로컬에서** 각 (outer, inner) 조합에 대해 평가된다. 즉, 원격은 “테이블 전체”만 제공하고, 조인은 로컬에서 수행된다.

**조인 조건 푸시 제한**: `view_transform.c`에서 **ON condition** (`term->info.expr.location > 0`)은 푸시 대상에서 **아예 제외**됨. 즉 `JOIN ... ON remote.x = local.y` 는 copy-push 후보가 아니며, **WHERE**에 있는 조건만 푸시 후보. ON 조건 푸시는 별도 확장 검토 필요.

**dblink의 위치**: dblink는 조인 대상에서 제외되지 않으며 FROM의 한 spec으로 유지된다. 다만 correlated term(조인 조건 등)은 원격으로 푸시되지 않아, 실행 시 원격 쿼리는 한 번만 실행되고(uncorrelated와 유사), 조인 조건은 로컬에서 평가된다.

### 2.2 현재 실행기 동작 — "다음 레코드" 요청

- Executor가 inner(dblink)에 "다음 레코드"를 요청하면:
  - `scan_next_dblink_scan` → `dblink_scan_next`로 이미 한 번 가져온 **원격 결과셋**에서 `cci_fetch`로 다음 행을 가져온다.
  - 가져온 행에 대해 `scan_pred.pr_eval_fnc`로 predicate(조인 조건 포함)를 평가하고, `scan_id->vd`(현재 outer 행)와 비교해 만족하지 않으면 **continue**로 버리고 다음 행을 fetch한다.
- outer가 바뀔 때마다 `scan_reset_scan_block`(S_DBLINK_SCAN) → `dblink_scan_reset`으로 **원격 결과셋 커서가 처음으로 돌아간다**.
- 따라서 **매 outer 행마다** "이미 가져온 원격 결과 전체"를 **처음부터 순차 스캔**하며 조인 조건을 만족하는 행만 반환한다. 조인 조건을 만족하는 행이 없으면 해당 outer에 대해 **원격 결과 전체를 한 번 full scan**한 뒤 S_END가 된다.
- 참고: `scan_manager.c` `scan_next_dblink_scan`(약 7085행), predicate 평가 및 continue(7096–7145).

### 2.3 현재 vs 목표 흐름도

```
[현재]
  로컬 outer next → (원격은 이미 1회 execute 완료) → 원격 결과셋에서 fetch → 로컬에서 조인 조건 평가
       → 불일치 시 다음 fetch 반복 (같은 원격 결과셋 내 순차 스캔)
  outer 변경 시 → 원격 결과셋 커서만 처음으로 reset → (다시 fetch + 로컬 평가 반복)

[목표]
  로컬 outer next → inner(dblink) reset 시점에 "현재 outer 행의 조인 키"로 rebind → 원격 execute
       → 원격에서는 "조인 조건 만족 행만" 반환 → 로컬에서는 fetch만 하면 됨 (로컬 full scan 제거)
```

### 2.4 관련 코드 위치 및 호출 경로

- **푸시 조건 식별**: `src/parser/view_transform.c` — correlated term 제외, copy-push 후보 식별.
- **XASL dblink 스펙**: `src/parser/xasl_generation.c` — dblink 노드, host_var 등.
- **옵티마이저**: 별도 처리 불필요. `join_key_count > 0`이 open/reset 분기 조건으로 직접 사용됨.
- **실행기**: `src/query/dblink_scan.c` (open/reset/next), `src/query/scan_manager.c` (scan_next_dblink_scan, scan_reset_scan_block).
- **데이터 구조**: `src/query/xasl.h`의 `dblink_node` — `host_var_count`, `host_var_index`, `conn_sql`, `conn_url`, `join_key_count` (int), `join_key_regu_list` 등. `join_key_count > 0`이면 reset 시점에 outer 행의 값으로 rebind. **PT 확장**: `src/parser/parse_tree.h`의 `PT_DBLINK_INFO` — `join_key_local_ref_count`, `join_key_local_refs` (i번째 `?`에 대응하는 로컬 측 노드). **실행기 확장**: `src/query/dblink_scan.h`의 `DBLINK_SCAN_INFO` — open 시 spec에서 복사하는 `join_key_count`, `join_key_regus`. 추가된 구조·필드 상세는 [dblink_join_optimization_plan.md](dblink_join_optimization_plan.md)의 자료 구조 섹션 참고.

### 2.5 옵티마이저·조인 순서·적용 범위

- **outer/inner 결정**: FROM 순서가 아니라 **옵티마이저가 비용으로 정한 조인 순서**로 결정된다. (`query_planner.c`의 `qo_find_best_nljoin_inner_plan_on_info`, `qo_nljoin_cost` 등. 예외: `PT_HINT_ORDERED` 시 left-to-right.)
- **dblink의 취급**: 옵티마이저는 dblink를 **일반 테이블처럼** 한 노드로 취급한다. **통계는 원격을 사용하지 않고** 고정 추정값만 사용한다 (`query_graph.c` `qo_add_node`, PT_DBLINK_TABLE: NCARD=1000, TCARD=100). dblink를 반드시 inner/outer로 강제하거나 막는 로직은 없다.
- **본 최적화 적용 조건**: **dblink가 inner인 경우에만** "매 outer 행마다 rebind 후 원격 execute"가 의미 있다. dblink가 outer이면 기존처럼 한 번 실행 후 스트리밍만 하면 되므로, rebind 최적화는 **dblink가 inner일 때만** 적용하면 된다. **푸시된 predicate에 앱 host 변수(PT_HOST_VAR, 예: `remote.col = ?`에서 앱이 넘기는 `?`)가 있으면** 조인 키 푸시 최적화를 적용하지 않고 기존 방식(open에서 bind+execute) 유지한다. (1차 작업에서는 앱 ?와 조인 키 푸시를 혼합하지 않음.)

---

## 3. 목표 동작

### 3.1 원하는 흐름
- Nested loop에서 **inner가 dblink**일 때: outer 행이 바뀔 때마다, **현재 outer 행의 조인 키**를 원격 쿼리의 `?`에 binding한 뒤 **원격 execute**를 수행한다.
- 원격 쿼리는 이미 `WHERE remote_key = ?` 형태로 푸시되어 있으므로, **조인 조건을 만족하는 행만** 결과로 온다. 로컬에서는 해당 커서에서 fetch만 하면 된다.

### 3.2 Outer 행 변경 시점과 Rebind 시점
- Rebind 시점: **inner(dblink) 스캔의 reset**이 호출될 때. 즉 `scan_reset_scan_block(S_DBLINK_SCAN)` → `dblink_scan_reset` 등에서, 현재 outer 행(vd)에서 조인 키 값을 읽어 `cci_bind` 후 `cci_execute` 호출.

### 3.3 제약/고려사항
- 조인 조건 중 "원격 컬럼 = 로컬 컬럼" 형태를 `?` 하나로 푸시 가능한 경우만 적용 (복합 키는 단계적 확장 가능).
- **앱 host 변수(?)와 조인 키 푸시**: 푸시된 predicate에 앱 `?`가 있으면 조인 키 푸시 최적화를 적용하지 않고 기존 경로만 사용한다. (앱 ?가 없고 조인 키 푸시만 있을 때만 reset 시 rebind 경로 적용.)
- Nested loop의 inner가 dblink일 때, **outer 행이 바뀔 때마다** rebind + re-execute 필요.
- 기존 "한 번 execute 후 cursor로만 fetch" 경로와의 호환성 유지 (푸시 불가 쿼리는 기존 방식 유지).
- **Gateway(Oracle/MySQL)**: 원격이 CUBRID가 아니라 Gateway 경유 Oracle/MySQL이어도, 서버는 동일하게 CCI prepare/bind/execute/fetch를 사용하므로, 이 최적화가 적용되면 Gateway 경유 조인에도 동일하게 이득이 있음.
- **outer 조인 키가 NULL인 경우**: 로컬 조인과 동일하게 처리. reset 시 조인 키가 NULL이면 원격 execute 스킵(매칭 0건). 3-2 구현 시 반영.
- **에러 처리**: rebind/execute 실패 시 원격 연결·stmt 정리 및 에러 전파 방식 정리.

### 3.4 위험·롤백
- 푸시 조건 식별 오류 시 원격 쿼리 실행 실패 또는 **결과 불일치** 가능. 푸시 가능 조건을 위와 같이 정의하고, 불명확한 경우 기존 방식(전체 fetch)으로 유지하는 것이 안전함.

### 3.5 조인 키 푸시 구현 개요

- **Parser / view_transform**
  - WHERE(및 향후 ON)에서 "원격 컬럼 = 로컬 컬럼" 형태의 등치 조건을 푸시 후보로 식별. 기존 correlated 제외를 "원격=로컬"인 경우 예외로 푸시 가능하도록 확장.
  - 푸시 시 원격 쿼리(rewritten)에는 `remote.col = ?`만 넣고, 로컬 쪽에는 "?에 넣을 값 = 로컬 조인 키 regu" 정보를 남김. 결과: `pushed_pred`, `rewritten`(예: `SELECT * FROM (...) cublink WHERE id = ?`).
- **XASL 생성**
  - dblink spec: `conn_sql`(또는 rewritten)에 `WHERE id = ?` 포함. `join_key_count`, `join_key_regu_list`로 "i번째 `?` ← outer 컬럼 REGU_VARIABLE" 연결. `join_key_count > 0`이 분기 조건.
- **실행기**
  - **open**: `join_key_count > 0`인 dblink는 `cci_prepare`만 수행, execute는 하지 않음(첫 execute는 reset 시점으로 지연).
  - **scan_reset_scan_block(S_DBLINK_SCAN)**: `join_key_count > 0`이면 `fetch_peek_dbval(join_key_regus[i], vd)`로 조인 키를 읽어 `?`에 rebind 후 `cci_execute`. 이후 해당 결과 커서만 사용.
  - **scan_next_dblink_scan**: 푸시된 경우 이미 "조인 조건 만족 행만" 오는 커서에서 `cci_fetch`만 하면 됨(로컬 full scan 제거).

---

## 4. 작업 항목 (구현 시 참고)

**구현 상태**: 단계별·구조체 반영할 내용은 [dblink_join_optimization_plan.md](dblink_join_optimization_plan.md)의 「구현 반영 사항」 참고.

### 4.1 Parser / View transform
- 조인 조건(원격 컬럼 = 로컬 컬럼)을 푸시 후보로 식별. (현재는 correlated로 제외되는지 확인 후, 푸시 허용 경로 추가.)
- 푸시 시 rewritten 원격 쿼리에 `?` 반영, 로컬 쪽에 host_var 대응 정보(어느 regu가 어떤 `?`에 바인딩되는지) 유지.

### 4.2 XASL 생성
- dblink 노드에 `conn_sql`(푸시된 WHERE 포함), `join_key_count`, `join_key_regu_list` 반영 (`join_key_count > 0`이 분기 조건).

### 4.3 실행기 (Scan / Executor)
- **open 시점**: dblink 스캔 open 시에는 **prepare만** 수행하고, execute는 **첫 번째 `scan_reset_scan_block`(S_DBLINK_SCAN) 호출 시** 수행(outer dependent dblink인 경우).
- **reset 시점**: outer dependent dblink는 vd에서 조인 키를 읽어 rebind 후 `cci_execute`.
- **next 시점**: 푸시된 경우 기존처럼 fetch만 수행(로컬 predicate 평가 생략 가능하도록 또는 유지).

### 4.4 플랜/스펙
- 플랜에 "dblink inner + 조인 키 푸시" 정보가 유지되는지 확인. 필요 시 스펙 확장.

### 4.5 테스트·검증 항목
- 푸시 가능 조인 쿼리: 결과 행 수·값이 기존(전체 fetch 후 로컬 조인)과 동일한지.
- 푸시 불가 쿼리: 기존과 동일 동작(한 번 execute, 로컬 조인).
- Gateway 경유 조인 동일 시나리오.

---

## 4.6 작은 단위 작업 분할 (권장 순서)

아래는 한 번에 하나씩 완료·검증할 수 있도록 나눈 단위이다. 각 단위 완료 후 빌드·기존 테스트 통과를 확인하는 것을 권장한다.

### Step 0: 사전 확인 및 인프라 (선택)
- **0-1** `view_transform.c`에서 "원격 컬럼 = 로컬 컬럼" 조건이 현재 correlated로 제외되는지 코드로 확인.
- **0-2** `xasl.h`의 `dblink_node`에 `host_var_count`, `host_var_index[]` 등이 이미 있는지 확인; `join_key_count` (int), `join_key_regu_list` (REGU_VARIABLE_LIST) 추가.

### Step 1: 푸시 조건 식별 (Parser / View transform)
- **1-1** "원격 컬럼 = 로컬 컬럼" 등치 조건을 푸시 **후보**로만 식별 (아직 푸시 적용은 하지 않음). 푸시 후보 플래그/구조만 추가.
- **1-2** 푸시 후보인 경우, rewritten 원격 쿼리에 `remote.col = ?` 형태 반영. 로컬 쪽에 "i번째 `?` ← 로컬 조인 키 regu" 매핑 정보 유지 (`pushed_pred` / host_var 대응).

### Step 2: XASL에 반영
- **2-1** dblink 노드에 푸시된 `conn_sql`(WHERE `?` 포함), `join_key_count`, `join_key_regu_list` 저장 (`join_key_count > 0`이 이후 open/reset 분기 조건).

### Step 3: 실행기 — Open / Reset / Next
- **3-1** **Open**: `join_key_count > 0`인 dblink일 때 `cci_prepare`만 수행, `cci_execute`는 호출하지 않음.
- **3-2** **Reset** (`scan_reset_scan_block(S_DBLINK_SCAN)` → `dblink_scan_reset`): `join_key_count > 0`이면 vd에서 `fetch_peek_dbval`로 조인 키를 읽어 `cci_bind` 후 `cci_execute`.
- **3-3** **Next**: 푸시된 경우 기존 fetch 경로 유지 (로컬 predicate 평가는 일단 유지 후, 필요 시 "`join_key_count > 0`이면 생략"으로 최적화).

### Step 4: 플랜·스펙 검증
- **4-1** 플랜에 "dblink inner + 조인 키 푸시" 정보가 끝까지 유지되는지 확인. 필요 시 스펙 확장.

### Step 5: 테스트·검증
- **5-1** 푸시 가능 조인 쿼리: 결과 행 수·값이 기존(전체 fetch 후 로컬 조인)과 동일한지.
- **5-2** 푸시 불가 / 기존 단일 dblink: regression 없음.
- **5-3** (선택) Gateway 경유 조인, 성능(원격 전송 행 수 감소) 확인.

**의존 관계 요약**: Step 1 → Step 2 → Step 3 이 순서로 진행하는 것이 자연스럽다. Step 0은 병렬로 진행 가능. Step 4는 2·3과 함께 진행 가능. Step 5는 3 완료 후 또는 각 Step 완료 시점에 소규모 검증을 넣을 수 있다.

---

## 5. 테스트 케이스 설계

### 5.1 환경 준비
- 로컬 DB, 원격 DB(또는 Gateway 경유), dblink 연결 설정.

### 5.2 기준 데이터
- 로컬: 소량(예: id 1~5). 원격: id별 0건/1건/다건 매칭 혼합.

### 5.3 케이스별 SQL과 기대 결과
- (1) 푸시 가능: `WHERE local.id = remote.id` → 결과 행 수·값 일치.
- (2) 0건 매칭 포함(inner join) → 해당 outer 행 없음.
- (3) 1:N 매칭 → 행 수 일치.
- (4) LEFT JOIN(ON 조건, 푸시 미적용) → 기존 동작 유지.
- (5) 로컬만 조인(비교용) → 동일 스키마일 때 결과 일치.

### 5.4 regression·호환성
- 푸시 불가 쿼리, 기존 단일 dblink 쿼리 regression 없음.

### 5.5 성능·동작 확인
- 원격 전송 행 수 감소, 실행 계획에 rebind/execute 반영 여부.

---

## 6. 참고 코드 위치 요약

| 구분 | 파일 | 비고 |
|------|------|------|
| 푸시 조건·correlated | view_transform.c | copy-push, term 제외 로직 |
| PT dblink 정보 확장 | parse_tree.h | PT_DBLINK_INFO, join_key_local_refs |
| XASL dblink | xasl_generation.c | dblink spec, host_var |
| dblink_node | xasl.h | conn_sql, host_var_count, host_var_index, join_key_count (int), join_key_regu_list |
| dblink 스캔 구조·open/reset/next | dblink_scan.h, dblink_scan.c | DBLINK_SCAN_INFO 확장, cci_prepare, execute, fetch |
| 스캔 next/reset 호출 | scan_manager.c | scan_next_dblink_scan, scan_reset_scan_block(S_DBLINK_SCAN) |
| 스캔 next 호출 경로 | scan_manager.c | scan_next_dblink_scan, dblink_open_scan 호출 |
| 조인 실행 | query_executor.c | nested loop, list_id, 스캔 next 호출 |
| dblink 카디널리티 추정 | query_graph.c | qo_add_node, PT_DBLINK_TABLE(NCARD=1000, TCARD=100) |
| 현재 "다음 레코드"·predicate 평가 | scan_manager.c | scan_next_dblink_scan, vaidp->scan_pred.pr_eval_fnc |

---

## 7. 문서 이력

| 일자 | 작성/수정 | 내용 |
|------|-----------|------|
| TBD | TBD | 초안 작성 — dblink 조인 최적화 작업 설명서 |
| TBD | TBD | 보완: 흐름도, on_cond/WHERE 구분, 호출 경로·dblink_node, Gateway·테스트·위험 반영, 통합 |
| TBD | TBD | 조인 순서(옵티마이저), 현재 실행(full scan per outer), 카디널리티(고정값), 조인 키 푸시 구현 개요·적용 조건(dblink=inner) 반영 |
