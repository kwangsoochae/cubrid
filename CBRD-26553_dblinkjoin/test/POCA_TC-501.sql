-- TC-501: 원격 전송 행 수 감소 측정 (PRD 3.2 효과 1)
-- 전제: setup_large_data_remote.sql (원격), setup_large_data_local.sql (로컬) 실행 완료
--
-- 시나리오: outer 10행, remote 10,000행, 10건 매칭 (선택도 0.1%)
--
-- Before (최적화 전):
--   remote_large_t 10,000행 전체 fetch → 로컬에서 predicate 평가 → 10행 반환
--   전송 행 수: 10,000행
--
-- After (최적화 후):
--   outer 행마다 1 execute → 각 1행 반환 → 합계 10행 fetch
--   전송 행 수: 10행 (1/1,000 수준)
--
-- 측정:
--   csql> ;time on
--   csql> ;read TC-501.sql
--   csql> ;run
--   → Before 실행 시간과 After 실행 시간 비교. 행 수 = 10행 (정확성 확인용).

SELECT l.id, l.name, r.val
FROM local_small_t l, remote_large_t@cubrid_conn r
WHERE l.id = r.id
;
