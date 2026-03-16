-- TC-109: outer 중복 키 — access_pred 없이 각 outer 행 독립 실행 (CBRD-26601 §3.2 access_pred 제거 검증)
-- 전제: setup_local.sql, setup_remote.sql 선행. cubrid_conn 생성됨.
-- 시나리오: local_t에 id=2 행을 2개 추가 → 동일 outer key가 3행 존재.
--   access_pred(r.id = l.id)를 제거한 상태에서도 outer 행마다 독립적으로
--   remote execute가 실행되고 각각 올바른 결과를 반환하는지 확인.
-- 기대: 3행, 모두 remote_name = 'remote_b1' (LIMIT 1 ORDER BY r.name 기준 최솟값).
--   remote_t에 r.id=2 행이 'remote_b1', 'remote_b2' 두 개이므로 LIMIT 1 → 'remote_b1'.

INSERT INTO local_t VALUES (2, 'local_2b');
INSERT INTO local_t VALUES (2, 'local_2c');
COMMIT;

SELECT l.id, l.name,
  (SELECT r.name FROM remote_t@cubrid_conn r WHERE r.id = l.id ORDER BY r.name LIMIT 1) AS remote_name
FROM local_t l
WHERE l.id = 2
ORDER BY l.id, l.name;

DELETE FROM local_t WHERE id = 2 AND name IN ('local_2b', 'local_2c');
COMMIT;
