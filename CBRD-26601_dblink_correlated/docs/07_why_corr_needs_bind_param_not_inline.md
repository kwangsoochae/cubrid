# 기존 인라인 경로가 상관 조건에 쓸 수 없는 이유, 그리고 CBRD-26601의 설계

| 항목 | 내용 |
|------|------|
| 관련 태스크 | T1-2 (`mq_dblink_append_corr_pred_sql`), T2-1 (`corr_key_regu_list`), T3-2 (`cci_bind_param`) |
| 관련 문서 | [09 비상관 분석](09_dblink_uncorrelated_scalar_subquery_Source_Analysis.md), [04 Tasks](04_dblink_correlated_Tasks.md) |
| 핵심 질문 | 비상관에서 `pt_copypush_terms`가 `id=1`을 인라인으로 처리하듯, 상관 조건 `r.id=l.id`도 같은 경로에서 `r.id=?`로 처리할 수 없나? |

---

## 목차

1. [두 케이스 나란히 보기](#1-두-케이스-나란히-보기)
2. [기존 인라인 경로가 상관 조건에 작동하지 않는 근본 이유](#2-기존-인라인-경로가-상관-조건에-작동하지-않는-근본-이유)
3. [`pt_check_pushable_term`의 차단 — 위 두 문제의 결과](#3-pt_check_pushable_term의-차단--위-두-문제의-결과)
4. [CBRD-26601의 설계 선택: 별도 경로 + `?` + 런타임 바인드](#4-cbrd-26601의-설계-선택-별도-경로---런타임-바인드)
5. [전체 흐름 대조](#5-전체-흐름-대조)
6. [요약](#6-요약)

---

## 1. 두 케이스 나란히 보기

```sql
-- [A] 비상관: 상수 조건
SELECT l.id, (SELECT r.name FROM remote_t@cubrid_conn r WHERE r.id = 1) FROM local_t l

-- [B] 상관: outer 참조
SELECT l.id, (SELECT r.name FROM remote_t@cubrid_conn r WHERE r.id = l.id) FROM local_t l
```

| | [A] `r.id = 1` (비상관 상수) | [B] `r.id = l.id` (상관) |
|--|------------------------------|--------------------------|
| 목표 원격 SQL | `WHERE id=1` | `WHERE id=?` (바인드 파라미터) |
| 현재 구현 | `pt_copypush_terms` 인라인 | T1-2 `mq_dblink_append_corr_pred_sql` |
| `pt_copypush_terms` 사용 가능? | 예 | **아니오** (이유: §2) |

---

## 2. 기존 인라인 경로가 상관 조건에 작동하지 않는 근본 이유

`pt_copypush_terms`가 PT_DBLINK_TABLE 분기에서 수행하는 핵심 동작은 WHERE 조건을 **텍스트로 직렬화**하는 것이다:

```c
// view_transform.c L4159~4162
parser->custom_print |=
    PT_CONVERT_RANGE | PT_SUPPRESS_RESOLVED
    | PT_PRINT_NO_HOST_VAR_INDEX | PT_PRINT_SUPPRESS_FOR_DBLINK;

pushed_pred = pt_print_and_list(parser, query->info.dblink_table.pushed_pred);
```

이 경로가 상관 조건 `r.id = l.id`에 쓸 수 없는 이유는 두 가지다.

### 2.1 직렬화 오류 — `PT_SUPPRESS_RESOLVED`가 `l.id`를 망가뜨린다

`PT_SUPPRESS_RESOLVED` 플래그는 PT_NAME 출력 시 테이블 prefix를 억제한다(parse_tree_cl.c L13708):

```c
if (!(parser->custom_print & PT_SUPPRESS_RESOLVED)
    && (p->info.name.resolved && p->info.name.resolved[0]) ...)
  {
    q = pt_append_name(parser, q, p->info.name.resolved);  // "r." 또는 "l." 출력
    q = pt_append_nulstring(parser, q, ".");
  }
// 이 조건이 false → prefix 생략 → 컬럼 이름만 출력
```

`r.id = l.id`를 이 플래그로 출력하면:

```
r.id  --[PT_SUPPRESS_RESOLVED]-->  "id"
l.id  --[PT_SUPPRESS_RESOLVED]-->  "id"
                                   ↓
             pushed_pred = "id=id"   ← 동어반복(tautology)
```

원격 서버에 `WHERE id=id`가 전달된다. **항상 TRUE**, 필터링 효과 없음.

플래그를 끄면:

```
r.id = l.id  →  "r.id=l.id"   또는   "r.id=local_t.id"
```

원격 서버에는 `r`도 `l`도 `local_t`도 없다 → **문법 오류 / 실행 오류**.

**비교: 상수 `1`은 왜 잘 되나?**

`r.id = 1`에서 `1`은 `PT_VALUE` 노드다. PT_NAME이 아니므로 `PT_SUPPRESS_RESOLVED`와 무관하게 `"1"`로 그대로 직렬화된다.

```
r.id  →  "id"
1     →  "1"           ← PT_VALUE: 테이블 참조 없음, resolved 없음
          ↓
pushed_pred = "id=1"   ← 유효한 원격 SQL
```

### 2.2 값의 존재 시점 — `l.id`는 파싱 단계에 값이 없다

`pt_copypush_terms`는 **XASL 생성 전, 파싱 단계**에서 실행된다:

```
SQL 파싱
  ↓
pt_rewrite_for_dblink   ← PT_DBLINK_TABLE 노드 생성
  ↓
pt_compile (의미 분석)
  ↓
mq_translate
  ↓ ← pt_copypush_terms 여기서 실행
xasl_generation
  ↓
런타임 실행             ← outer 행 읽기, l.id 값 확정
```

이 시점에서 `l.id`는 아직 **"outer 테이블의 컬럼을 가리키는 PT_NAME 노드"**일 뿐이다.

| 값 | 파싱 시점 | XASL 생성 시점 | 런타임 시점 |
|---|-----------|---------------|------------|
| `1` | `PT_VALUE(1)` — **값 확정** | `XASL: TYPE_VALUE(1)` | 항상 1 |
| `l.id` | `PT_NAME("id", spec=local_t)` — **이름만** | `TYPE_CONSTANT(outer val_list slot)` | outer 행 읽을 때마다 다름 |

파싱 시점에 `l.id`에는 구체적인 숫자값이 없다. 인라인하려 해도 "무엇을 넣을지" 알 수 없다.

`?`를 텍스트로 넣는다고 해도, 그 `?`에 무엇을 언제 바인드할지를 `pt_copypush_terms`(정적 문자열 생성기)는 결정할 수 없다. 이것은 런타임 인프라의 영역이다.

---

## 3. `pt_check_pushable_term`의 차단 — 위 두 문제의 결과

`mq_copypush_sargable_terms_helper`(view_transform.c L4707)는 `pt_check_pushable_term`을 통과한 조건만 `pt_copypush_terms`에 전달한다:

```c
for (term = statement->info.query.q.select.where; ...)
  {
    if (pt_check_pushable_term(parser, term, infop))
      {
        push_term_list = parser_append_node(new_term, push_term_list);
      }
  }
if (push_cnt)
  pt_copypush_terms(parser, spec, subquery, push_term_list, ...);
```

`pt_check_pushable_term`(view_transform.c L4022)은 DBLink 스펙에 outer 참조가 있으면 명시적으로 차단한다:

```c
if (infop->out.correlated_found)
  {
    if (derived->node_type == PT_DBLINK_TABLE)
      {
        is_correlated_with_dblink = true;
      }
  }
return PT_PUSHABLE_TERM(infop) && !is_correlated_with_dblink;
```

**이 차단은 독립적인 장벽이 아니다.** 기존 `pt_copypush_terms` 경로로 진입하면 §2.1(tautology)과 §2.2(값 부재) 문제가 발생하므로 막아둔 것이다.

**"입구 차단을 해제하고 `pt_copypush_terms` 내부에서 분기하면 안 되나?"**

원칙적으로 가능하다. 차단을 해제하고 `pt_copypush_terms` 내부에서 correlated 여부를 재판단해 `?` 경로를 타도 된다. 단, §2.1/§2.2 우회 로직과 런타임 바인드 인프라를 `pt_copypush_terms` 안에 함께 구현해야 한다.

T1-2가 별도 경로(`mq_dblink_append_corr_pred_sql`)를 택한 이유:
- `pt_check_pushable_term`이 단순 `bool`을 반환 — "통과하되 특별 처리" 신호를 호출자에게 전달할 구조가 없다
- `pt_copypush_terms`에 내부 분기를 넣으면 비상관/상관 두 경로가 한 함수 안에 섞인다. 별도 함수로 분리하는 편이 책임 경계가 명확하다

---

## 4. CBRD-26601의 설계 선택: 별도 경로 + `?` + 런타임 바인드

§2의 두 문제를 우회하는 올바른 방법은 하나다:
- remote 컬럼 이름(`"id"`)만 출력하고, outer 참조(`l.id`)는 출력하지 않는다
- 값 자리는 `"?"` 리터럴로 채운다
- 런타임에 outer 값을 `cci_bind_param`으로 전달한다

이 세 단계가 각각 T1-2, T2-1, T3-2이며, CBRD-26601이 구현하는 핵심 내용이다.

### 4.1 T1-2 — 문자열 조립 (파싱 / view_transform·XASL)

**호출 시점(문서 고정):** `mq_rewrite_dblink_as_subquery`에서는 **메타(`corr_key_*`)만** 두고, `mq_dblink_append_corr_pred_sql`은 **`pt_copypush_terms(PT_DBLINK_TABLE)`에서 `rewritten` 할당 직후**(혼합 케이스) 또는 **T2-1에서 `rewritten == NULL`일 때**(순수 상관) 호출한다. 상세·표는 [04 Tasks §T1-2 유의 5](04_dblink_correlated_Tasks.md).

`mq_dblink_append_corr_pred_sql`(구현 위치: `view_transform.c` 등):

```c
static bool
mq_dblink_append_corr_pred_sql (PARSER_CONTEXT * parser, PT_DBLINK_INFO * di, PT_NODE * remote_col)
{
  // [1] remote 컬럼 이름만 출력 ("id")
  col_sql = mq_dblink_print_remote_col(parser, remote_col);
  // PT_SUPPRESS_RESOLVED → "r.id" → "id"
  // ← outer ref인 "l.id"는 아예 출력하지 않음

  // [2] 기존 rewritten 문자열 확인 후 WHERE/AND 선택
  if (has_where)
    base = pt_append_bytes(parser, base, " AND ", 5);
  else
    base = pt_append_bytes(parser, base, " WHERE ", 7);

  // [3] "id = ?" 조립 — 값은 런타임으로 위임
  base = pt_append_varchar(parser, base, col_sql);   // "id"
  base = pt_append_bytes(parser, base, " = ?", 4);  // " = ?"

  di->rewritten = base;  // "SELECT name, id FROM remote_t r WHERE id = ?"
  return true;
}
```

### 4.2 T2-1 — `corr_key_regu_list` 저장 (XASL 생성 단계)

`pt_to_dblink_table_spec_list` 또는 `pt_to_subquery_table_spec_list`(xasl_generation.c):

```c
if (pdblink->corr_key_count > 0) {
    // outer ref "l.id" → TYPE_CONSTANT regu (outer val_list slot 참조)
    dblink_spec->corr_key_count = pdblink->corr_key_count;
    dblink_spec->corr_key_regu_list =
        pt_to_regu_variable_list(parser, pdblink->corr_key_outer_refs, ...);
}
```

`l.id`가 런타임에 어떤 val_list 슬롯에 있는지를 XASL에 기록한다. 이 regu가 `xasl_to_stream.c`를 통해 서버로 전달된다. **이 필드(`corr_key_count`, `corr_key_regu_list`)의 추가가 T0-2로 이미 완료되어 있다.**

### 4.3 T3-2 — outer 값 바인드 (런타임, outer 행마다)

`dblink_open_scan()`(dblink_scan.c):

```c
// cci_prepare: "... WHERE id = ?"  ← 1회만
stmt_handle = cci_prepare(conn_handle, conn_sql, ...);

// outer 행 읽은 후, execute 전에 바인드
for (i = 0; i < scan_info->corr_key_count; i++) {
    fetch_peek_dbval(..., scan_info->corr_key_regus[i], ..., &dbval);
    //                    ↑ TYPE_CONSTANT regu → outer val_list에서 현재 l.id 값 읽기

    // pos = (앱 ? 개수) + i + 1  ← 앱 ?와 겹치지 않게
    cci_bind_param(stmt_handle, app_hv_count + i + 1,
                   cci_type, dbval, CCI_BIND_PTR);
}
cci_execute(stmt_handle, ...);  // 이제야 실행
```

outer 행마다:
- `l.id = 1` → `cci_bind_param(..., 1)` → 원격 `WHERE id=1` 실행
- `l.id = 2` → `cci_bind_param(..., 2)` → 원격 `WHERE id=2` 실행
- `l.id = 3` → `cci_bind_param(..., 3)` → 원격 `WHERE id=3` 실행

---

## 5. 전체 흐름 대조

```
┌────────────────────────────────────────────────────────────────────┐
│ [A] 비상관 상수  r.id = 1                                          │
├────────────────────────────────────────────────────────────────────┤
│  파싱 단계                                                         │
│  pt_check_pushable_term → correlated_found=false → 통과            │
│  pt_copypush_terms(PT_DBLINK_TABLE)                                │
│    pushed_pred = pt_print_and_list("r.id=1")                       │
│      PT_SUPPRESS_RESOLVED: r.id → "id"                            │
│      PT_VALUE(1): → "1"                                            │
│    rewritten = "SELECT name, id FROM remote_t r) cublink WHERE id=1"│
│                                                   ↑ 값 인라인       │
│                                                                    │
│  런타임                                                             │
│  cci_prepare("... WHERE id=1")                                     │
│  cci_execute()   ← 바인드 없음, 1회만 실행, 캐시 재사용             │
└────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────┐
│ [B] 상관  r.id = l.id                                              │
├────────────────────────────────────────────────────────────────────┤
│  파싱 단계                                                         │
│  pt_check_pushable_term → correlated_found=true + PT_DBLINK_TABLE  │
│    → 기존 경로(tautology 문제) 차단                                 │
│                                                                    │
│  T1-1 탐지 → PT_DBLINK_INFO.corr_key_* 메타 저장                    │
│  mq_dblink_append_corr_pred_sql (T1-2) — pt_copypush 직후 또는     │
│    T2-1(rewritten==NULL)에서 호출                                   │
│    mq_dblink_print_remote_col(r.id) → "id"  (l.id는 출력 안 함)   │
│    rewritten = "... WHERE id = ?"   ← "?" 자리 표시자만            │
│    PT_DBLINK_INFO.corr_key_outer_refs[0] = l.id PT_NODE 저장       │
│                                                                    │
│  XASL 생성 단계 (T2-1)                                             │
│  corr_key_regu_list = TYPE_CONSTANT(outer val_list slot for l.id)  │
│                                                                    │
│  런타임 (T3-2, outer 행마다)                                        │
│  cci_prepare("... WHERE id = ?")  ← 1회만                         │
│  for each outer row:                                               │
│    fetch_peek_dbval(corr_key_regus[0]) → 현재 l.id 값             │
│    cci_bind_param(stmt, pos, type, l_id_val)                       │
│    cci_execute()                   ← outer 행마다 N회             │
└────────────────────────────────────────────────────────────────────┘
```

---

## 6. 요약

기존 `pt_copypush_terms` 인라인 경로가 상관 조건에 쓸 수 없는 **근본 이유는 두 가지**다:

| 문제 | 원인 | 결과 |
|------|------|------|
| **직렬화 오류** | `pt_print_and_list` + `PT_SUPPRESS_RESOLVED`: `l.id` → `"id"` → `"id=id"` (tautology) 또는 원격에 없는 테이블명 | 원격 서버에서 실행 불가 / 의미 없는 결과 |
| **값의 부재** | 파싱 시점에 `l.id`는 PT_NAME 노드, 구체적 값 없음 | 인라인할 값 자체가 없음 |

`pt_check_pushable_term`의 차단은 위 두 문제가 발생하는 경로를 막은 결과다. 차단을 해제하고 내부 분기로 `?` 경로를 택하는 것도 원칙적으로 가능하다.

**`?` + 런타임 바인드**가 올바른 방향이며, 이것이 CBRD-26601이 구현하는 내용이다:

| 태스크 | 내용 | 단계 |
|--------|------|------|
| **T1-2** | remote 컬럼 이름만 출력 + `"= ?"` 추가 | 파싱 단계 |
| **T2-1** | outer ref(`l.id`) → `corr_key_regu_list`(TYPE_CONSTANT regu) 저장 | XASL 생성 단계 |
| **T3-2** | outer 행마다 `cci_bind_param` → `cci_execute` | 런타임 |

상수는 **컴파일 타임에 값이 확정**되어 인라인 가능하다. outer 참조는 **실행 타임에 행마다 값이 결정**되므로, 반드시 바인드 파라미터(`?`) + 런타임 바인드 인프라가 필요하며, 그것이 CBRD-26601의 설계다.
