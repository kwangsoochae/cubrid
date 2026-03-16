-- TC-114: 동일 outer key 다수 반복 + remote N행 — worst case 정합성 (CBRD-26601 §3.2)
-- 전제: setup_local.sql, setup_remote.sql 선행. cubrid_conn 생성됨.
-- 시나리오: local_t에 id=5를 기존 1행에서 5행으로 늘림. remote_t에 id=5는 3행.
--   각 outer 행마다 cci_execute → remote에서 3행 수신 → instnum(LIMIT 1) → 'remote_e1' 반환.
--   access_pred(r.id = l.id) 제거 후에도 5개 outer 행이 각각 올바른 결과를 독립적으로 반환하는지 확인.
--   (오매칭이 있으면 remote_name이 NULL이 되거나 'remote_e1'이 아닌 값이 나와 버그 감지 가능.)
-- 기대: 5행(local_5 ~ local_5e), 모두 remote_name = 'remote_e1'.

INSERT INTO local_t VALUES (5, 'local_5b');
INSERT INTO local_t VALUES (5, 'local_5c');
INSERT INTO local_t VALUES (5, 'local_5d');
INSERT INTO local_t VALUES (5, 'local_5e');
COMMIT;

SELECT l.id, l.name,
  (SELECT r.name FROM remote_t@cubrid_conn r WHERE r.id = l.id ORDER BY r.name LIMIT 1) AS remote_name
FROM local_t l
WHERE l.id = 5
ORDER BY l.id, l.name;

DELETE FROM local_t WHERE id = 5 AND name IN ('local_5b', 'local_5c', 'local_5d', 'local_5e');
COMMIT;
