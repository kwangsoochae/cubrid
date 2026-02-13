# 오늘 작업을 다음에 활용하는 방법

다른 작업(또는 다른 채팅)에서 오늘의 코드 분석·수정 내용을 쓰려면 아래처럼 하면 됩니다.

---

## 1. 새 채팅 시작할 때 파일로 불러오기

새 대화를 시작하면서 **@** 로 아래 파일들을 지정하면, AI가 오늘 맥락을 같이 읽습니다.

- **`@.cursor/presentation_summary.md`** – 수정 요약(발표용)
- **`@.cursor/code_review_dblink_synonym.md`** – 코드 리뷰

예시 문장:
> "@.cursor/presentation_summary.md @.cursor/code_review_dblink_synonym.md 이전에 DBLINK synonym 수정했었는데, 그 근처에서 ~ 작업하려고 해"

---

## 2. 관련 코드 위치만 기억해 두기

오늘 손댄 함수/파일만 알면, 다음에 "여기 근처 수정해 줘"라고 할 수 있습니다.

| 구분 | 파일 | 함수/역할 |
|------|------|-----------|
| 원격 테이블명 unqualified | `src/parser/parser_support.c` | `pt_mk_spec_derived_dblink_table` |
| synonym → 원격 이름 | `src/parser/parser_support.c` | `pt_convert_dblink_synonym` |
| dblink SELECT FROM 절 | `src/parser/name_resolution.c` | `pt_remake_dblink_select_list` |
| 서버 조회/권한 | `src/query/execute_statement.c` | `server_find` |

---

## 3. Cursor 규칙으로 자동 참고 (선택)

`.cursor/rules/` 에 규칙을 두면, 이 프로젝트에서 대화할 때 **자동으로** 그 내용이 참고됩니다.

- 이미 **`.cursor/rules/dblink-synonym-context.mdc`** 를 만들어 두었습니다.
- DBLINK/synonym 관련 작업을 할 때 "아래 문서와 코드 위치를 참고하라"는 짧은 규칙이 들어 있습니다.
- 규칙을 수정·삭제하려면 해당 파일만 고치면 됩니다.

---

## 4. 문서 위치 정리

| 파일 | 용도 |
|------|------|
| `.cursor/presentation_summary.md` | 발표/요약용 |
| `.cursor/code_review_dblink_synonym.md` | 코드 리뷰 보관 |
| `.cursor/HOW_TO_REUSE.md` | 이 파일 – 다음에 활용하는 방법 |

원하면 `docs/` 등으로 복사해 두고, 새 채팅에서 `@docs/...` 로 불러와도 됩니다.
