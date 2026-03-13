-- TC-601: Worst case — 고선택도 (outer_count × avg_matching >> remote_count)
-- 전제: setup_worst_case_remote.sql (원격), setup_worst_case_local.sql (로컬) 실행 완료
--
-- 시나리오: outer 100행 (id 1-10, 10개씩), remote 1,000행 (id 1-10, 100개씩)
--   → outer 1행당 100개 매칭 (선택도 100%)
--
-- Before (최적화 전):
--   1 execute → 1,000행 fetch (전체, 1회)
--   outer 100행마다 cursor reset → 로컬에서 1,000행 × 100 = 100,000번 predicate 평가
--
-- After (최적화 후):
--   100 executes × 100행 fetch = 10,000행 fetch (Before의 10배)
--   + 100회 execute round-trip 오버헤드 (Before의 100배)
--
-- 기대: After 실행 시간 >= Before (최적화가 오히려 불리한 케이스)
--   → 향후 cost 기반 최적화 적용 여부 판단의 근거
--
-- 측정:
--   csql> ;time on
--   csql> ;read TC-601.sql
--   csql> ;run
--   → Before/After 실행 시간 비교. 결과 COUNT = 10,000 (정확성).

SELECT COUNT(*) AS result_count
FROM local_hiselectivity_t l, remote_hiselectivity_t@cubrid_conn r
WHERE l.id = r.id;
