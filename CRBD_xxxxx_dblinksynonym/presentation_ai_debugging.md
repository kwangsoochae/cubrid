# AI와 함께한 디버깅 — DBLINK Synonym 버그 수정

발표용 정리. 슬라이드 구간은 `---` 로 나눔.

---

## 슬라이드 1: 제목 / 오늘 다룰 내용

**제목:** AI와 함께한 디버깅 — DBLINK Synonym 버그 수정

**다룰 내용**
- 어떤 버그였는지 (증상·기대 동작)
- 어떻게 원인을 좁혀 갔는지 (가설·계측·분석)
- 어떤 수정을 했는지 (4곳 요약)
- AI와 협업하면서 느낀 점·정리한 것

**발표자:** 오늘은 CUBRID DBLINK + Synonym 버그를 AI(코드 어시스턴트)와 함께 디버깅한 과정을 공유합니다.

---

## 슬라이드 2: 문제 상황

**증상**
- `create server cubrid_conn(...)`  
  `create synonym synonym_cu for emp@cubrid_conn`  
  이후 `select * from synonym_cu` 실행 시  
  **`ERROR: dblink - Syntax: Unknown class "public.emp"`** 발생

**기대**
- 원격 서버에는 **테이블 이름만** (예: `emp`) 전달되어야 함

**실제**
- 원격 SQL에 **`public.emp`** 가 전달되어 원격 서버에서 인식 실패

**발표자:** “public.emp”는 로컬 스키마가 붙은 이름인데, 원격에는 그냥 “emp”만 넘어가야 하는 상황이었습니다.

---

## 슬라이드 3: 첫 번째 확인 — DB에는 맞게 들어가 있나?

**확인한 것**
- `select * from db_synonym` 으로 보면  
  **`target_name` = `emp@cubrid_conn`** 으로 정상 저장됨

**의미**
- **저장 경로는 문제 없음**  
  → “public.emp”가 만들어지는 구간은  
  **synonym을 다시 읽어서 쓰는 경로** 쪽일 가능성이 큼

**발표자:** DB에는 올바르게 들어가 있으니, “다시 읽어서 사용하는 코드”를 추적하는 쪽으로 방향을 잡았습니다.

---

## 슬라이드 4: 접근 방법 — 가설과 계측

**가설 (H1~H5 등)**
- H1: synonym target을 읽은 직후 값이 어떻게 바뀌는가?
- H2: entity_name이 “public.emp”로 설정되는 시점은?
- H3: dblink용 SQL 문자열이 만들어질 때 테이블명은 어디서 오는가?
- 그 외: _db_server 조회·권한 검사 경로 등

**계측**
- `parser_support.c` — synonym target, entity_name 설정 시점 로그
- `name_resolution.c` — dblink SQL 생성 시 entity_original, sql 로그
- `execute_statement.c` — server_find, _db_server 쿼리·결과 로그  
- 로그 파일: `.cursor/debug.log` (NDJSON 한 줄씩)

**발표자:** 코드베이스가 커서, “어디서 public이 붙는지”를 좁히기 위해 몇 가지 가설을 세우고, 해당 경로에만 로그를 넣어서 확인했습니다.

---

## 슬라이드 5: 원인 정리

**문제 구간**
- synonym을 **다시 읽어서 사용하는 경로**  
  → 그 과정에서 현재 사용자 스키마(`public`)가 붙어 **`public.emp`** 로 사용됨

**주요 원인 (핵심 한 곳)**
- **`pt_mk_spec_derived_dblink_table`** (parser_support.c)  
  - 원격 테이블명을 만들 때  
    `entity_name->resolved`(예: `"public"`) + `"."` + `entity_name->original`(예: `"emp"`)  
    로 **`"public.emp"`** 를 만들어 사용함  
  - 원격 서버에는 **unqualified 이름만** 넘겨야 하는데, 로컬 스키마까지 붙여 버린 것

**발표자:** “DB에는 emp@cubrid_conn으로 잘 들어가 있는데, 그걸 다시 읽어서 쓰는 곳에서 
public.emp로 붙인다”는 사용자 힌트가 원인 좁히는 데 큰 도움이 됐습니다.

---

## 슬라이드 6: 수정 내용 (4곳 요약)

| # | 파일 | 함수/역할 | 수정 요지 |
|---|------|-----------|-----------|
| 1 | parser_support.c | `pt_mk_spec_derived_dblink_table` | 원격 테이블명을 **original만** 사용하고 스키마 제거. `resolved`는 사용하지 않고 NULL로 두어 `public.emp` 재사용 방지 |
| 2 | parser_support.c | `pt_convert_dblink_synonym` | synonym target(`emp@cubrid_conn`)에서 @ 앞 부분을 **스키마 제거**한 뒤 `entity_name->original`에 설정 |
| 3 | name_resolution.c | `pt_remake_dblink_select_list` | dblink용 `SELECT * FROM ...` 의 FROM 절 테이블명을 **unqualified**로 구성 |
| 4 | execute_statement.c | `server_find` | _db_server 조회 시 SELECT에 `[user_name]` 사용. 권한은 서버 객체의 `owner`로 검사 |

**발표자:** “원격에는 스키마 없이 테이블명만”이라는 정책을 parser·name_resolution·execute 
세 경로에서 맞춰 주었습니다.

---

## 슬라이드 7: 수정 후 결과

**동작**
- `select * from synonym_cu` 시  
  원격 SQL이 **`SELECT * FROM emp ...`** 형태로 전달되어 정상 수행

**정리**
- dblink 사용 시 원격 서버에는 **unqualified 클래스명만** 전달하도록 세 곳에서 일관 적용
- 문제 추적용으로 넣었던 로그/계측은 제거 완료

**발표자:** 수정 후 정상 동작 확인했고, 디버깅용 코드는 모두 제거한 상태입니다.

---

## 슬라이드 8: AI와 함께 디버깅하면서 한 일

**역할 분담**
- **사람:** 증상 설명, “db_synonym에는 emp@cubrid_conn으로 잘 들어가 있다” 같은 힌트, 수정 방향 결정, 최종 검증
- **AI:** 코드베이스 검색·함수 호출 관계 추적, 가설별 계측 위치 제안, 수정 패치 초안 작성, 발표/리뷰 문서 초안

**효과**
- parser / name_resolution / execute 등 여러 디렉터리를 빠르게 훑고, “synonym을 다시 읽어오는 곳” 후보를 좁히는 데 도움
- 수정 후 “다음에 재사용하려면?”을 위해 `.cursor/` 에 요약·코드 리뷰·재사용 가이드·규칙 파일 정리

**발표자:** 대화하면서 “저장은 맞는데, 다시 읽어서 쓰는 곳에서 public이 붙는다”는 한 마디가 원인 특정에 크게 기여했습니다.

---

## 슬라이드 9: 한 줄 요약 & 정리

**한 줄 요약**
> DBLINK synonym 사용 시 원격 SQL에 스키마가 붙어 `public.emp`로 나가던 문제를,  
> 원격 테이블명을 **unqualified로만** 쓰도록 parser / name_resolution / execute 경로에서 통일해 수정했다.

**정리**
- **증상:** 원격에 `public.emp` 전달 → Unknown class 에러  
- **원인:** synonym을 다시 쓰는 경로에서 `resolved + "." + original` 로 이름을 만든 한 곳  
- **수정:** 원격용은 **original만** 쓰고 스키마 제거, 세 경로에서 정책 통일  
- **협업:** 가설·계측·수정·문서화를 AI와 함께 진행해, 원인 특정과 수정 정리를 빠르게 할 수 있었음

---

## 부록: 참고 문서 위치

- **발표/요약:** `.cursor/presentation_summary.md`
- **코드 리뷰:** `.cursor/code_review_dblink_synonym.md`
- **다음에 활용:** `.cursor/HOW_TO_REUSE.md`
- **이 발표용:** `.cursor/presentation_ai_debugging.md` (본 문서)
