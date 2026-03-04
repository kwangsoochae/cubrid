-- TC-205: 복합 조인 키 — 1차 미지원 경계 검증 (plan.md Step 1-1 주의 참고)
-- 전제: setup_edge_cases_local.sql (로컬), setup_edge_cases_remote.sql (원격) 실행 완료
--
-- 시나리오: WHERE l.id = r.id AND l.code = r.code (조인 키 2개)
--
-- 1차 동작:
--   단일 등치만 지원 → 복합 키는 push 미적용 → 기존 방식(1 execute + 로컬 필터)
--
-- 검증 포인트:
--   1) 결과 정확성: id만 매칭되는 행(rc_1C, rc_2D)은 code 조건에 걸려 최종 결과에서 제외
--      → 결과 2행 (lc_1A+rc_1A, lc_2B+rc_2B)
--   2) push 미적용 확인: remote statdump Num_query_selects delta = 1 (not 4)
--
-- 만약 push가 (잘못) id=? 로만 적용되더라도 로컬 code 필터가 동작하면 결과는 동일.
-- 어느 경우든 아래 expected와 일치해야 함.

SELECT l.id, l.code, l.name, r.val
FROM local_compound_t l, remote_compound_t@cubrid_conn r
WHERE l.id = r.id AND l.code = r.code
ORDER BY l.id, l.code;
