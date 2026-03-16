# DBLink Correlated 서브쿼리 최적화 — PRD

| 항목 | 내용 |
|------|------|
| 제목 | DBLink Correlated 스칼라 서브쿼리 — Correlation 키 푸시 최적화 |
| 이슈 | CBRD-26601 |
| 기준 브랜치 | develop |

---

## 1. 개요

### 1.1 목적

`SELECT` 절 또는 `WHERE` 절에 `(SELECT col FROM remote_t@conn WHERE remote_t.id = l.id LIMIT 1)` 형태의 **correlated 스칼라 서브쿼리**가 있을 때, 현재는 원격 테이블 전체를 **1회 fetch**하여 로컬에서 필터링하는 구조이다. 이를 **outer 행마다 correlation 키를 바인딩 후 원격 execute**하는 방식으로 변경하여, 원격 전송 데이터량과 로컬 연산을 줄인다.

### 1.2 한 줄 요약

원격 테이블 **전체 1회 fetch → 로컬 N회 필터** 구조를 **outer 행마다 `WHERE col = ?` 바인딩 후 원격 execute** 구조로 교체.

### 1.3 용어

| 용어 | 설명 |
|------|------|
| **Correlated 서브쿼리** | 외부 쿼리의 컬럼을 참조하는 서브쿼리 (`WHERE remote.id = l.id` 에서 `l.id`가 outer 참조) |
| **Correlation 키** | 서브쿼리가 outer를 참조하는 컬럼 쌍 (`remote.col = outer.col`) |
| **푸시(push)** | 로컬에서 평가하던 조건을 원격 SQL의 `WHERE col = ?`로 넣어 원격 DB에서 필터링하게 하는 것 |
| **aptr** | XASL에서 1회 선행 실행되는 서브쿼리 리스트. 서브쿼리 내 dblink는 현재 여기에 배치됨 |
| **dptr** | XASL에서 outer 행마다 재실행되는 correlated 서브쿼리 |

---

## 2. 배경 및 문제

### 2.1 현재 동작 (AS-IS)

```
outer 스캔 시작
  └─ aptr 실행 (1회)
       └─ dblink: cci_prepare + cci_execute('SELECT col FROM remote_t')
            └─ 결과 전체 → local list

outer 각 행마다
  └─ dptr(LINK_TO_REGU_VARIABLE) 재평가
       └─ local list 스캔
            ├─ access_pred: remote.id = l.id  ← 로컬 필터
            └─ instnum: inst_num() <= 1
```

- DBLink가 `0x40269c00`(래퍼)의 **aptr_list**에 배치되어, `IS_XASL_INITIAL_STATUS` 체크에서 첫 outer 행 시점에만 실행되고 이후는 **skip** 됨 (`query_executor.c:15292`).
- `qexec_clear_xasl_head` (`query_executor.c:1395`)가 래퍼(0x40269c00) status만 CLEARED로 리셋하고, **aptr DBLink(0x40249d60)는 건드리지 않으므로** 재실행 없이 동일 list를 N회 재스캔.
- 원격 쿼리 (`conn_sql`)에는 `WHERE id = ?`가 없음 — correlation 조건이 로컬 `access_pred`로만 존재.

### 2.2 문제점

| 문제 | 영향 |
|------|------|
| 원격 테이블 **전체 전송** | 원격 행이 많을수록 네트워크 전송량 낭비 |
| 로컬 **N회 리스트 스캔** | outer 행 수만큼 local list를 처음부터 스캔 |
| **매칭율 낮을수록 비효율** | 실제 필요한 행은 1~수 건이지만 전체를 받음 |

### 2.3 구조적 제약

- `mq_rewrite_dblink_as_subquery` (`view_transform.c:6607`)가 **모든** `PT_DERIVED_DBLINK_TABLE`을 `PT_IS_SUBQUERY`로 변환 → DBLink가 항상 **list access** 경로(`pt_to_subquery_table_spec_list`)를 거침.
- Correlation 조건(`_dbl.id = l.id`)은 list access spec의 **`where` predicate**(로컬 필터)로만 생성되며, DBLink SQL(`conn_sql`)에는 반영되지 않음.
- `dblink_spec_node` / `DBLINK_SCAN_INFO` (develop 기준)에 **rebind/re-execute 관련 필드 없음**.

---

## 3. 목표 및 성공 기준

### 3.1 목표 동작 (TO-BE)

```
outer 스캔 시작
  └─ dblink prepare (1회)

outer 각 행마다
  └─ cci_bind_param(correlation 키 = 현재 outer 행 값)
  └─ cci_execute('SELECT col FROM remote_t WHERE id = ?')
  └─ fetch (최대 1행)
  └─ 스칼라 반환
```

- DBLink가 outer 행마다 **rebind + re-execute** → 원격에서 조건 만족 행만 반환.
- `conn_sql`에 `WHERE remote.col = ?` 포함.
- 로컬 `access_pred`에서 push-down된 조건 제거 (이중 필터 방지).

### 3.2 기대 효과

- **네트워크 전송량**: 전체 테이블 → 매칭 행만 (원격 테이블 크기 · 매칭율에 비례)
- **로컬 연산**: N회 list 전체 스캔 → 불필요 (원격에서 필터)
- **원격 DB 부하**: WHERE 조건 유무로 인덱스 활용 가능성 증가

### 3.3 성공 기준

- **정확성**: 푸시 후 결과 행 수·값이 AS-IS와 **동일**.
- **Regression**: 푸시 불가 쿼리, 단순 DBLink 쿼리 등 기존 동작에 **영향 없음**.
- **NULL 처리**: correlation 키가 NULL인 경우 re-execute 스킵 → 0건 반환 (로컬 조인과 동일).

---

## 4. 적용 범위

### 4.1 In Scope — 1차 작업 (SELECT 절 스칼라 서브쿼리)

- **SELECT 절** correlated 스칼라 서브쿼리 안의 DBLink (`SELECT (SELECT col FROM remote@conn WHERE remote.k = a.k LIMIT 1) FROM t a`)
- correlation 조건: **단일 등치** (`remote.col = outer.col`)
- 앱 `?` (PT_HOST_VAR) 미포함 쿼리

> 본 PRD의 요구사항(5장), 설계(6장), 구현 단계(9장), 테스트(10장)는 모두 1차 작업 기준이다.

### 4.2 2차 작업 (향후 확장)

1차 구현 완료 후 별도 이슈/브랜치로 진행.

| 항목 | 내용 | 비고 |
|------|------|------|
| **WHERE 절 correlated 서브쿼리** | `WHERE EXISTS (SELECT 1 FROM remote@conn WHERE remote.id = l.id)` 등 | 탐지 경로 상이 (`dptr`/predicate); 20~30% 추가 작업 예상 |
| **복합 correlation 키** | AND 등치 여러 개 (`remote.k1 = l.k1 AND remote.k2 = l.k2`) | bind_param 순서 관리 필요 |
| **cost 기반 push-down 선택** | remote NCARD 실측 + 선택도 추정으로 push-down 적용 여부 결정 | 현재는 구조적 조건으로만 판단 |

### 4.3 Out of Scope

| 항목 | 비고 |
|------|------|
| 앱 `?`와 correlation 키 혼합 | 파라미터 번호 충돌; 구조적으로 배제 |
| OR 조건 푸시 | 별도 검토 필요 |

---

## 5. 요구사항

### 5.1 기능 요구사항

| ID | 요구사항 | 우선순위 |
|----|----------|----------|
| FR-1 | correlated 스칼라 서브쿼리 안의 DBLink에서 `remote.col = outer.col` 등치 조건을 탐지하여 push-down 후보로 식별한다. | Must |
| FR-2 | push-down 후보 DBLink의 `conn_sql`에 `WHERE remote.col = ?`를 append한다. | Must |
| FR-3 | `dblink_spec_node` / `DBLINK_SCAN_INFO`에 correlation 키 regu_list 및 count 필드를 추가한다. correlation 키 regu는 outer val_list 슬롯을 참조한다. | Must |
| FR-4 | push-down 후보 DBLink의 open 시 `cci_prepare`만 수행하고, execute는 outer 행 평가 시점으로 지연한다. | Must |
| FR-5 | outer 행 평가 시마다 correlation 키 값을 `vd`에서 읽어 `cci_bind_param` 후 `cci_execute`를 수행한다. | Must |
| FR-6 | correlation 키가 NULL이면 re-execute를 스킵하고 0건(NULL) 반환한다. | Must |
| FR-7 | push-down 불가 쿼리(앱 `?` 포함, 조건 없음 등)는 기존 동작(1회 전체 fetch)을 유지한다. | Must |
| FR-8 | push-down 적용 시 list access spec의 `access_pred`에서 push-down된 조건을 제거한다. | Must |
| FR-9 | 세션 파라미터 `use_dblink_corr_pushdown`(기본값 `yes`)가 `no`이면 correlated push-down을 적용하지 않고 AS-IS 방식(1회 전체 fetch)을 유지한다. | Should |

### 5.2 비기능 요구사항

| ID | 요구사항 | 우선순위 |
|----|----------|----------|
| NFR-1 | push-down 불가 경로와의 완전한 하위 호환성 유지. | Must |
| NFR-2 | re-execute 실패 시 에러 설정 후 상위로 전파, 필요 시 stmt/conn 정리. | Must |
| NFR-3 | 직렬화(`xasl_to_stream.c` / `stream_to_xasl.c`)에 신규 필드 pack/unpack 반영. | Must |

---

## 6. 설계 방향

### 6.1 구조 변경 개요

```
AS-IS                              TO-BE
------                             ------
[래퍼 XASL]                        [래퍼 XASL]
  aptr → [DBLink XASL]               aptr → [DBLink XASL]
           conn_sql: SELECT *                  conn_sql: SELECT * WHERE col=?
           access_pred: col=l.id              corr_key_regu: → outer.val_list[0]
           IS_INITIAL: 첫 행만 실행            IS_INITIAL: 매 행 실행 (status reset)
```

### 6.2 핵심 변경 위치

| 레이어 | 파일 | 변경 내용 |
|--------|------|-----------|
| 파서 | `view_transform.c` | correlated DBLink 등치 조건 탐지 (`remote.col = outer.col`) |
| XASL 생성 | `xasl_generation.c` | `conn_sql`에 `WHERE col = ?` append; `corr_key_regu_list` 채우기 |
| XASL 구조 | `xasl.h` | `dblink_spec_node`에 `corr_key_count`, `corr_key_regu_list` 추가 |
| 런타임 | `dblink_scan.h/c` | `DBLINK_SCAN_INFO`에 corr_key 필드; open 시 prepare만; 재실행 함수 추가 |
| 실행기 | `query_executor.c` | `qexec_clear_xasl_head` 또는 aptr 실행 루프에서 corr DBLink re-execute 처리 |
| 직렬화 | `xasl_to_stream.c`, `stream_to_xasl.c` | 신규 필드 pack/unpack |

### 6.3 AS-IS / TO-BE 실행 횟수

| 단계 | AS-IS | TO-BE |
|------|-------|-------|
| cci_prepare | 1회 | 1회 |
| cci_execute | 1회 (전체 fetch) | N회 (outer 행마다, 조건 포함) |
| 원격 결과 전송 행 수 | 전체 | 매칭 행만 |
| 로컬 list 스캔 | N회 | 불필요 |

---

## 7. 제약 및 가정

- correlation 키 탐지는 **보수적**으로 정의: 불명확한 경우 기존 방식(1회 fetch) 유지.
- 앱 `?` (PT_HOST_VAR)가 서브쿼리 안에 존재하면 correlation 키 푸시를 적용하지 않음.
- 원격은 CUBRID뿐 아니라 Gateway 경유 Oracle/MySQL도 CCI 인터페이스로 동일하게 제어되므로 동일 이득.
- DBLink 카디널리티는 원격 통계 없이 고정 추정값 사용 — 푸시 적용 여부는 비용이 아닌 **구조적 조건**으로 판단.

---

## 8. 위험 및 완화

| 위험 | 영향 | 완화 |
|------|------|------|
| correlation 조건 탐지 오류 | 잘못된 SQL 생성 또는 결과 불일치 | 1차는 단일 등치만 허용; 불명확하면 기존 방식 유지 |
| aptr re-execute 시 outer val_list 슬롯 매핑 오류 | 잘못된 값 바인딩 → 결과 오류 | TYPE_CONSTANT regu가 가리키는 outer val_list 슬롯을 정확히 추적; 단일 등치로 제한 |
| `qexec_clear_xasl_head` 변경 범위 과다 | 다른 서브쿼리 동작에 영향 | corr_key_count > 0 인 경우에만 aptr status reset 분기 추가 |
| 앱 `?` 혼합 쿼리 오동작 | 파라미터 번호 충돌 | `host_var_count > 0`이면 corr push-down 비활성화 |

---

## 9. 구현 단계 요약 (1차)

상세 설계는 `dblink_correlated_optimization_design_doc.md` 참고.

| 단계 | 내용 |
|------|------|
| Step 1 | 탐지: `view_transform.c` 에서 correlated DBLink 등치 조건 식별; `use_dblink_corr_pushdown` 세션 파라미터 추가 및 탐지 진입부에서 체크 |
| Step 2 | SQL 재작성: `conn_sql`에 `WHERE col = ?` append; `PT_DBLINK_INFO`에 corr_key 정보 저장 |
| Step 3 | XASL 생성: `dblink_spec_node.corr_key_count/regu_list` 채우기 |
| Step 4 | 런타임: open = prepare만; 매 outer 행 평가 시 bind + execute |
| Step 5 | aptr status reset: `qexec_clear_xasl_head` 또는 aptr 루프에서 corr DBLink status CLEARED 처리 |
| Step 6 | 직렬화: 신규 필드 pack/unpack 반영 |
| Step 7 | 테스트·검증 |

---

## 10. 테스트 요구사항 (1차)

- **환경**: 로컬 DB + 원격 DB(dblink 연결) 구성.

| 케이스 | 검증 항목 |
|--------|-----------|
| 기본 correlated 스칼라 서브쿼리 | 결과 행 수·값이 AS-IS와 동일 |
| outer에 매칭 행 없음 (0건) | NULL 반환 |
| 원격 테이블 대용량 | 전송 행 수 감소 확인 |
| correlation 키 = NULL | re-execute 스킵, NULL 반환 |
| 앱 `?` 포함 서브쿼리 | 기존 방식(1회 fetch) 유지, regression 없음 |
| push-down 불가 조건 (OR 등) | 기존 방식 유지, regression 없음 |
| DBLink 단독 사용 (correlated 아님) | 기존 방식 유지, regression 없음 |
| `use_dblink_corr_pushdown=no` 세션 설정 | push-down 미적용, AS-IS(1회 전체 fetch) 동작 확인 |

---

## 11. 참고 문서

- [dblink_correlated_source_analysis.md](dblink_correlated_source_analysis.md) — AS-IS 소스 분석

---

## 12. 문서 이력

| 일자 | 내용 |
|------|------|
| 2026-03-13 | 초안 작성 |
| 2026-03-13 | 4장 적용 범위를 1차/2차/Out of Scope로 분리; 9·10장 제목에 "(1차)" 명시 |
| 2026-03-16 | FR-9 추가: `use_dblink_corr_pushdown` 세션 파라미터로 push-down ON/OFF 제어 (Should); §9 Step 1, §10 테스트 케이스 반영 |
