# dblink Correlated 조건 Push-Down — 작업 개요

| 항목 | 내용 |
|------|------|
| 문서 유형 | 작업 개요서 |
| 이슈 | CBRD-26601 (또는 후속 이슈) |
| 관련 | `03_dblink_correlated_Desgin_Doc.md`, `NA_dblink_correlated_worst_case.md` (파일명은 저장소 기준 최신) |

---

## 1. 작업 개요

### 1.1 성격

**dblink correlated 조건 push-down**은 **dblink 스캔의 WHERE 조건** 중, **outer(상위) 튜플 값에 의존하는 correlated 조건**을 **원격 SQL의 WHERE로 밀어 넣는 최적화**이다.  
AS-IS에서는 correlated 조건이 로컬 `access_pred`에서만 평가되지만, TO-BE에서는 **원격 SQL에서 먼저 필터링**해 전송량과 로컬 필터링 비용을 줄인다.

### 1.2 목표

- XASL 상에서 dblink 스캔의 **correlated 조건을 식별**한다.
- 해당 조건을 **`conn_sql`에 반영**하여, 원격 DB에서 correlated 조건을 포함한 WHERE를 수행하게 한다.
- 실행 시에는 **aptr 1회 + dptr N회** 구조를 유지하면서, 각 outer 튜플에 대해 **원격 SQL을 재실행**(`scan_reset_scan_block` → `dblink_scan_reset(scan_info, vd)`)하여 correlated 조건을 만족하는 행만 가져온다.

### 1.3 한 줄 요약

**로컬에서만 평가되던 dblink correlated 조건** → **원격 SQL WHERE로 push하여 “outer 튜플별로 필요한 행만” 가져오기**.

---

## 2. 필요한 이유

### 2.1 AS-IS 한계

- AS-IS XASL 구조에서 dblink 스캔은 **outer와 독립된 단일 스캔**으로 동작한다.
  - `dblink_open_scan`에서 `cci_prepare + cci_execute`를 수행한 뒤, 상위 buildlist_proc 루프에서 `scan_next_dblink_scan`(`cci_cursor + cci_fetch`)으로 행을 하나씩 읽어 **로컬 결과 리스트 파일에 적재**.
  - 이후 outer 루프에서 **모든 튜플 조합에 대해 로컬 결과 리스트 파일을 재스캔**하며 correlated 조건을 평가 (`access_pred`).
  - 원격 실행(`cci_execute`)은 outer 행마다 **N회** 수행된다. DBLink XASL에 `XASL_ZERO_CORR_LEVEL`이 설정되지 않아 매 래퍼 실행 후 CLEARED로 리셋되기 때문이다.
- 결과적으로:
  - outer 행마다 원격 전체를 **N회 fetch** 하고, 그 중 correlated 조건에 맞는 행만 `access_pred`로 필터링.
  - correlated 조건이 선택적인 경우에도, **원격에서는 필터되지 않은 전체 행**을 N번 반복해서 받음.

### 2.2 TO-BE 개선 방향

- TO-BE에서는 dblink 스캔을 **outer 의존 스캔**으로 모델링한다.
  - aptr(`dblink_open_scan`): `cci_prepare`만 수행하고 execute는 하지 않는다.
  - dptr(outer 튜플마다): `scan_reset_scan_block` → `dblink_scan_reset(scan_info, vd)`를 통해 **correlated 값 바인딩 후 원격 SQL 재실행**. AS-IS의 "결과 리스트 파일 재스캔"이 "원격 재실행"으로 대체된다.
- 이렇게 하면:
  - 원격 SQL의 WHERE에 correlated 조건이 포함되어, **outer 튜플마다 “필요한 행만” 반환**.
  - 로컬 리스트 크기와 로컬 `access_pred` 평가 비용이 크게 줄어든다.

---

## 3. 작업 내용

### 3.1 XASL·파서/뷰 변환 측

| 구분 | 내용 |
|------|------|
| **correlated 조건 식별** | dblink 서브쿼리/뷰에 대해 outer 컬럼을 참조하는 조건을 식별하고, 이를 dblink 전용 메타데이터(예: `corr_key_count`, `corr_key_regu_list`)로 수집. |
| **XASL 구조 확장** | `DBLINK_SCAN_INFO`, `dblink_spec_node` 등 XASL 구조에 correlated 키 정보를 추가. |
| **conn_sql 템플릿 구성** | correlated 조건을 **바인딩 변수(`?`)를 포함하는 WHERE 절 템플릿**으로 표현하여, 실행 시 outer 값으로 바인딩 가능하게 설계. |

### 3.2 실행기(query_executor / dblink_scan) 측

| 구분 | 내용 |
|------|------|
| **초기화(aptr)** | 첫 outer 튜플 진입 시 `dblink_open_scan`에서 `cci_prepare`만 수행하고, correlated 키 바인딩 및 execute는 dptr에서 처리. |
| **dptr 재실행** | 각 outer 튜플마다 `scan_reset_scan_block` → `dblink_scan_reset(scan_info, vd)`를 통해 correlated 값 바인딩 후 `cci_execute`. |
| **로컬 필터링 경량화** | 원격 WHERE에서 correlated 조건이 이미 적용되므로, 로컬 `access_pred`에서는 해당 조건을 제거/대체해 불필요 중복 평가를 줄임. |

### 3.3 예외·검토 사항

- **원격 DB 문법/동작 차이**: 현재 dblink 대상 엔진(예: CUBRID↔CUBRID 가정) 기준으로 설계하되, 향후 이종 DB 고려 시 확장성 검토.
- **에러/타임아웃 처리**: outer 튜플마다 원격 재실행이 일어나므로, 네트워크/원격 에러 처리 정책(재시도 여부 등) 정의 필요.
- **동일 outer 값 재사용**: 같은 correlated 키 조합이 반복되는 경우 결과 캐시 여부(초기 버전에서는 스킵 가능, 후속 최적화로 검토). 

---

## 4. 참고·연계 문서

- `01_dblink_correlated_Source_Analysis.md` — AS-IS 실행 경로, XASL 구조, aptr/dptr 동작 분석
- `03_dblink_correlated_Desgin_Doc.md` — TO-BE 설계, 전체 실행 흐름 다이어그램, `dblink_scan_reset` 확장 설계
- `NA_dblink_correlated_worst_case.md` — worst case·AS-IS/TO-BE 비교 보조
- `04_dblink_correlated_Tasks.md` — 구현 태스크

