# DBLink Correlated — AS-IS 대비 TO-BE Worst Case

| 항목 | 내용 |
|------|------|
| 이슈 | CBRD-26601 |
| 관련 문서 | [Design Doc](03_dblink_correlated_Desgin_Doc.md), [Tasks](04_dblink_correlated_Tasks.md) |
| 목적 | SELECT 절 correlated 스칼라 서브쿼리에서 TO-BE(outer 행마다 re-execute)가 AS-IS(원격 1회 전체 fetch)보다 불리해지는 worst case 조건(outer 행 수가 많고 remote가 작은 경우, outer correlation 키의 cardinality가 낮은 경우)을 분석한다. |

---

## 1. 질의

```sql
SELECT l.id,
       (SELECT r.name FROM remote_t@conn r WHERE r.id = l.id)
FROM local_t l;
```

- **l.id**: outer(local_t)의 correlation 키
- **r.id**: 원격(remote_t)의 키 — **unique**

---

## 2. AS-IS / TO-BE conn_sql

| 방식 | conn_sql |
|------|----------|
| AS-IS | `SELECT name, id FROM remote_t r` (WHERE 없음) |
| TO-BE | `SELECT name, id FROM remote_t r WHERE r.id = ?` |

- AS-IS: 원격 전체를 1회 fetch, `r.id = l.id` 조건은 **로컬**에서 평가.
- TO-BE: outer 행마다 `?`에 현재 l.id를 바인딩하여 원격 실행.

---

## 3. Worst Case 발생 조건

| 조건 | 값 |
|------|-----|
| outer 행 수 (N) | 많음 |
| r.id | unique (k=1, 키당 원격 매칭 1행) |
| l.id cardinality | **낮음** (중복 많음) |

- l.id 값이 소수의 종류만 존재 → 같은 `?` 값으로 TO-BE가 반복 실행됨.
- r.id가 unique이므로 round-trip당 전송은 1행이지만, l.id 중복 횟수만큼 **같은 원격 행을 반복 fetch**.

---

## 4. 수치 예시

- **가정**: outer 10,000행, r.id unique, l.id 값 10종류(각 1,000개 outer 행이 같은 값 공유).

| 방식 | Round-trip | 전송 행 수 | 비고 |
|------|------------|------------|------|
| AS-IS | **1회** | **M행** (원격 전체) | M=10이면 10행 |
| TO-BE | **10,000회** | **10,000행** | 1행 × 10,000회, 동일한 10행 반복 |

M = 10이라면 AS-IS **10행** vs TO-BE **10,000행** — **1,000배 차이**.

---

## 5. Worst Case의 원인

1. **l.id(outer correlation 키)의 낮은 cardinality** — 같은 키로 TO-BE가 반복 실행됨.
2. **TO-BE의 행 단위 재실행 모델** — 결과를 캐시·공유하지 않고 outer 행마다 원격 재실행.

→ 데이터 분포(N 대비 l.id 종류 수)에 따라 AS-IS가 유리할 수 있다.

---

## 6. CBRD-26553 POC 결과 기반 추정

CBRD-26553(`dblink_join_improve` 브랜치)의 POC 결과를 참고하여 CBRD-26601 AS-IS/TO-BE의 예상 성능을 추정한다.

**추정 근거:**
- CBRD-26601 **AS-IS** = 원격 전체 1회 fetch → CBRD-26553 **Before**와 동일 구조
- CBRD-26601 **TO-BE** = outer 행마다 execute → CBRD-26553 **After**와 동일 구조
- 따라서 CBRD-26553 실측값을 CBRD-26601 AS-IS/TO-BE 예상값으로 적용할 수 있다.

**참조 문서:** `dblink_join_improve:CBRD-26553_dblinkjoin/docs/CBRD-26553_dblinkjoin_POC_report.md`

| POC | 조건 | AS-IS (예상) | TO-BE (예상) | 배율 | 판정 |
|-----|------|-------------|-------------|------|------|
| A | outer 10, remote 100,000, 매칭 10건 (r.id unique) | ~0.491s | ~0.018s | 27x 빠름 | ✅ TO-BE 유리 |
| B | outer 10, remote 100,000, 매칭 0건 | ~0.481s | ~0.020s | 24x 빠름 | ✅ TO-BE 유리 |
| C | outer 100, remote 1,000, outer당 100건 매칭 (r.id non-unique) | ~0.023s | ~0.095s | 4x 느림 | ❌ AS-IS 유리 |
| D | outer 1,000, remote 5 (r.id unique) | ~0.017s | ~0.272s | 16x 느림 | ❌ AS-IS 유리 |
| E | outer 10, remote 100,000, outer당 10,000건 매칭 (전송량 동일) | ~0.228s | ~0.481s | 2x 느림 | ❌ AS-IS 유리 |

**POC-C, E 주의:**
- r.id non-unique → scalar subquery는 outer당 매칭 행 전체를 수신 후 로컬에서 1건만 사용.
- TO-BE 전송 행 수(C: 10,000행, E: 100,000행)는 CBRD-26553 After와 동일하므로 timing도 유사하게 적용.

**POC-D가 worst case의 전형:**
- outer 1,000행, remote 5행(소규모) — AS-IS는 5행 1회 fetch, TO-BE는 1,000회 execute.
- 전송 행 수는 동일(5행)해도 **execute overhead**만으로 16x 역효과.
- l.id 중복이 많을수록 같은 remote 행을 반복 fetch하여 역효과가 더 커진다.

---

## 7. Worst Case 발생 가능성 — 일반화 추론

Worst case 발생 여부는 **데이터 분포와 outer 필터 조건**에 따라 달라진다.

**Worst case가 발생하기 쉬운 조건:**

- **N이 크고 remote가 작은 경우** (POC-D 패턴)
  - remote가 코드 테이블·참조 테이블(수백~수천 행)이고, outer 필터 없이 N이 큰 경우.
  - 예: `FROM local_t l` (필터 없음), remote_t = 국가코드(200행) → TO-BE 불리.
- **l.id cardinality가 낮은 경우** (CBRD-26601 특유)
  - 같은 l.id 값으로 TO-BE가 반복 실행 → 동일 remote 행 중복 fetch.
  - 예: orders.customer_id — 고객 1명당 수백 건이면 같은 키로 수백 번 execute.
- **WAN 환경**
  - execute overhead가 loopback(~28ms)보다 훨씬 크므로 POC-E 수준의 조건에서도 역효과가 심화.

**완화 요인:**

- outer 필터가 있으면 N이 줄어 TO-BE의 round-trip 비용도 함께 감소.
  - 예: `WHERE l.status = 'active' AND l.date > '2026-01-01'` → N이 충분히 작으면 TO-BE도 경쟁력 있음.
- remote가 크고 outer가 적은 쿼리(POC-A, B 패턴)에서는 TO-BE가 명확히 유리.
- remote가 클수록 AS-IS의 전송 부담이 커지므로 실무에서는 TO-BE가 유리한 케이스가 더 많을 수 있음. SELECT 절에 correlated 서브쿼리가 여러 개면 이 부담이 서브쿼리 수에 비례해 늘어나 그 차이가 더욱 두드질 것으로 보임.

---

## 8. 문서 이력

| 일자 | 내용 |
|------|------|
| 2026-03-16 | 초안 작성 (l.id 중복 많을 때 AS-IS 대비 TO-BE worst case 설명). |
| 2026-03-16 | CBRD-26553 POC 결과 기반 AS-IS/TO-BE 예상값 추가. |
| 2026-03-17 | 서브쿼리 패턴에서의 완화 요인 추가 (§7). |
