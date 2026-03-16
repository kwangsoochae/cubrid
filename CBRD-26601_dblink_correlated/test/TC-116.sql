-- TC-116: AND 비상관 범위 조건 — correlated 제거 후 비상관 조건 독립 동작 확인 (CBRD-26601 §3.2)
-- 전제: setup_local.sql, setup_remote.sql 선행. cubrid_conn 생성됨.
-- 시나리오: WHERE 절에 correlated 조건(r.id = l.id)과 비상관 범위 조건(r.id < 3) 혼합.
--   correlated 조건만 제거한 뒤, 비상관 조건(r.id < 3)이 독립적으로 올바르게 동작하는지 확인.
--   id=3: r.id=l.id=3이지만 r.id < 3 불만족 → NULL이어야 함.
--   (비상관 조건이 제거되었거나 잘못 처리되면 id=3에 'remote_c1'이 나와 버그 감지 가능.)
-- 기대:
--   id=1 → 'remote_a1' (r.id=1, 1 < 3 통과)
--   id=2 → 'remote_b1' (r.id=2, 2 < 3 통과, LIMIT 1)
--   id=3 → NULL (r.id=3, 3 < 3 불만족)
--   id=4 → NULL (원래 매칭 없음)
--   id=5 → NULL (r.id=5, 5 < 3 불만족)

SELECT l.id, l.name,
  (SELECT r.name FROM remote_t@cubrid_conn r
   WHERE r.id = l.id AND r.id < 3
   ORDER BY r.name LIMIT 1) AS remote_name
FROM local_t l
ORDER BY l.id;
