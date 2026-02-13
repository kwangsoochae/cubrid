# DBLINK + Synonym 테스트 케이스

## 개요

이 테스트 케이스는 DBLINK + Synonym 사용 시 원격 SQL에 스키마가 붙어 `public.emp` 형태로 나가던 버그 수정을 검증합니다.

**핵심 검증 사항:**
- 원격 SQL에는 **unqualified 클래스명만** 전달되어야 함 (예: `emp`, `dept`)
- 스키마가 붙은 이름(예: `public.emp`)이 원격 SQL에 포함되면 안 됨
- `db_synonym` 카탈로그에는 올바르게 저장되어야 함

---

## 테스트 파일

- **`test_dblink_synonym.sql`** – SQL 테스트 케이스 모음

---

## 테스트 케이스 목록

| # | 테스트 케이스 | 검증 내용 |
|---|---------------|-----------|
| 1 | Basic DBLINK Synonym - SELECT | 기본 SELECT 동작, 원격 SQL이 `emp`만 사용 |
| 2 | Schema-qualified Target Name | `public.emp@cubrid_conn` 지정 시 원격에는 `public.emp` 전달 (스키마 보존) - **현재 구현으로는 실패 예상** |
| 3 | Synonym with Alias | 별칭 사용 시에도 원격 SQL은 unqualified |
| 4 | SELECT with WHERE | WHERE 절 포함 시에도 원격 SQL은 unqualified |
| 5 | SELECT with JOIN | JOIN 사용 시에도 원격 SQL은 unqualified |
| 6 | INSERT with Synonym | INSERT 시 원격 SQL은 unqualified |
| 7 | UPDATE with Synonym | UPDATE 시 원격 SQL은 unqualified |
| 8 | DELETE with Synonym | DELETE 시 원격 SQL은 unqualified |
| 9 | Multiple Synonyms | 여러 synonym이 각각 올바르게 동작 |
| 10 | Different Schema Names | 다른 스키마명도 모두 제거되어야 함 |
| 11 | Error - Server Not Found | 서버 없을 때 적절한 에러 (not "public.emp" error) |
| 12 | Error - Table Not Found | 원격 테이블 없을 때 적절한 에러 |
| 13 | Verify db_synonym Catalog | 카탈로그에 올바르게 저장되는지 확인 |
| 14 | ALTER SYNONYM | ALTER 후에도 원격 SQL은 unqualified |
| 15 | Synonym with Owner | Owner 지정해도 원격 SQL은 unqualified |

---

## 실행 방법

### 전제 조건

1. **원격 서버 설정**
   - DBLINK 서버가 설정되어 있어야 함
   - 원격 DB에 테스트 테이블(`emp`, `dept` 등)이 존재해야 함

2. **로컬 환경**
   - CUBRID 서버 실행 중
   - 테스트용 사용자/권한 설정

### 실행

```bash
# 전체 테스트 실행
csql -u dba -C test_dblink_synonym.sql

# 또는 특정 테스트 케이스만 실행하려면 해당 부분만 복사해서 실행
```

### 검증 방법

1. **에러 확인**
   - `ERROR: dblink - Syntax: Unknown class "public.emp"` 같은 에러가 발생하지 않아야 함
   - 원격 서버 관련 에러만 발생해야 함 (서버 없음, 테이블 없음 등)

2. **원격 SQL 로그 확인** (가능한 경우)
   - 원격 서버 로그에서 실제 전달된 SQL 확인
   - `SELECT * FROM emp` 형태여야 함 (not `SELECT * FROM public.emp`)

3. **카탈로그 확인**
   ```sql
   SELECT synonym_name, target_name, target_unique_name 
   FROM db_synonym 
   WHERE synonym_name LIKE 'syn%';
   ```
   - `target_name`이 올바르게 저장되어 있는지 확인

---

## 예상 결과

### 성공 케이스
- 모든 SELECT/INSERT/UPDATE/DELETE가 정상 실행
- 에러가 발생하지 않거나, 원격 서버/테이블 관련 적절한 에러만 발생

### 실패 케이스 (수정 전)
- `ERROR: dblink - Syntax: Unknown class "public.emp"` 발생
- 원격 SQL에 `public.emp` 형태로 전달됨

---

## 관련 파일

- **수정된 코드:**
  - `src/parser/parser_support.c` – `pt_mk_spec_derived_dblink_table`, `pt_convert_dblink_synonym`
  - `src/parser/name_resolution.c` – `pt_remake_dblink_select_list`
  - `src/query/execute_statement.c` – `server_find`

- **문서:**
  - `.cursor/presentation_summary.md` – 수정 요약
  - `.cursor/code_review_dblink_synonym.md` – 코드 리뷰

---

## 주의사항

- 테스트 실행 전에 원격 서버 설정이 올바른지 확인
- 테스트 후 정리(cleanup) 구문이 실행되어야 함
- 실제 원격 서버에 영향을 주지 않도록 테스트 환경에서 실행 권장
