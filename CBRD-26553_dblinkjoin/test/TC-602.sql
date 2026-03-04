-- TC-602: Worst case — 다수 outer + 소규모 remote (execute round-trip 오버헤드)
-- 전제: setup_worst_case_remote.sql (원격), setup_worst_case_local.sql (로컬) 실행 완료
--
-- 시나리오: outer 1,000행 (id 1-1,000), remote 5행 (id 1-5)
--   → id 1-5만 매칭 (5건), id 6-1,000은 0건 매칭
--
-- Before (최적화 전):
--   1 execute → 5행 fetch (전체, 1회)
--   outer 1,000행마다 cursor reset → 로컬에서 5행 × 1,000 = 5,000번 predicate 평가
--
-- After (최적화 후):
--   1,000 executes (outer행마다 1회) → 총 5행 fetch (fetch 수는 동일)
--   + 1,000회 execute round-trip 오버헤드 (Before의 1,000배!)
--
-- 기대: After 실행 시간 >> Before (execute round-trip이 지배적)
--   → remote가 작고 outer가 많을 때 최적화가 역효과
--   → 고지연 네트워크(WAN)에서 더욱 심각
--
-- 측정:
--   csql> ;time on
--   csql> ;read TC-602.sql
--   csql> ;run
--   → Before/After 실행 시간 비교. 결과 5행 (정확성).
--
-- execute 횟수 측정 (선택):
--   원격 DB: cubrid statdump -c <remote_db> | grep Num_query_selects
--   Before: +1, After: +1,000

SELECT l.id, l.name, r.val
FROM local_manyouter_t l, remote_smalltable_t@cubrid_conn r
WHERE l.id = r.id
ORDER BY l.id;
