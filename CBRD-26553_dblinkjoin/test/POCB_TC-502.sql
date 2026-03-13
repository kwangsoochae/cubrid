-- TC-502: 로컬 조인 조건 평가 부담 감소 측정 (PRD 3.2 효과 2)
-- 전제: setup_large_data_remote.sql (원격), setup_large_data_local.sql (로컬) 실행 완료
--
-- 시나리오: outer 10행 (id 10001-10010), remote 10,000행 (id 1-10,000) → 매칭 0건
-- 이 케이스가 효과 2의 극단적 예: 매칭이 없으면 Before는 가장 비효율적
--
-- Before (최적화 전):
--   remote_large_t 10,000행 전체 fetch → outer 10행마다 커서 reset → 전부 predicate 불일치
--   총 local predicate 평가: 10행 × 10,000행 = 100,000회, 전부 실패
--
-- After (최적화 후):
--   outer 10행마다 1 execute → WHERE id = 10001~10010 → 0행 즉시 반환 → 바로 S_END
--   총 remote fetch: 0행, local predicate 평가: 0회
--
-- 측정:
--   csql> ;time on
--   csql> ;read TC-502.sql
--   csql> ;run
--   → Before/After 실행 시간 비교. 결과 0행 (정확성 확인용).

SELECT l.id, l.name, r.val
FROM local_nomatch_t l, remote_large_t@cubrid_conn r
WHERE l.id = r.id
;
