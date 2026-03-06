# T0-1 검증: "원격 컬럼 = 로컬 컬럼" 조건의 푸시 제외 메커니즘

| 항목 | 내용 |
|------|------|
| 이슈 | CBRD-26553 |
| 태스크 | T0-1 |
| 파일 | `src/parser/view_transform.c` |

---

## 1. 검증 목표

"원격 컬럼 = 로컬 컬럼" 형태의 term이 dblink 푸시 대상에서 **제외되는지** 코드로 확인하는 것.

---

## 2. 결론

**결과**: "원격 컬럼 = 로컬 컬럼" 조건은 **푸시 대상에서 제외되며**, 제외 메커니즘은 **`others_found`** 이다. `correlated_found` 경로가 아니라 **`PT_PUSHABLE_TERM`의 `!others_found` 조건**에서 걸린다.

---

## 3. 코드 흐름

### 3.1 진입점

```text
mq_rewrite_dblink_as_subquery ()  →  mq_copypush_sargable_terms_dblink (호출 경로)
                                    ↓
mq_copypush_sargable_terms ()     →  mq_copypush_sargable_terms_helper ()
```

dblink 쿼리 rewrite 시 `mq_copypush_sargable_terms_helper()`가 WHERE term을 순회하며 `pt_check_pushable_term()`으로 푸시 가능 여부를 판단한다.

### 3.2 pt_check_pushable_term() (4021~4058행)

```c
static bool
pt_check_pushable_term (PARSER_CONTEXT * parser, PT_NODE * term, FIND_ID_INFO * infop)
{
  bool is_correlated_with_agg = false;
  bool is_correlated_with_dblink = false;
  PT_NODE *derived;

  /* init output section */
  infop->out.found = false;
  infop->out.others_found = false;
  infop->out.correlated_found = false;
  infop->out.pushable = true;

  parser_walk_leaves (parser, term, pt_find_only_name_id, infop, NULL, NULL);

  if (infop->out.correlated_found)
    {
      if (pt_has_aggregate (...))
        is_correlated_with_agg = true;
      if (infop->in.spec && derived->node_type == PT_DBLINK_TABLE)
        is_correlated_with_dblink = true;
    }

  return PT_PUSHABLE_TERM (infop) && !is_correlated_with_agg && !is_correlated_with_dblink;
}
```

### 3.3 PT_PUSHABLE_TERM 매크로 (46~47행)

```c
#define PT_PUSHABLE_TERM(p) \
  ((p)->out.pushable && (p)->out.found && !(p)->out.others_found)
```

### 3.4 pt_find_only_name_id() (3867~3976행)

term에서 PT_NAME을 walk할 때:

| 조건 | spec_id 매칭 | 설정 |
|------|--------------|------|
| spec의 컬럼 | `node->info.name.spec_id == spec->info.spec.id` | `found = true` |
| others_spec_list의 컬럼 | `node->info.name.spec_id == spec->info.spec.id` (다른 spec) | `others_found = true` |
| 그 외 (outer query 등) | 위 둘 모두 불일치 | `correlated_found = true` |

### 3.5 "원격 컬럼 = 로컬 컬럼" 예시

```sql
SELECT * FROM local_t, remote_t@dblink WHERE local_t.id = remote_t.id
```

- spec = `remote_t@dblink`
- others_spec_list = `[local_t, remote_t@dblink]` (FROM 절 전체)

| term 구성 | walk 결과 |
|-----------|-----------|
| `remote_t.id` | spec_id == spec → `found = true` |
| `local_t.id` | spec_id == local_t (others_spec_list) → `others_found = true` |

### 3.6 결론

- `others_found = true` → `PT_PUSHABLE_TERM(infop) = false` (매크로의 `!others_found` 조건)
- `pt_check_pushable_term()` 반환값 = `false && ...` → **푸시 불가**

`correlated_found`는 설정되지 않으며, `is_correlated_with_dblink` 분기도 실행되지 않는다. 제외는 **`others_found`** 에 의해 발생한다.

---

## 4. 요약

| 구분 | 내용 |
|------|------|
| 제외 여부 | 예, 푸시 대상에서 제외됨 |
| 제외 메커니즘 | `PT_PUSHABLE_TERM`의 `!others_found` 조건 |
| 관련 코드 | `pt_find_only_name_id()` 3960~3966행 (others_spec_list 매칭 시 `others_found = true`) |
| `correlated_found` | "원격=로컬" 케이스에서는 해당 없음 (outer query 등 다른 경우에만 사용) |

---

## 5. T1-1 구현 시 참고

T1-1에서 "원격 컬럼 = 로컬 컬럼"을 푸시 허용하려면:

- `pt_check_pushable_term()` 반환 전에 `others_found`로 제외되는 경우를 **예외**로 처리해야 한다.
- 또는 `pt_find_only_name_id()`에서 "원격=로컬" 형태를 별도로 판별하는 로직이 필요하다.
- plan의 `pt_is_dblink_join_key_equality()` 등으로 "원격=로컬" 단일 등치를 판별한 뒤, 해당 조건일 때 `others_found`를 무시하고 푸시 허용하는 방향이 적절하다.
