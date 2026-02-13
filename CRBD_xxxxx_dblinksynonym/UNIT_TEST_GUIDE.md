# DBLINK Synonym 수정 - Unit Test 가이드

## 개요

수정한 함수들은 parser 내부 static 함수들이므로 직접 unit test 작성이 복잡합니다. 두 가지 접근 방법을 제안합니다.

---

## 방법 1: SQL 통합 테스트 (권장)

**장점:**
- 실제 사용 시나리오를 그대로 테스트
- 구현 세부사항에 의존하지 않음
- 유지보수 용이

**방법:**
이미 작성한 `.cursor/test_dblink_synonym.sql` 파일을 사용하여 테스트합니다.

### 실행 방법

```bash
# CUBRID 서버 실행 후
csql -u dba -C .cursor/test_dblink_synonym.sql

# 또는 특정 테스트 케이스만 실행
csql -u dba <<EOF
CREATE SERVER cubrid_conn HOST 'localhost' PORT 33000 DBNAME 'testdb' USER 'dba' PASSWORD 'password';
CREATE SYNONYM synonym_cu FOR emp@cubrid_conn;
SELECT * FROM synonym_cu;
DROP SYNONYM synonym_cu;
DROP SERVER cubrid_conn;
EOF
```

### 검증 포인트

1. **에러 없이 실행되는지 확인**
   - `ERROR: dblink - Syntax: Unknown class "public.emp"` 같은 에러가 발생하지 않아야 함

2. **원격 SQL 로그 확인** (가능한 경우)
   - 원격 서버 로그에서 실제 전달된 SQL 확인
   - `SELECT * FROM emp` 형태여야 함 (not `SELECT * FROM public.emp`)

3. **카탈로그 확인**
   ```sql
   SELECT target_name FROM db_synonym WHERE synonym_name = 'synonym_cu';
   ```

---

## 방법 2: Parser 함수 직접 테스트 (고급)

**장점:**
- 특정 함수만 집중적으로 테스트 가능
- 빠른 피드백

**단점:**
- 많은 mock/stub 필요
- parser context, DB 연결 등 복잡한 초기화 필요

### 예시 구조

`unit_tests/parser/` 디렉토리를 만들고 다음과 같은 구조로 작성:

```
unit_tests/parser/
├── CMakeLists.txt
├── test_dblink_synonym.cpp
├── test_dblink_synonym.hpp
└── test_main.cpp
```

### 예시 코드 (개념)

```cpp
// test_dblink_synonym.cpp
#include "test_dblink_synonym.hpp"
#include "parser.h"
#include "parser_support.c"  // static 함수를 테스트하려면...

namespace test_dblink_synonym
{
  void test_schema_preservation()
  {
    // PARSER_CONTEXT 초기화
    PARSER_CONTEXT *parser = parser_create_parser();
    
    // PT_NODE 생성 및 설정
    PT_NODE *spec = parser_new_node(parser, PT_SPEC);
    // ... entity_name 설정 (public.emp@cubrid_conn)
    
    // pt_convert_dblink_synonym 호출
    // 결과 확인: entity_name->original이 "public.emp"인지
    
    parser_free_parser(parser);
  }
  
  void test_schema_stripping()
  {
    // emp@cubrid_conn (스키마 없음) 테스트
    // 결과 확인: entity_name->original이 "emp"인지
  }
}
```

**주의사항:**
- `parser_support.c`의 static 함수를 테스트하려면 해당 파일을 include하거나 함수를 extern으로 노출해야 함
- 많은 의존성(memory allocator, DB connection 등) 초기화 필요
- 실제로는 매우 복잡하고 시간이 많이 소요됨

---

## 권장 접근: SQL 통합 테스트

**이유:**
1. **실용성**: 실제 사용 시나리오를 정확히 반영
2. **간단함**: 이미 작성한 SQL 테스트 케이스 활용
3. **유지보수**: 코드 변경 시에도 테스트가 계속 유효

**추가 개선:**
- `.cursor/test_dblink_synonym.sql`을 `test/` 또는 `sql/` 디렉토리로 이동
- CI/CD 파이프라인에 통합
- 테스트 결과를 자동으로 검증하는 스크립트 작성

---

## CI/CD 통합 예시

```bash
#!/bin/bash
# test_dblink_synonym.sh

set -e

# CUBRID 서버 시작
cubrid server start testdb

# 테스트 실행
csql -u dba -C test_dblink_synonym.sql > test_output.log 2>&1

# 에러 확인
if grep -q "Unknown class.*public\." test_output.log; then
  echo "FAIL: Schema prefix error found"
  exit 1
fi

echo "PASS: All tests passed"
```

---

## 결론

**권장: 방법 1 (SQL 통합 테스트)**
- 이미 작성한 `.cursor/test_dblink_synonym.sql` 활용
- 실제 동작을 검증하는 가장 확실한 방법
- 추가 개발 시간 최소화

**선택: 방법 2 (Parser 함수 직접 테스트)**
- 특정 함수만 집중 테스트가 필요한 경우
- 많은 초기 작업과 유지보수 필요
