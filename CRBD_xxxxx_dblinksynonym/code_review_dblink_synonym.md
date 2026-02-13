# DBLINK + Synonym 수정 코드 리뷰

## 1. parser_support.c – `pt_mk_spec_derived_dblink_table`

**목적:** dblink 원격 SQL에 스키마가 붙어 `public.emp` 형태로 나가던 문제 제거.

**변경 요약:**
- `remote_table_name`을 더 이상 `resolved + "." + original`로 만들지 않고, **`original`만** 사용하고 `sm_remove_qualifier_name()`으로 스키마를 제거한 뒤 사용.
- `entity_name->info.name.original`을 위에서 구한 unqualified 이름으로 통일.
- `entity_name->info.name.resolved = NULL`로 두어, 이후 경로에서 `public.emp`가 다시 쓰이지 않도록 함.

**장점:**
- 원격 서버가 unqualified 이름만 받는다는 전제가 주석으로 명확히 적혀 있음.
- `sm_remove_qualifier_name(orig)`가 NULL일 때 `class_only = orig`로 폴백하는 방어 코드가 있음.

**제안:**
- `entity_name` 또는 `entity_name->info.name.original`이 NULL인 경우는 위 블록 진입 전에 이미 `derived_spec` 생성 실패 등으로 걸러질 가능성이 크지만, 필요하다면 `class_spec_info->entity_name` NULL 체크를 블록 앞에 한 줄 추가해 두면 더 안전함.

---

## 2. parser_support.c – `pt_convert_dblink_synonym`

**목적:** synonym target이 `emp@cubrid_conn`일 때, 원격용으로는 스키마 없이 `emp`만 쓰도록 함.

**변경 요약:**
- `db_get_synonym_target_name`으로 받은 `class_name`에서 `@` 앞 부분만 사용.
- 그 부분에 대해 `sm_remove_qualifier_name(class_name)`으로 스키마를 제거한 뒤 `entity_name->info.name.original`에 설정.

**장점:**
- “Remote server expects unqualified name for default schema”가 주석으로 명시되어 있음.
- `class_name_for_remote`가 NULL일 때 `class_name`으로 폴백하는 처리 있음.

**참고:**
- `*r = 0`으로 `class_name` 문자열 중 `@` 위치를 널로 잘라서 재사용하고 있음. `class_name`이 로컬 버퍼(`target_name`)에서 온다는 전제가 유지되는 한 문제 없음.

---

## 3. name_resolution.c – `pt_remake_dblink_select_list`

**목적:** dblink용으로 만들어지는 `SELECT * FROM ...` 문자열의 테이블 이름을 unqualified로 유지.

**변경 요약:**
- `FROM ` 뒤에 붙는 테이블 이름을 `entity_name->info.name.original`에서 가져온 뒤, `sm_remove_qualifier_name(tbl_name)`으로 스키마 제거.
- `tbl_unqual`이 NULL이면 `tbl_name` 사용.

**장점:**
- “Remote server expects unqualified class name” 주석으로 의도가 분명함.
- `entity_name`/`original` 없을 때 `""`로 폴백하는 방어 로직 있음.

**일관성:**
- `pt_mk_spec_derived_dblink_table`에서 이미 `original`을 unqualified로 맞추고 `resolved`를 NULL로 두었기 때문에, 대부분의 경우 여기서 한 번 더 strip하는 것은 중복이지만, 다른 경로에서 `original`이 qualified로 들어오는 경우를 대비한 이중 방어로 보면 무난함.

---

## 4. execute_statement.c – `server_find`

**목적:** `_db_server` 조회 시 `[owner]` 대신 `[user_name]`을 SELECT에 사용하고, 권한 검사는 서버 객체의 `owner`로 수행.

**변경 요약:**
- 1차/2차 쿼리 모두  
  `SELECT [_db_server], [user_name] FROM [_db_server] WHERE ...`  
  형태로 변경 (기존 `[owner]` 등 제거).
- owner 지정 없이 `link_name`만으로 찾을 때:  
  `db_get(server_obj, SERVER_ATTR_OWNER, &owner_val)` 후 `au_is_server_authorized_user(&owner_val)`로 권한 검사.
- `owner_val` 선언·초기화 및 에러/해제 경로에서 `pr_clear_value(&owner_val)` 호출로 누수 방지.

**장점:**
- “SELECT returns [user_name] not [owner]”, “for au_is_server_authorized_user” 등 주석으로 SELECT 목적과 권한 검사 방식이 구분되어 있음.
- 권한은 항상 서버 객체의 `SERVER_ATTR_OWNER`로 검사하므로, SELECT 컬럼 변경과 권한 로직이 분리되어 있음.

**확인 제안:**
- `_db_server`에 `user_name` 컬럼이 실제로 존재하고, 기존 기능(예: dblink 연결 시 사용자 정보 사용)이 이 컬럼을 기대하는지 스키마/다른 호출부와 한 번만 맞춰 보면 좋음.

---

## 5. 공통 / 스타일

- **스키마 제거:**  
  dblink 관련해서 “원격은 unqualified만 사용”하는 정책이  
  `pt_convert_dblink_synonym` → `pt_mk_spec_derived_dblink_table` → `pt_remake_dblink_select_list` 세 곳에서 일관되게 적용되어 있음.
- **디버그 로그 제거:**  
  `.cursor/debug.log` 및 agent 로그용 코드는 제거된 상태로 보이며, 운영 코드에는 불필요한 부담이 없음.

---

## 요약 표

| 파일 | 변경 | 평가 |
|------|------|------|
| parser_support.c | dblink 시 `remote_table_name` / `entity_name`을 unqualified만 사용 | 의도 명확, NULL 폴백 적절 |
| parser_support.c | synonym target에서 원격용 이름만 스키마 제거 후 사용 | 주석·폴백 적절 |
| name_resolution.c | dblink SELECT 문 FROM 절 테이블명 unqualified 유지 | 이중 방어로 안전 |
| execute_statement.c | `server_find`에서 SELECT는 `user_name`, 권한은 `owner`로 검사 | 역할 분리·리소스 정리 명확 |

**결론:** dblink + synonym에서 “원격에는 스키마 없이 테이블명만” 보내는 정책이 한 방향으로 정리되어 있고, 방어 코드와 주석도 잘 맞춰져 있어서 그대로 반영해도 무난해 보입니다.
