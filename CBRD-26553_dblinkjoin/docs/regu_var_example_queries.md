# Regular Variable(REGU) 종류별 예제 SQL

REGU_DATATYPE별로 해당 타입의 Regular variable이 생성되는 SQL 예제를 정리했다.  
실제로 REGU가 어떻게 쓰이는지 코드 추적 시 참고용이다.

## 사전 준비: 스키마 생성

예제를 실행하려면 먼저 아래 스키마 스크립트를 실행한다.

- **파일:** [regu_var_example_schema.sql](regu_var_example_schema.sql)
- **내용:** 테이블 `t`, `t2`, `emp` 생성 및 샘플 데이터 INSERT, 저장 프로시저 `proc_name` 생성

```bash
# 예: csql에서 실행
csql -u dba -S demodb < regu_var_example_schema.sql
```

| 객체    | 용도 |
|---------|------|
| **t**   | 대부분의 예제 (상수, 속성, 산술, 함수, ORDER BY, 분석함수 등). 컬럼: id, a, b, c, name, amt, col, d |
| **t2**  | 서브쿼리 예제 (스칼라 서브쿼리, IN, EXISTS). 컬럼: id, a, b |
| **emp** | 복합 예제 (GROUP BY, COUNT, HAVING). 컬럼: emp_id, dept_id, name, salary |
| **proc_name** | TYPE_SP 예제 (CALL). 인자: (INT, VARCHAR) |

---

## 1. TYPE_CONSTANT (상수)

리터럴·상수 표현. `pt_make_regu_constant()`로 생성된다.

```sql
-- SELECT 리스트 상수
SELECT 1, 'hello', 3.14, DATE '2025-01-01' FROM db_root;

-- WHERE 조건 상수
SELECT * FROM t WHERE a = 100 AND b = 'x';

-- INSERT 값
INSERT INTO t (id, name) VALUES (1, 'foo');

-- 함수 인자 상수
SELECT SUBSTR('abcdef', 1, 3), LENGTH('test') FROM db_root;
```

---

## 2. TYPE_DBVAL (단일 DB_VALUE)

내부적으로 DB_VALUE 하나로 다루는 값. 상수 평가 결과 등이 해당할 수 있다.

```sql
-- 단순 상수 표현 (내부에서 TYPE_DBVAL로 취급되는 경우)
SELECT 1 FROM db_root;
```

---

## 3. TYPE_ATTR_ID / TYPE_CLASS_ATTR_ID / TYPE_SHARED_ATTR_ID (속성 참조)

테이블/뷰 컬럼 참조. `pt_to_regu_attr_descr()` 등으로 attr_descr가 채워진다.

```sql
-- 일반 컬럼 (TYPE_ATTR_ID)
SELECT a, b, c FROM t WHERE a > 0;

-- 여러 컬럼 연산
SELECT a + b, a * 2 FROM t;

-- 클래스 속성 / 공유 속성 (메타/시스템 속성에 따라 CLASS_ATTR_ID, SHARED_ATTR_ID)
SELECT * FROM t;
```

---

## 4. TYPE_INARITH / TYPE_OUTARITH (산술/연산)

산술·비교 연산 트리. leftptr, rightptr, thirdptr로 자식 REGU를 가진다.

```sql
-- 산술식
SELECT a + b, a - b * 2, (a + b) / 2 FROM t;

-- 비교 연산 (predicate 쪽에서도 REGU 사용)
SELECT * FROM t WHERE a > 10 AND b <= 100;

-- CASE 식 (내부적으로 연산/조건 REGU)
SELECT CASE WHEN a > 0 THEN 1 ELSE 0 END FROM t;
```

---

## 5. TYPE_FUNC (함수)

내장 함수·UDF 호출. `function_node`의 operand가 REGU_VARIABLE_LIST다.

```sql
-- 내장 함수
SELECT SUBSTR(name, 1, 3), LENGTH(name), UPPER(name) FROM t;
SELECT COUNT(*), SUM(amt), AVG(amt) FROM t;
SELECT NVL(col, 0), COALESCE(a, b, c) FROM t;

-- 날짜/시간 함수
SELECT SYSDATE, SYSTIMESTAMP, MONTH(d) FROM t;
```

---

## 6. TYPE_POS_VALUE (호스트 변수)

Prepared statement의 `?` 또는 named parameter. `pt_make_regu_hostvar()`로 생성된다.

```sql
-- csql 등에서 ? 바인드
PREPARE st FROM 'SELECT * FROM t WHERE id = ?';
EXECUTE st USING 100;

-- named parameter (드라이버/API에 따라)
-- SELECT * FROM t WHERE id = :id
```

---

## 7. TYPE_REGUVAL_LIST (VALUES 절)

`VALUES (...)` 형태. `pt_make_regu_reguvalues_list()` → TYPE_REGUVAL_LIST.

```sql
-- VALUES만 사용
SELECT * FROM (VALUES (1, 'a'), (2, 'b')) AS v(c1, c2);

-- INSERT ... VALUES
INSERT INTO t (a, b) VALUES (1, 'x'), (2, 'y');
```

---

## 8. TYPE_LIST_ID / 서브쿼리 (TYPE_CONSTANT + xasl)

스칼라 서브쿼리, IN (subquery), EXISTS 등. 서브쿼리 결과를 리스트/스칼라로 쓰는 경우.

```sql
-- 스칼라 서브쿼리
SELECT a, (SELECT MAX(b) FROM t2 WHERE t2.id = t.id) FROM t;

-- IN (subquery)
SELECT * FROM t WHERE id IN (SELECT id FROM t2);

-- EXISTS
SELECT * FROM t WHERE EXISTS (SELECT 1 FROM t2 WHERE t2.id = t.id);
```

---

## 9. TYPE_ORDERBY_NUM (orderby_num())

`orderby_num()`으로 정렬 순서를 참조하는 출력. ORDER BY 결과 위치를 갱신하는 용도.

```sql
SELECT a, b, orderby_num() FROM t ORDER BY a, b;
```

---

## 10. TYPE_REGU_VAR_LIST (CUME_DIST, PERCENT_RANK)

분석 함수 중 `CUME_DIST`, `PERCENT_RANK`는 정렬 리스트를 REGU_VARIABLE_LIST로 가진다.

```sql
SELECT a, b,
       CUME_DIST() OVER (ORDER BY a),
       PERCENT_RANK() OVER (ORDER BY b)
FROM t;
```

---

## 11. TYPE_POSITION (list file 컬럼 위치)

정렬/그룹/중간 결과의 “몇 번째 컬럼”을 가리키는 REGU. SELECT 리스트나 ORDER BY 처리 시 생성된다.

```sql
-- ORDER BY로 정렬된 결과의 위치 참조가 필요한 경우
SELECT a, b FROM t ORDER BY a, b;

-- 복수 컬럼 출력 (list file 상 위치가 REGU로 관리됨)
SELECT a, b, a+b FROM t;
```

---

## 12. TYPE_OID / TYPE_CLASSOID (객체/클래스 식별자)

현재 행의 OID 또는 클래스 OID를 쓰는 표현. 메타/시스템 속성 참조 시 사용된다.

```sql
-- OID/클래스 OID를 반환하는 메타 속성 사용 시 (구문은 버전에 따라 다를 수 있음)
-- 객체 참조 컬럼이나 시스템 컬럼 참조 시 내부적으로 해당 타입 사용
```

---

## 13. TYPE_SP (저장 프로시저)

저장 프로시저 호출 또는 SP가 반환하는 값을 쓰는 경우. `sp_node`의 args가 REGU_VARIABLE_LIST다.

```sql
CALL proc_name(1, 'arg2');

-- SP를 호출하는 함수처럼 쓰는 경우 (지원 시)
-- SELECT proc_ret_func() FROM db_root;
```

---

## 14. 복합 예제 (여러 REGU 타입이 함께 사용되는 경우)

```sql
-- TYPE_ATTR_ID(a, b), TYPE_INARITH(a+b), TYPE_FUNC(SUBSTR), TYPE_CONSTANT(1, 3)
SELECT a, b, a + b, SUBSTR(name, 1, 3) FROM t WHERE id > 0;

-- TYPE_ATTR_ID, TYPE_FUNC(COUNT), TYPE_CONSTANT
SELECT dept_id, COUNT(*) FROM emp GROUP BY dept_id HAVING COUNT(*) > 5;

-- 서브쿼리 + 상수 + 속성
SELECT * FROM t
WHERE a = (SELECT MAX(a) FROM t2) AND b = 'constant';
```

---

## 참고

- REGU 타입은 `src/query/regu_var.hpp`의 `REGU_DATATYPE` enum에 정의되어 있다.
- 생성 경로는 `src/parser/xasl_generation.c`의 `pt_to_regu_variable()`, `pt_make_regu_*()` 계열에서 확인할 수 있다.
- 실행 시 값 평가는 `src/query/fetch.c`의 `fetch_peek_dbval()`에서 type별 분기로 처리된다.
