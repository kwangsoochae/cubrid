-- TC-104: outer 조인 키가 NULL인 경우 (plan.md 참고: NULL·에러 처리)
-- 전제: setup_edge_cases_local.sql (로컬), 기존 remote_t (원격) 사용
--
-- 시나리오: local_null_key_t에 id=NULL 행 포함
--
-- 기대 동작:
--   Before (최적화 전): id=NULL 행은 remote_t 전체 스캔 후 조인 조건 l.id = r.id 평가 → NULL = any → false → 결과 제외
--   After  (최적화 후): id=NULL → join_key_regus[0] 평가 결과 NULL → execute 스킵 (no_result=true) → S_END
--   → 두 경우 모두 NULL key 행은 결과에 나타나지 않아야 함 (INNER JOIN 시맨틱 동일)
--
-- 검증: NULL key 행(lnk_null)이 결과에 없음. 총 3행 (id=1: 1행, id=2: 2행).

SELECT l.id, l.name, r.name
FROM local_null_key_t l, remote_t@cubrid_conn r
WHERE l.id = r.id
ORDER BY l.id, r.name;
