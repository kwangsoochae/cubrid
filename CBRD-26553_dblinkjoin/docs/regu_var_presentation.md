# Regular Variable (regu_var) 코드 분석
## CUBRID Query Execution 내부 구조 발표

---

## Slide 1 — 발표 개요

**오늘 다룰 내용**

1. Regular Variable이란?
2. 파일·모듈 구조
3. 핵심 데이터 구조
4. REGU_DATATYPE별 value 사용
5. 생성·평가·정리 흐름
6. 사용처 요약
7. **map_regu(): 트리 순회 메커니즘** ← 핵심
8. clear_xasl(): 트리 메모리 정리
9. **예제 SQL 단계별 추적** ← 핵심
8. **DBLink 조인 push-down에서 REGU 활용** ← 핵심
9. DBLink push-down 예제: 단순 조인 키 단계별 추적
10. DBLink push-down 예제: 함수 포함 조인 키
11. AS-IS vs TO-BE 실행 흐름 비교

---

## Slide 2 — Regular Variable이란?

**한 문장 정의**

> REGU는 XASL 실행 계획 안에서 **"값 또는 식"을 나타내는 공통 표현**이다.

```
SQL → PT_NODE(파스 트리) → REGU 생성 → XASL에 저장
                                           ↓
                              실행 시 fetch_peek_dbval()로 DB_VALUE 평가
```

**핵심 파일**

| 파일 | 역할 |
|------|------|
| `regu_var.hpp / .cpp` | 타입·플래그·클래스 정의, map/clear 구현 |
| `xasl_generation.c` | PT_NODE → REGU_VARIABLE 변환 |
| `fetch.c` | 실행 시 값 계산 (fetch_peek_dbval) |

---

## Slide 3 — 왜 REGU가 필요한가?

**설계 목적: Regulator ↔ Interpreter 공통 표현**

```
┌─────────────┐     ┌──────────────────┐     ┌──────────────┐
│  PT_NODE    │────▶│  REGU_VARIABLE   │────▶│  DB_VALUE    │
│ (파스 트리) │     │ (XASL 계획 내부) │     │ (실행 결과)  │
└─────────────┘     └──────────────────┘     └──────────────┘
    파서(생성)            공통 표현                 실행기(평가)
```

- 계획용 표현과 실행용 표현을 **별도로 두면** 변환·중복 발생
- **REGU 하나**로 파서(Regulator)와 실행기(XASL Interpreter)가 공유
- 직렬화·역직렬화·실행까지 **동일 구조** 유지

> 코드 주석: *"types/fields used by both XASL interpreter and regulator"*
> (`regu_var.hpp` 46행, 185행)

---

## Slide 4 — 파일·모듈 구조

```
src/
├── query/
│   ├── regu_var.hpp     ← 타입/플래그/클래스 정의
│   ├── regu_var.cpp     ← map_regu, clear_xasl 구현
│   ├── fetch.c          ← fetch_peek_dbval (값 평가)
│   └── scan_manager.c   ← 스캔 시 regu_list 사용
│
└── parser/
    ├── xasl_generation.c    ← pt_to_regu_variable 등 REGU 생성
    └── xasl_regu_alloc.hpp  ← regu_alloc / regu_init
```

**흐름 요약**

```
xasl_generation.c  →  REGU 생성
      │
      ▼
 XASL_NODE (pred_expr, outptr_list, access_spec …)
      │
      ▼
 fetch.c / scan_manager.c  →  DB_VALUE 평가
```

---

## Slide 5 — 핵심 데이터 구조

### regu_variable_node (REGU_VARIABLE)

```cpp
struct regu_variable_node {
    REGU_DATATYPE       type;             // 어떤 종류의 값/식인지
    int                 flags;            // 비트 플래그
    TP_DOMAIN          *domain;           // 결과 타입·도메인
    DB_VALUE           *vfetch_to;        // 값 채울 목적지
    xasl_node          *xasl;            // 서브쿼리 XASL 연결
    union regu_data_value value;          // type에 따라 사용 필드 다름
};
```

### regu_variable_list_node (REGU_VARIABLE_LIST)

```cpp
struct regu_variable_list_node {
    REGU_VARIABLE_LIST  next;   // 연결 리스트
    REGU_VARIABLE       value;  // 실제 regu_variable_node
};
```

→ 출력 컬럼, 조건 피연산자, 스캔 속성 등을 **연결 리스트**로 묶을 때 사용

---

## Slide 6 — REGU_DATATYPE: 무엇을 담는가?

| REGU_DATATYPE | value 필드 | 예시 |
|---------------|-----------|------|
| `TYPE_DBVAL` | `dbval` | 리터럴 상수 (`1`, `'hello'`) |
| `TYPE_CONSTANT` | `dbvalptr` | 호스트 변수 결과 캐시 |
| `TYPE_INARITH / OUTARITH` | `arithptr` | `a + b`, `CASE WHEN …` |
| `TYPE_ATTR_ID` | `attr_descr` | 컬럼 참조 (`t.col`) |
| `TYPE_POSITION` | `pos_descr` | list file 컬럼 위치 |
| `TYPE_FUNC` | `funcp` | 함수 호출 (`UPPER(s)`) |
| `TYPE_REGUVAL_LIST` | `reguval_list` | `VALUES (…)` 절 |
| `TYPE_SP` | `sp_ptr` | 저장 프로시저 |

**트리 구조 예시 — `a + b * 2`**

```
OUTARITH(+)
├── ATTR_ID(a)
└── INARITH(*)
    ├── ATTR_ID(b)
    └── DBVAL(2)
```

---

## Slide 7 — 주요 플래그

| 플래그 | 비트 | 의미 |
|--------|------|------|
| `REGU_VARIABLE_HIDDEN_COLUMN` | 0x01 | list file에서 숨김 |
| `REGU_VARIABLE_FETCH_ALL_CONST` | 0x40 | 모두 상수 (최적화 힌트) |
| `REGU_VARIABLE_FETCH_NOT_CONST` | 0x80 | 상수 아님 |
| `REGU_VARIABLE_CORRELATED` | 0x800 | 상관 서브쿼리 캐시 |
| `REGU_VARIABLE_UPD_INS_LIST` | 0x200 | UPDATE/INSERT 리스트용 |

헬퍼 매크로: `REGU_VARIABLE_IS_FLAGED`, `REGU_VARIABLE_SET_FLAG`, `REGU_VARIABLE_CLEAR_FLAG`

---

## Slide 8 — 생성 흐름: PT_NODE → REGU

```
SQL 파싱 완료 (PT_NODE)
        │
        ▼
pt_to_regu_variable()          ← 표현식 하나를 REGU로 변환
pt_to_regu_variable_list()     ← 리스트로 변환
        │
        ├── pt_make_regu_hostvar()
        ├── pt_make_regu_constant()
        ├── pt_make_regu_subquery()
        ├── pt_make_function()
        └── pt_make_position_regu_variable()
        │
        ▼
regu_alloc() / regu_init()     ← packing buffer에서 메모리 할당
        │
        ▼
XASL_NODE에 저장
  (pred_expr, outptr_list, access_spec …)
```

---

## Slide 9 — 실행 흐름: fetch_peek_dbval

```
fetch_peek_dbval(regu, vd, tuple, ...)
        │
        ▼
  switch(regu->type)
  ├── TYPE_DBVAL       → &regu->value.dbval 반환
  ├── TYPE_CONSTANT    → dbvalptr 반환 (서브쿼리면 먼저 실행)
  ├── TYPE_INARITH     → 좌·우 피연산자 재귀 평가 후 산술 수행
  ├── TYPE_ATTR_ID     → tuple/캐시에서 속성 값 조회
  ├── TYPE_FUNC        → 함수 실행
  └── ...
        │
        ▼
    DB_VALUE* (결과)
```

**fetch_peek_dbval() 호출 위치** (반환된 DB_VALUE*를 즉시 사용)

- 스캔 조건 평가 (`scan_manager.c`)
- 조인 키 비교 (`query_evaluator.c`)
- SELECT 출력 컬럼 계산 (`execute_statement.c`)
- 함수 인자 조회 (`query_opfunc.c`)

---

## Slide 10 — map_regu(): 트리 순회 메커니즘

**한 줄 정의**

> REGU 트리 전체에 콜백 함수를 적용하는 범용 DFS 순회기

---

### 함수 시그니처

```cpp
void regu_variable_node::map_regu(map_func_type func);
// map_func_type: void(regu_variable_node &, bool &stop)
```

`func`는 람다 또는 함수 포인터. `stop = true`로 설정하면 순회 중단 가능.

---

### 순회 방식: pre-order DFS

```
map_regu(func):
  1. func(this)              ← 현재 노드에 콜백 먼저 실행
  2. type에 따라 자식 재귀:

     TYPE_INARITH/OUTARITH : leftptr->map_regu(func)
                             rightptr->map_regu(func)
     TYPE_FUNC             : funcp->operand 리스트 각 항목->map_regu(func)
     TYPE_SP               : sp_ptr->args 리스트 각 항목->map_regu(func)
     TYPE_REGUVAL_LIST     : reguval_list->regu_list 각 항목->map_regu(func)
     그 외 (리프 노드)      : 재귀 없음, 종료
```

---

### 예시: `(a + b) * 2` 순회 순서

```
OUTARITH(*)
  ├── INARITH(+)
  │     ├── ATTR_ID(a)
  │     └── ATTR_ID(b)
  └── DBVAL(2)

map_regu 호출 순서:
  1. OUTARITH(*)   ← func 실행
  2. INARITH(+)    ← func 실행
  3. ATTR_ID(a)    ← func 실행 (리프)
  4. ATTR_ID(b)    ← func 실행 (리프)
  5. DBVAL(2)      ← func 실행 (리프)
```

---

### 활용처

| 콜백 | 목적 |
|------|------|
| `clear_xasl_local` | 트리 전체 자원 해제 |
| 상수 여부 판별 | `FETCH_ALL_CONST` 플래그 설정 (memoize.cpp) |
| REGU 복사 | 트리 전체 deep copy |
| 디버그 덤프 | 각 노드 출력 |

콜백 하나만 작성하면 트리 전체에 적용 — 타입별 분기를 직접 작성할 필요 없음.

---

## Slide 10-2 — clear_xasl(): 트리 메모리 정리

**한 줄 정의**

> `map_regu(clear_xasl_local)` — map_regu를 사용해 트리 전체에 정리 적용

```
clear_xasl()
  └── map_regu(clear_xasl_local)
        └── 모든 노드에 clear_xasl_local 실행
```

---

### clear_xasl_local: 노드 하나의 정리 내용

| 타입 | 정리 내용 |
|------|----------|
| `TYPE_DBVAL` | `pr_clear_value(&value.dbval)` |
| `TYPE_FUNC` | value clear + `tmp_obj` 삭제 (예: compiled_regex 캐시) |
| `TYPE_SP` | `pr_clear_value`, sig 삭제 |
| `TYPE_INARITH` | rand_seed 해제, pred->clear_xasl |
| `vfetch_to != NULL` | `pr_clear_value(vfetch_to)` |

---

### clear_xasl와 map_regu의 관계

```
clear_xasl() 호출 한 번
  │
  ▼ map_regu()가 트리 전체 DFS 순회
  │
  ▼ 각 노드에서 clear_xasl_local 실행
  │
  ▼ 트리의 모든 노드 자원 해제 완료
```

`map_regu()`가 순회를 담당하므로, `clear_xasl_local`은 **현재 노드 하나만** 처리하면 된다.

---

## Slide 11 — 사용처 전체 지도

| 단계 | 파일 | 하는 일 |
|------|------|---------|
| **생성** | `xasl_generation.c` | pt_to_regu_variable → XASL 구성 |
| **스캔** | `scan_manager.c` | heap/index/list/dblink scan에 regu_list 전달 |
| **실행** | `execute_statement.c` | outptr_list 순회, UPD_INS_LIST 설정 |
| **평가** | `fetch.c` | fetch_peek_dbval — 실제 DB_VALUE 계산 |
| **함수** | `query_opfunc.c` | 함수 인자 fetch |
| **파티션** | `partition.c` | 파티션 프루닝용 상수/식 평가 |
| **직렬화** | `stream_to_xasl.c / xasl_to_stream.c` | REGU 저장·복원 |
| **최적화** | `memoize.cpp` | 조건식 내 상수 regu 수집 |

---

## Slide 12 — 예제 SQL 단계별 추적

**예제 쿼리**

```sql
SELECT a + 1 FROM t WHERE b = 'hello';
```

---

### Step 1. SQL 파싱 → PT_NODE

파서(bison/flex)가 SQL을 파스 트리로 변환

```
SELECT list:  PT_PLUS
                ├── PT_NAME("a")
                └── PT_VALUE(1)

WHERE:        PT_EQ
                ├── PT_NAME("b")
                └── PT_VALUE('hello')
```

**파일:** `src/parser/csql_grammar.y` → `src/parser/`

---

### Step 2. REGU_VARIABLE 생성 (xasl_generation.c)

`pt_to_regu_variable()`가 PT_NODE를 REGU_VARIABLE로 변환

**SELECT 리스트 (`a + 1`)**

```
pt_to_regu_variable(PT_PLUS)
  → regu_alloc() : OUTARITH 노드 할당
       arithptr->opcode  = PLUS
       arithptr->leftptr = pt_to_regu_variable(PT_NAME("a"))
                           → TYPE_ATTR_ID  { attr_id=0 }    ← 컬럼 a
       arithptr->rightptr= pt_to_regu_variable(PT_VALUE(1))
                           → TYPE_DBVAL   { dbval=1 }       ← 리터럴 1
```

**WHERE 절 (`b = 'hello'`)**

```
pt_make_pred_term_comp(lhs, rhs, R_EQ)
  lhs = pt_to_regu_variable(PT_NAME("b"))
        → TYPE_ATTR_ID { attr_id=1 }     ← 컬럼 b
  rhs = pt_to_regu_variable(PT_VALUE('hello'))
        → TYPE_DBVAL   { dbval='hello' } ← 리터럴 'hello'
```

**파일:** `src/parser/xasl_generation.c`, `src/parser/xasl_regu_alloc.hpp`

---

### Step 3. XASL_NODE에 저장

생성된 REGU_VARIABLE이 XASL 실행 계획의 각 자리에 배치됨

```
XASL_NODE (SELECT)
 ├── access_spec        → heap scan on table "t"
 │
 ├── outptr_list        → 출력 컬럼 리스트
 │    └── [0] REGU: TYPE_OUTARITH
 │              arithptr->opcode   = PLUS
 │              arithptr->leftptr  → TYPE_ATTR_ID (a)
 │              arithptr->rightptr → TYPE_DBVAL   (1)
 │
 └── pred               → WHERE 조건
      └── PRED_COMP (EQ)
            lhs → TYPE_ATTR_ID (b)
            rhs → TYPE_DBVAL   ('hello')
```

**파일:** `src/xasl/`, `src/parser/xasl_generation.c`

---

### Step 4. 직렬화 → 서버 전송

```
클라이언트  xasl_to_stream()  →  byte stream  →  서버
서버        stream_to_xasl()  →  XASL_NODE 복원
```

REGU_VARIABLE 구조 그대로 직렬화 — 별도 변환 없음

**파일:** `src/query/xasl_to_stream.c`, `src/query/stream_to_xasl.c`

---

### Step 5. 실행 — WHERE 조건 평가

서버가 heap scan으로 각 row를 읽으며 pred를 평가

```
scan_manager.c: heap에서 row (a=5, b='world') 읽음

fetch_peek_dbval(TYPE_ATTR_ID b)
  → tuple에서 b 컬럼 값 조회 → DB_VALUE('world')

PRED_COMP(EQ):
  'world' == 'hello'  →  FALSE  →  row 스킵

fetch_peek_dbval(TYPE_ATTR_ID b)  ← 다음 row (a=5, b='hello')
  → DB_VALUE('hello')

PRED_COMP(EQ):
  'hello' == 'hello'  →  TRUE   →  row 통과
```

**파일:** `src/query/fetch.c`, `src/query/scan_manager.c`

---

### Step 6. 실행 — SELECT 출력 평가

WHERE를 통과한 row에 대해 outptr_list 평가

```
fetch_peek_dbval(TYPE_OUTARITH)
  │
  ├── fetch_peek_dbval(TYPE_ATTR_ID a)
  │     → tuple에서 a 컬럼 조회 → DB_VALUE(5)
  │
  └── fetch_peek_dbval(TYPE_DBVAL 1)
        → &regu->value.dbval  → DB_VALUE(1)
  │
  └── PLUS(5, 1) → DB_VALUE(6)

결과: 6
```

**파일:** `src/query/fetch.c`, `src/query/query_opfunc.c`

---

### 전체 흐름 한눈에 보기

```
SQL:  SELECT a + 1 FROM t WHERE b = 'hello'
         │
         ▼ [csql_grammar.y]
PT_NODE: PT_PLUS(PT_NAME(a), PT_VALUE(1))  /  PT_EQ(PT_NAME(b), PT_VALUE('hello'))
         │
         ▼ [xasl_generation.c] pt_to_regu_variable()
REGU:    OUTARITH(+)                        /  ATTR_ID(b) == DBVAL('hello')
           ├── ATTR_ID(a)
           └── DBVAL(1)
         │
         ▼ [xasl_generation.c]
XASL:    outptr_list = [OUTARITH]  /  pred = COMP(EQ, ATTR_ID(b), DBVAL('hello'))
         │
         ▼ [xasl_to_stream / stream_to_xasl]
직렬화 → 서버 복원
         │
         ▼ [scan_manager.c + fetch.c]  ← row 단위 반복
평가:    pred 평가 → WHERE 필터링
         outptr 평가 → a + 1 계산
         │
         ▼
결과:    DB_VALUE(6)
```

---

## Slide 13 — 정리

**REGU(Regular Variable) 핵심 3가지**

1. **공통 표현**
   상수·컬럼·산술·함수·서브쿼리·SP를 `REGU_DATATYPE + value union` 하나로 통일

2. **Regulator ↔ Interpreter 공유**
   계획 생성 단계와 실행 단계가 **동일 구조**를 사용 → 변환 불필요, 직렬화 단순

3. **트리 구조**
   산술식·함수 인자가 REGU 트리를 이루며, `map_regu()`로 전체 순회

**dblink/원격 조인에서의 활용**
로컬/원격 피연산자 구분, 실행 계획 분석 시 `type` / `xasl` / `flags`를 추적하면
"어디서 값이 오는지" 파악 가능 — 자세한 내용은 Slide 14 참조

---

## Slide 14 — DBLink 조인 push-down에서 REGU 활용

**문제:** `remote_t.col = local_t.id` 조건에서 어느 쪽이 로컬/원격인지 어떻게 판단하는가?

**`regu_variable_node`의 세 필드 조합으로 판단**

| 필드 | 로컬 값 | 원격 값 |
|------|---------|---------|
| `type` | `TYPE_ATTR_ID` (로컬 scan) | `TYPE_ATTR_ID` (dblink scan) |
| `xasl` | `NULL` | dblink XASL 포인터 |
| `flags` | `REGU_VARIABLE_CORRELATED` | 없음 |

```
조인 조건:  remote_t.col = local_t.id

lhs: TYPE_ATTR_ID, xasl = dblink_xasl, flags = 0
     → 원격 컬럼, dblink scan 결과에서 옴

rhs: TYPE_ATTR_ID, xasl = NULL, flags = CORRELATED
     → 로컬 컬럼, outer row에서 공급
     → push-down bind parameter 후보
```

**판단 규칙**

- `xasl == NULL` + `REGU_VARIABLE_CORRELATED` → **로컬 값** → 원격 쿼리의 `WHERE` bind parameter로 내려보낼 수 있다
- `xasl != NULL` (dblink XASL) → **원격 값** → push-down 대상 컬럼

**리프 노드 타입은 즉시 판단 가능**

| 타입 | 판단 |
|------|------|
| `TYPE_DBVAL` | 상수 → 언제든 사용 가능 |
| `TYPE_ATTR_ID` | xasl/flags로 확인 |
| `TYPE_INARITH` 등 | 자식 노드 재귀 추적 필요 |

---

## Slide 15 — DBLink push-down 예제: 단순 조인 키 단계별 추적

**예제 쿼리**

```sql
SELECT l.name, r.score
FROM   local_t l,
       DBLINK('remote_srv', 'SELECT id, score FROM score_t') AS r(id INT, score INT)
WHERE  r.id = l.user_id;
```

---

### Step 1. 조인 조건 REGU 생성

`pt_to_regu_variable()`가 `r.id = l.user_id`를 REGU 트리로 변환

```
PRED_COMP (EQ)
  lhs → pt_to_regu_variable(PT_NAME("r.id"))
        → TYPE_ATTR_ID { attr_id = r.id }

  rhs → pt_to_regu_variable(PT_NAME("l.user_id"))
        → TYPE_ATTR_ID { attr_id = l.user_id }
```

---

### Step 2. 각 REGU 필드 분석

```
lhs (r.id):
  type  = TYPE_ATTR_ID
  xasl  = &dblink_xasl     ← dblink XASL 노드를 가리킴
  flags = 0
  → 판정: 원격 컬럼 (dblink scan 결과에서 옴)

rhs (l.user_id):
  type  = TYPE_ATTR_ID
  xasl  = NULL              ← 현재 plan 내부 값
  flags = REGU_VARIABLE_CORRELATED  ← outer row에 의존
  → 판정: 로컬 컬럼, push-down bind parameter 후보
```

---

### Step 3. push-down 결정

```
조인 조건 분석 결과:
  원격 side  : r.id      (xasl != NULL)
  로컬 side  : l.user_id (xasl == NULL, CORRELATED)

push-down 변환:
  원격 쿼리 재작성 → "SELECT id, score FROM score_t WHERE id = ?"
  l.user_id → bind parameter(1번)로 등록
```

---

### Step 4. 실행 흐름

```
outer loop: local_t에서 row 읽음
  (l.name = 'Alice', l.user_id = 42)
       │
       ▼ fetch_peek_dbval(rhs_regu: TYPE_ATTR_ID l.user_id)
         → tuple에서 l.user_id 조회 → DB_VALUE(42)
       │
       ▼ cci_bind_param(stmt, 1, DB_VALUE(42))
       │
       ▼ cci_execute(stmt)
         원격 실행: SELECT id, score FROM score_t WHERE id = 42
       │
       ▼ fetch: (id = 42, score = 98)
       │
       ▼ PRED_COMP(EQ): r.id(42) == l.user_id(42) → TRUE
         outptr 평가: l.name='Alice', r.score=98

결과: ('Alice', 98)
```

---

### 전체 흐름 한눈에 보기

```
SQL:  WHERE r.id = l.user_id
         │
         ▼ [xasl_generation.c]
REGU:    PRED_COMP(EQ)
           lhs: TYPE_ATTR_ID(r.id)   xasl=dblink_xasl  → 원격
           rhs: TYPE_ATTR_ID(l.user_id) xasl=NULL, CORRELATED → 로컬
         │
         ▼ [dblink_scan.c] push-down 결정
원격쿼리: "SELECT id, score FROM score_t WHERE id = ?"
         │
         ▼ [실행: outer loop 반복]
outer row: l.user_id=42
         │ fetch_peek_dbval(rhs_regu) → 42
         │ cci_bind_param(1, 42)
         │ cci_execute
         ▼
결과: 매칭된 원격 row만 반환
```

---

## Slide 16 — DBLink push-down 예제: 함수 포함 조인 키

**예제 쿼리** — rhs가 단순 컬럼이 아니라 함수식인 경우

```sql
SELECT l.name, r.result
FROM   local_t l,
       DBLINK('remote_srv', 'SELECT code, result FROM remote_t') AS r(code VARCHAR, result INT)
WHERE  r.code = UPPER(l.category);
```

---

### REGU 트리 구조

```
PRED_COMP (EQ)
  lhs → TYPE_ATTR_ID (r.code)
          xasl  = &dblink_xasl
          flags = 0
          → 원격 컬럼

  rhs → TYPE_OUTARITH (UPPER)
          xasl  = NULL
          └── TYPE_ATTR_ID (l.category)
                xasl  = NULL
                flags = REGU_VARIABLE_CORRELATED
          → 로컬 계산식 전체가 push-down 가능
```

---

### 판단 방법: 재귀 추적

`TYPE_OUTARITH` 노드 자체는 `TYPE_ATTR_ID`가 아니므로 자식까지 추적한다.

```
rhs 트리 전체를 map_regu()로 순회:
  모든 자식의 xasl == NULL?  → YES
  CORRELATED 자식 존재?      → YES (l.category)
  → rhs 전체가 로컬 계산식
  → push-down 가능
```

---

### 실행 흐름

```
outer row: (l.name = 'Bob', l.category = 'sports')
       │
       ▼ fetch_peek_dbval(rhs_regu: TYPE_OUTARITH UPPER)
           └── fetch_peek_dbval(TYPE_ATTR_ID l.category)
                 → tuple에서 조회 → DB_VALUE('sports')
           └── UPPER('sports') → DB_VALUE('SPORTS')
       │
       ▼ cci_bind_param(stmt, 1, DB_VALUE('SPORTS'))
       │
       ▼ cci_execute(stmt)
         원격 실행: SELECT code, result FROM remote_t WHERE code = 'SPORTS'
       │
       ▼ fetch: (code = 'SPORTS', result = 77)

결과: ('Bob', 77)
```

**핵심:** 리프 노드가 `TYPE_ATTR_ID`가 아니어도, 트리 전체가 로컬 계산만 하면 push-down 가능 — REGU 트리를 재귀 추적해야 판단할 수 있다.

---

## Slide 17 — AS-IS vs TO-BE 실행 흐름 비교

**예제 쿼리**

```sql
SELECT l.name, r.score
FROM   local_t l,
       DBLINK('remote_srv', 'SELECT id, score FROM score_t') AS r(id INT, score INT)
WHERE  r.id = l.user_id;
```

---

### AS-IS (현재)

```
cci_prepare(stmt, "SELECT id, score FROM score_t")
       │
       ▼ cci_execute(stmt)   ← 파라미터 없이 1회 실행
         원격 전체 데이터 반환
       │
       ▼ fetch all rows → CUBRID 서버 메모리에 적재
         (score_t가 크면 모두 가져옴)
       │
       ▼ [outer loop: local_t 한 row씩]
           scan_next_dblink_scan()이 이미 적재된 데이터를 순회
           r.id = l.user_id 조건을 로컬에서 필터링
```

**문제점:** score_t 전체를 가져오므로, 조인 조건에 매칭되지 않는 row도 모두 전송됨

---

### TO-BE (push-down 이후)

```
cci_prepare(stmt, "SELECT id, score FROM score_t WHERE id = ?")
       │
       [outer loop: local_t 한 row씩]
       │
       ▼ fetch_peek_dbval(join_key_regu: l.user_id)
         → REGU 트리 평가 → DB_VALUE(현재 outer row의 user_id)
       │
       ▼ cci_bind_param(stmt, 1, DB_VALUE)
       │
       ▼ cci_execute(stmt)   ← outer row마다 실행
         원격에서 id = ? 인 row만 반환
       │
       ▼ fetch: 매칭 row만 처리 → 로컬 필터 최소화
```

---

### 비교 요약

| 항목 | AS-IS | TO-BE |
|------|-------|-------|
| 원격 실행 횟수 | 1회 | outer row 수만큼 |
| 전송 데이터 | 원격 테이블 전체 | 매칭 row만 |
| 로컬 필터링 | 전량 필터 | 최소화 |
| REGU 활용 | 없음 | `fetch_peek_dbval(join_key_regu)`로 bind 값 계산 |

**REGU의 역할:** `join_key_regu`가 `TYPE_ATTR_ID`든 `TYPE_OUTARITH`든, `fetch_peek_dbval()` 한 번 호출로 bind parameter 값을 얻을 수 있다 — REGU 추상화가 push-down 구현을 단순하게 만드는 핵심 이유.

---

## 참고: 전체 흐름 요약

```
SQL
 │
 ▼ [src/parser/]
PT_NODE  →  pt_to_regu_variable()  →  REGU_VARIABLE
                                              │
                                              ▼
                                      XASL_NODE 저장
                                    (pred, outptr, spec)
                                              │
                                              ▼
                                    직렬화 (xasl_to_stream)
                                              │
                                              ▼
                                    역직렬화 (stream_to_xasl)
                                              │
                                              ▼
                                 [src/query/] 실행
                                    fetch_peek_dbval()
                                              │
                                              ▼
                                          DB_VALUE*
```
