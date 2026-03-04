-- TC-503: 원격 execute 횟수 측정 (PRD 3.2 효과 3)
-- 전제: 기존 소규모 데이터 (local_t 5행, remote_t 7행) 사용
--
-- 시나리오: outer 5행 (local_t: id 1,2,3,4,5)
--
-- Before (최적화 전):
--   remote_t에서 SELECT 1회 실행 → 결과셋 전체 보유 → outer마다 cursor reset
--   원격 DB execute 횟수: +1
--
-- After (최적화 후):
--   outer 5행마다 각 1 execute → WHERE id = ? 에 outer 키 바인딩
--   원격 DB execute 횟수: +5
--
-- 측정 방법 (원격 DB execute 횟수):
--   cubrid broker status -b 의 SELECT 컬럼 delta 로 측정
--   1) 쿼리 전: cubrid broker status -b (SELECT 컬럼 기록)
--   2) 아래 쿼리 실행
--   3) 쿼리 후: cubrid broker status -b (SELECT 컬럼 재측정)
--   4) delta = Before: 1, After: 5 (예상)
--
-- ※ After(최적화 후) 측정값은 구현 완료 후 검증 필요.
--   rebind+re-execute가 cci_execute 단위로 처리되면 delta=5 가 되지만,
--   구현 방식에 따라 달라질 수 있음.
--
-- 결과 정확성: TC-101과 동일한 7행

SELECT l.id, l.name, r.name
FROM local_t l, remote_t@cubrid_conn r
WHERE l.id = r.id
ORDER BY l.id, r.name;
