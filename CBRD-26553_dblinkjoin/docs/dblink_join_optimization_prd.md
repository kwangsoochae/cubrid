# DBLINK 조인 최적화 — PRD (Product Requirements Document)

| 항목 | 내용 |
|------|------|
| 제목 | DBLINK 조인 키 푸시 최적화 |
| 이슈 | CBRD-26553 |


---

## 1. 개요

### 1.1 목적

로컬 테이블과 dblink(원격) 테이블을 조인할 때, **원격 테이블 전체**를 한 번에 가져와 로컬에서 조인 조건을 평가하는 대신, **조인 키를 원격 쿼리에 바인딩**해 **조인 조건을 만족하는 행만** 원격에서 가져오도록 변경한다.

### 1.2 한 줄 요약

리모트 테이블 **전체**를 가져와 로컬에서 조인하는 대신, **prepare + 조인 키 binding**으로 **조인 조건을 만족하는 행만** 원격에서 가져오도록 변경.

### 1.3 용어: 푸시

<strong>푸시(push)</strong>란, 조인 조건·필터 조건처럼 로컬에서 평가하던 조건을 원격에서 실행되는 쿼리(원격 SQL) 쪽으로 넘겨, 원격 DB에서 해당 조건으로 필터링하도록 하는 것을 말한다. 이번 최적화에서는 **"원격 컬럼 = 로컬 컬럼"** 형태의 조인 조건을 원격 쿼리의 **WHERE 절에 `remote.col = ?`** 로 넣고, **실행 시 `?`에는 로컬 행의 조인 키 값을 바인딩**한다. 그 결과 원격은 "조인 조건을 만족하는 행만" 반환하고, 로컬은 전체를 가져와 다시 걸러낼 필요가 없어진다.

---

## 2. 배경 및 문제

### 2.1 현재 동작

- 로컬에서 `remote_t@conn`과 로컬 테이블을 조인하면, 원격 쿼리는 (푸시된 WHERE가 없다면) `SELECT * FROM remote_t` 형태로 **한 번** 실행되고, **결과셋 전체**가 로컬로 전달된다.
- 조인 조건(예: `local_t.id = remote_t.id`)은 **로컬에서** 각 (outer, inner) 조합에 대해 평가된다. 즉 원격은 “테이블 전체”만 제공하고, 조인은 로컬에서 수행된다.
- outer가 바뀔 때마다 **원격 결과셋 커서만 처음으로 reset**되고, **매 outer 행마다** 이미 가져온 원격 결과 전체를 **처음부터 순차 스캔**하며 조인 조건을 만족하는 행만 반환한다.

### 2.2 문제점

- **원격 전송·수신 데이터량**: 원격 테이블 전체가 로컬로 오므로 불필요한 데이터 전송이 발생한다.
- **로컬 부하**: Nested loop에서 inner가 dblink인 경우, 매 outer 행마다 원격 결과 전체를 스캔하며 조인 조건을 평가해야 한다.
- **네트워크·원격 부하**: Nested loop에서 inner가 dblink일 때, 한 번에 큰 결과셋을 받는 구조로 인해 비효율이 발생한다.

### 2.3 제약(현재)

- `view_transform.c`에서 **ON condition**은 푸시 대상에서 제외되며, **WHERE**에 있는 조건만 푸시 후보이다.
- correlated term(조인 조건 등)은 원격으로 푸시되지 않아, 실행 시 원격 쿼리는 한 번만 실행되고 조인 조건은 로컬에서 평가된다.
- **XASL 구조 제약**: `mq_rewrite_dblink_as_subquery`(`view_transform.c:8584`)가 optimizer/XASL 생성 이전에 실행되어 dblink spec을 `PT_DERIVED_DBLINK_TABLE` → `PT_IS_SUBQUERY`(wrapper PT_SELECT)로 변환한다. 결과적으로 dblink ACCESS_SPEC이 `aptr_list`(uncorrelated buildlist) 내부에 위치하게 되어 NL join 실행 중 `scan_reset_scan_block`이 dblink_scan에 닿지 못한다. 이를 해결하기 위해 push-down 후보 spec에 대해 rewrite를 우회하여 dblink spec을 `scan_ptr`에 직접 두어야 한다(XASL dblink spec 변경, FR-8).

---

## 3. 목표 및 성공 기준

### 3.1 목표 동작

- Nested loop에서 **inner가 dblink**일 때: outer 행이 바뀔 때마다, **현재 outer 행의 조인 키**를 원격 쿼리의 `?`에 binding한 뒤 **원격 execute**를 수행한다.
- 원격 쿼리는 `WHERE remote_key = ?` 형태로 푸시되어 있으므로, **조인 조건을 만족하는 행만** 결과로 온다. 로컬에서는 해당 커서에서 fetch만 하면 된다.

### 3.2 기대 효과

- 원격으로 전송·수신하는 **데이터량 감소**.
- 로컬에서의 **조인 조건 평가(필터) 부담 감소**.
- Nested loop에서 inner가 dblink일 때, outer 행마다 “해당 키만” 원격 execute → **네트워크·원격 부하 감소**.

### 3.3 성공 기준

- **정확성**: 푸시 가능한 조인 쿼리의 결과 행 수·값이 기존(전체 fetch 후 로컬 조인)과 **동일**하다.
- **호환성**: 푸시 불가 쿼리, 기존 단일 dblink 쿼리는 **regression 없이** 기존과 동일하게 동작한다.

---

## 4. 적용 범위

### 4.1 적용 조건

- **Nested loop에서 inner가 dblink인 경우에만** “매 outer 행마다 rebind 후 원격 execute”를 적용한다.
- dblink가 outer이면 기존 방식(한 번 실행 후 스트리밍) 유지.
- 푸시된 predicate에 앱 host 변수(PT_HOST_VAR, 사용자가 SQL문에 ? 표현)가 있으면 조인 키 푸시 최적화를 적용하지 않고 기존 방식(open에서 bind+execute) 유지. (1차 작업에서는 앱 `?`와 조인 키 푸시를 혼합하지 않음.)

### 4.2 In Scope (1차)

- WHERE에서 “원격 컬럼 = 로컬 컬럼” 형태의 **단일 등치** 조인 조건을 `?`로 푸시.
- Parser(view_transform) → XASL 생성 → 실행기(open/reset/next) 전 구간 반영.
- Gateway(Oracle/MySQL) 경유 조인: 서버는 동일하게 CCI prepare/bind/execute/fetch를 사용하므로, 이 최적화 적용 시 동일 이득.
- **outer 조인 키가 NULL인 경우**: 로컬 조인과 동일. reset 시 조인 키가 NULL이면 원격 execute 스킵(매칭 0건). Step 3-2 구현 시 반영.

### 4.3 Out Scope / 향후 확장
현
- **ON condition** 푸시: 별도 확장 검토.
- **복합 조인 키**·OR 조건: 단계적 확장.
- 앱 `?`와 조인 키 푸시 혼합: 1차에서 미지원.
- **SELECT 절 correlated 서브쿼리**: `SELECT (SELECT col1 FROM remote_t@dblink WHERE col2 = a.col2) FROM t1 a` 처럼 FROM 절이 아닌 서브쿼리 안 dblink에 대해, correlated 컬럼(outer ref)을 원격 `?`에 바인딩해 행마다 rebind+execute 하는 확장. Parser(서브쿼리 경로)·XASL(서브쿼리 노드 스펙)·실행기(서브쿼리 재평가 시 rebind 로직 추가) 추가 수정 필요.

---

## 5. 요구사항

### 5.1 기능 요구사항

| ID | 요구사항 | 우선순위 |
|----|----------|----------|
| FR-1 | “원격=로컬” 등치를 푸시 후보로 식별·푸시 시 원격 쿼리에 `remote.col = ?` 반영. | Must |
| FR-3 | 조인 키 푸시·dblink가 NL inner일 때 dblink spec에 `join_key_count > 0` 조건으로 분기(PT_HOST_VAR 있으면 join_key_count = 0 유지). | Must |
| FR-4 | `join_key_count > 0`인 dblink open 시 prepare만, execute는 reset으로 지연. spec→scan_info에 join_key_count·join_key_regus 복사. | Must |
| FR-5 | reset 시 vd에서 조인 키 읽어 dblink_bind_param 후 cci_execute. dblink_scan_reset(scan_info, vd) vd 인자 추가. | Must |
| FR-6 | 푸시 불가 또는 앱에서 `?` 가 포함된 쿼리를 사용한 경우는 기존 방식(open에서 bind+execute) 유지, regression 없음. | Must |
| FR-7 | 푸시 조인 결과(행 수·값)가 기존 전체 fetch 후 로컬 조인과 동일. | Must |
| FR-8 | **XASL dblink spec 변경**: push-down 후보 dblink가 NL inner일 때, outer 행 교체마다 dblink를 재실행할 수 있도록 dblink scan을 `scan_ptr` 체인에 직접 배치한다. 이를 위해 `mq_rewrite_dblink_as_subquery` 내에서 해당 spec의 `PT_IS_SUBQUERY` 변환을 생략하여 `PT_DERIVED_DBLINK_TABLE` 타입을 유지한다. 비후보(앱 `?` 혼합, 조인 키 없음 등)는 기존 변환 유지. | Must |

### 5.2 비기능 요구사항

| ID | 요구사항 | 우선순위 |
|----|----------|----------|
| NFR-1 | 기존 “한 번 execute 후 cursor로만 fetch” 경로와 호환성을 유지한다. | Must |
| NFR-2 | 푸시 조건이 불명확한 경우 기존 방식(전체 fetch)으로 유지하여 결과 불일치 위험을 제거한다. | Must |
| NFR-3 | rebind/execute 실패 시 에러 설정 후 상위로 전파하고, 필요 시 stmt/conn 정리를 한다. | Should |

---

## 6. 제약·가정

- 조인 순서는 **옵티마이저**가 비용으로 결정하며, dblink를 inner/outer로 강제하는 로직은 없다.
- dblink 카디널리티는 원격 통계를 쓰지 않고 고정 추정값(NCARD=1000, TCARD=100)을 사용한다.
- **host_var_count**, **host_var_index**는 앱 `?`용과 조인 키용이 **동시에 쓰이지 않으므로** 동일 필드를 공유한다.
- 원격은 CUBRID뿐 아니라 Gateway 경유 Oracle/MySQL이어도, 서버는 CCI 인터페이스로 동일하게 제어한다.

---

## 7. 위험 및 완화

| 위험 | 영향 | 완화 |
|------|------|------|
| 푸시 조건 식별 오류 | 원격 쿼리 실행 실패 또는 **결과 불일치** | 푸시 가능 조건을 명확히 정의하고, 불명확한 경우 기존 방식(전체 fetch) 유지 |
| outer vd 슬롯 매핑 오류 | 잘못된 값 바인딩 → 결과 오류 | 1차는 단일 조인 키, outer 첫 컬럼(vd 슬롯 0 만 사용)으로 제한; 향후 join_key_local_refs 기반으로 복합 조인 키 보완 |
| `mq_rewrite_dblink_as_subquery` 우회 오판 | 비후보 spec이 rewrite 생략되어 **기존 경로 파손** | `pt_is_dblink_join_key_equality` 탐지 조건을 보수적으로 정의; 비후보는 반드시 기존 rewrite 수행; T5-2 regression 테스트로 검증 |

---

## 8. 구현 단계 요약

구현 상세는 [dblink_join_optimization_plan.md](dblink_join_optimization_plan.md) 참고.

| 단계 | 내용 |
|------|------|
| Step 0 | 사전 확인: view_transform correlated+dblink 제외, xasl.h dblink_node 구조 및 `join_key_count`·`join_key_regu_list` 추가 |
| Step 1 | 푸시 조건 식별: “원격=로컬” 푸시 허용, rewritten에 `?` 반영 및 join_key_local_refs 매핑 |
| Step 2 | XASL 반영: conn_sql·join_key_regu_list 채우기 (`join_key_count > 0`이 분기 조건) |
| Step 3 | 실행기: Open(prepare만), Reset(rebind+execute), Next(fetch·predicate 유지) |
| Step 4 | **XASL dblink spec 변경**: `mq_rewrite_dblink_as_subquery` 내에서 push-down 후보 spec의 `PT_IS_SUBQUERY` 변환을 생략하여 dblink scan을 `scan_ptr`에 직결; `gen_inner`에 `is_generating_dblink_inner_scan` 플래그 set/clear; 플랜/스펙 검증 |
| Step 5 | 테스트·검증: 푸시 가능/불가/regression/성능 |


---

## 9. 테스트 요구사항

- **환경**: 로컬 DB, 원격 DB(또는 Gateway), dblink 연결 설정.
- **케이스**: 푸시 가능 조인(결과 일치), 0건 매칭, 1:N 매칭, LEFT JOIN(기존 동작), 푸시 불가/단일 dblink(regression 없음).
- **검증**: 원격 전송 행 수 감소, 실행 계획에 rebind/execute 반영 여부.

---

## 10. 참고 문서

- [dblink_join_optimization_summary.md](dblink_join_optimization_summary.md) — 요약
- [dblink_join_optimization_tasks.md](dblink_join_optimization_tasks.md) — 태스크 목록 및 점검 항목
- [dblink_join_optimization_work.md](dblink_join_optimization_work.md) — 작업 설명서, 현재/목표 동작, 테스트 설계
- [dblink_join_optimization_plan.md](dblink_join_optimization_plan.md) — 상세 구현 계획, 자료 구조, Step별 구현

---

## 11. 문서 이력

| 일자 | 작성/수정 | 내용 |
|------|-----------|------|
| TBD | TBD | PRD 초안 작성 |
| TBD | TBD | XASL dblink spec 변경 반영: 2.3 구조적 제약 추가, FR-8 추가, 위험 항목 추가, Step 4 설명 업데이트, TASKS 참고 문서 추가 |
