# LIMIT Push-Down — 작업 개요

| 항목 | 내용 |
|------|------|
| 문서 유형 | 작업 개요서 |
| 관련 | [LIMIT push-down 제한](dblink_correlated_LIMIT_push_down_restriction.md) |

---

## 1. 작업 개요

### 1.1 성격

**LIMIT push-down**은 특정 기능에 한정된 것이 아니라, 서브쿼리·derived table·뷰 등 **내부 실행 단위에 행 수 제한을 내리는 공통 최적화**이다. “바깥에서 LIMIT n만 필요할 때, 안쪽에서도 n행만 생산·전달하게 만드는 것”이 목표이며, 이 과정에서 **dblink는 그 효과를 함께 누리게 된다**.

### 1.2 목표

**LIMIT n**을 가능한 한 **내부(서브쿼리·원격 등)** 로 push하여, 바깥에서 “n행만 필요”할 때 **내부에서 n행만 계산·전송**하도록 한다. 스칼라 서브쿼리에서 “1행만 필요”할 때 전송량과 로컬 처리를 줄이는 것이 목적이다.

### 1.3 한 줄 요약

**내부에서 여러 행 반환 후 로컬에서 n건만 사용** → **내부 실행에 LIMIT n을 반영해 n행만 반환**.

### 1.4 적용 대상(혜택을 보는 곳)

| 대상 | 내용 |
|------|------|
| **일반 서브쿼리 / derived table** | `SELECT * FROM (SELECT ... FROM big_t) t LIMIT 10` — 내부에 LIMIT을 밀어 넣어 내부에서 10행만 생성. |
| **뷰** | 뷰 인라인 후 바깥 LIMIT을 뷰 쪽으로 push하여 뷰 결과 행 수를 줄임. |
| **원격/외부 소스 (dblink 등)** | 원격 SQL에 `LIMIT n`을 넣어 원격에서 n행만 반환. LIMIT push-down이 구현되면 이러한 외부 소스들도 동일한 이득을 본다. |

### 1.5 적용 시 “현재 vs 개선 후” 예 (외부 소스)

| 구분 | 현재 | 개선 후 |
|------|------|---------|
| 외부로 전달되는 SQL | `SELECT ... FROM remote_t` (LIMIT 없음) | `SELECT ... FROM remote_t ... LIMIT n` |
| 전송 행 수 | 조건에 맞는 전체(또는 여러 행) | 최대 n행 |
| 로컬 | instnum으로 “n건만 사용” | 동일(호환 유지 가능) |

---

## 2. 필요한 이유

### 2.1 현재 제약

- `LIMIT n`은 의미 분석 단계에서 **`inst_num() <= n`** 조건으로 WHERE에 붙음(`type_checking.c` 등).
- Push-down 판단 시 **`inst_num()`이 포함된 term은 push하지 않음** (`view_transform.c` `pt_find_only_name_id`, `others_found`).
- 따라서 **일반 서브쿼리**에서는 내부에 LIMIT이 반영되지 않고, **로컬에서만** instnum으로 “n건만 사용”이 보장됨. 외부 소스(dblink 등)를 쓰는 경우에도 전달 SQL에는 LIMIT이 포함되지 않음.

### 2.2 기대 효과

- **일반 서브쿼리 / derived table / 뷰**: 내부에서 n행만 생성·전달 → 중간 데이터량·연산 감소.
- **외부 소스(예: dblink)를 통한 조회**: LIMIT n push 시 원격/외부 측에서 n행만 반환 → 네트워크 전송량 및 로컬 리스트 크기 감소.
- 특히 SELECT 절 스칼라 서브쿼리는 대부분 “1행 또는 1값” 의도이므로, **LIMIT 1** push만으로도 실사용에서 이득이 큰 경우가 많다.

---

## 3. 작업 내용

### 3.1 작업 범위

| 구분 | 내용 |
|------|------|
| **공통** | “이 내부 실행에 유효한 LIMIT n이 있다”는 정보를 파악하고, 내부 실행 계획 또는 SQL에 LIMIT n을 반영하는 경로 추가. |
| **일반 서브쿼리 / derived table** | inst_num() 변환 문제는 동일하게 존재. inner XASL에 inst_num 제한을 추가하거나, (A) 변환 전 LIMIT 노드를 별도 보존하거나, (B) `inst_num() <= n`에서 n을 역추출해 inner 실행에 반영. |
| **외부 소스 적용 예** | 예를 들어 dblink의 경우, 전달 SQL을 만드는 경로에서 위 정보를 반영해 `LIMIT n`을 붙일 수 있다. 접근법은 일반 서브쿼리와 동일하게 (A) 또는 (B). |
| **영역** | 파서/뷰 변환 또는 XASL 생성. dblink가 아닌 일반 서브쿼리 push-down도 같은 개념으로 확장 가능. |

### 3.2 예외·검토 사항

- **ORDER BY 상호작용 (정확성 조건)**: LIMIT push-down의 핵심 정확성 전제.
  - 내부에 `ORDER BY`가 있는 경우 → LIMIT을 내부로 push해도 결과 동일 (안전).
  - 외부에 `ORDER BY`가 있는 경우 → 내부에 LIMIT을 먼저 적용하면 정렬 전에 행이 잘려 결과가 달라질 수 있음 → **push 불가**.
  - `ORDER BY` 없는 경우 → 결과 순서는 비결정적이지만 "n행만 필요"라는 의미는 유지됨.
- **OFFSET**: `LIMIT n OFFSET m` 처리 여부. 외부 소스인 경우 원격 지원 여부.
- **중첩 서브쿼리**에서 LIMIT이 여러 개인 경우: 어떤 LIMIT을 push할지 규칙 정의.

---

## 4. 참고 문서

- [LIMIT push-down 제한](dblink_correlated_LIMIT_push_down_restriction.md) — dblink 맥락에서 LIMIT·push-down 제약
- [소스 분석](01_dblink_correlated_Source_Analysis.md) — AS-IS 실행 경로, push-down 경로
