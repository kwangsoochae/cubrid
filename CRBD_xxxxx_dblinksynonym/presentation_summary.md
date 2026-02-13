# DBLINK + Synonym 수정 요약 (발표용)

## 1. 문제 상황

- **증상:** `create server cubrid_conn(...)`, `create synonym synonym_cu for emp@cubrid_conn` 후  
  `select * from synonym_cu` 실행 시  
  **`ERROR: dblink - Syntax: Unknown class "public.emp"`** 발생
- **기대:** 원격 서버에는 **테이블 이름만** (예: `emp`) 전달되어야 함
- **실제:** 원격 SQL에 **`public.emp`** 가 전달되어 원격 서버에서 인식 실패

---

## 2. 원인 정리

- **DB에는 올바르게 저장됨**  
  `select * from db_synonym` 시 `target_name` = `emp@cubrid_conn` 으로 정상 저장
- **문제 구간:** synonym을 **다시 읽어서 사용하는 경로**에서  
  현재 사용자 스키마(`public`)가 붙어 `public.emp` 로 사용됨
- **주요 원인:**  
  - **`pt_mk_spec_derived_dblink_table`** 에서 원격 테이블명을 만들 때  
    `entity_name->resolved`(예: `"public"`) + `"."` + `entity_name->original`(예: `"emp"`) 로  
    **`"public.emp"`** 를 만들어 사용함

---

## 3. 수정 내용 요약

| 구분 | 파일 | 수정 요지 |
|------|------|-----------|
| **1** | **parser_support.c** | **`pt_mk_spec_derived_dblink_table`** – 원격 테이블명을 **`original`만** 사용하고, `sm_remove_qualifier_name()`으로 스키마 제거. `resolved`는 사용하지 않고 NULL로 두어 다른 경로에서 `public.emp` 재사용 방지 |
| **2** | **parser_support.c** | **`pt_convert_dblink_synonym`** – synonym target(`emp@cubrid_conn`)에서 `@` 앞 부분을 **스키마 제거**한 뒤 `entity_name->original`에 설정 (원격용은 unqualified만 사용) |
| **3** | **name_resolution.c** | **`pt_remake_dblink_select_list`** – dblink용 `SELECT * FROM ...` 문에서 FROM 절 테이블명을 **unqualified**로 구성 (스키마 제거) |
| **4** | **execute_statement.c** | **`server_find`** – `_db_server` 조회 시 SELECT에 **`[user_name]`** 사용 (기존 `[owner]` 대신). 권한 검사는 서버 객체의 **`SERVER_ATTR_OWNER`** 로 수행하도록 유지 |

---

## 4. 수정 후 결과

- **동작:** `select * from synonym_cu` 시 원격 SQL이 **`SELECT * FROM emp ...`** 형태로 전달되어 정상 수행
- **정책:** dblink 사용 시 원격 서버에는 **unqualified 클래스명만** 전달하도록 세 곳에서 일관 적용
- **디버깅:** 문제 추적용으로 추가했던 로그/계측은 제거 완료

---

## 5. 발표 시 한 줄 요약 (선택)

> **“DBLINK synonym 사용 시 원격 SQL에 스키마가 붙어 `public.emp` 로 나가던 문제를, 원격 테이블명을 unqualified로만 쓰도록 parser/name_resolution/execute 경로에서 통일해 수정했습니다.”**
