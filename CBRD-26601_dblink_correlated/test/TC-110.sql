-- TC-110: AND 상수(비상관) 조건 혼합 — correlated 조건 제거 후 비상관 필터 정확성 (CBRD-26601 §3.2)
-- 전제: setup_local.sql, setup_remote.sql 선행. cubrid_conn 생성됨.
-- 시나리오: WHERE 절에 correlated 조건(r.id = a.id)과 비상관 조건(r.name LIKE 'remote_b%') 혼합.
--   access_pred에서 correlated 조건(r.id = a.id)만 제거/대체한 뒤
--   비상관 조건(r.name LIKE 'remote_b%')이 올바르게 남아 필터링되는지 확인.
-- 기대:
--   id=1 → remote r.id=1 수신('remote_a1'), LIKE 'remote_b%' 불일치 → NULL
--   id=2 → remote r.id=2 수신(2행), LIKE 통과('remote_b1','remote_b2') → LIMIT 1 → 'remote_b1'
--   id=3 → remote r.id=3 수신('remote_c1'), LIKE 불일치 → NULL
--   id=4 → remote 수신 없음 → NULL
--   id=5 → remote r.id=5 수신(3행, 'remote_e*'), LIKE 불일치 → NULL

SELECT a.id, a.name,
  (SELECT r.name FROM remote_t@cubrid_conn r
   WHERE r.id = a.id AND r.name LIKE 'remote_b%'
   ORDER BY r.name LIMIT 1) AS remote_name
FROM local_t a
ORDER BY a.id;
