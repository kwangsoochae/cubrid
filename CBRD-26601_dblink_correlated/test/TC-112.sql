-- TC-112: 경계값 outer id (0, negative) — access_pred 없는 상태에서 오매칭 없음 확인 (CBRD-26601 §3.2)
-- 전제: setup_local.sql, setup_remote.sql 선행. cubrid_conn 생성됨.
-- 시나리오: remote_t에 존재하지 않는 id(0, -1)를 local에 임시 추가하여 서브쿼리 실행.
--   access_pred 제거 후에도 remote가 올바르게 0행을 반환하고 결과가 NULL인지 확인.
--   (오매칭 행이 있으면 NULL이 아닌 값이 나와 버그 감지 가능.)
-- 기대: 2행, 모두 remote_name = NULL.

INSERT INTO local_t VALUES (0, 'local_0');
INSERT INTO local_t VALUES (-1, 'local_neg1');
COMMIT;

SELECT l.id, l.name,
  (SELECT r.name FROM remote_t@cubrid_conn r WHERE r.id = l.id ORDER BY r.name LIMIT 1) AS remote_name
FROM local_t l
WHERE l.id <= 0
ORDER BY l.id;

DELETE FROM local_t WHERE id IN (0, -1);
COMMIT;
