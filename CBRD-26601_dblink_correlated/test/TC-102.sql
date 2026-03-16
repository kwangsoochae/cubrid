-- TC-102: outer key NULL → subquery NULL 반환, re-execute 스킵 (FR-6, T3-3, T6-5)
-- 전제: setup_local.sql, setup_remote.sql 로 스키마·데이터 적재 완료. cubrid_conn 생성됨.
-- local_t에 id=NULL 행을 추가 후 쿼리 실행, 이후 제거.
-- 기대: 2행. id=NULL 행 → remote_name=NULL (re-execute 없이 스킵). id=1 행 → 정상 매칭 확인.

INSERT INTO local_t VALUES (NULL, 'local_n');
COMMIT;

SELECT l.id, l.name,
  (SELECT r.name FROM remote_t@cubrid_conn r WHERE r.id = l.id ORDER BY r.name LIMIT 1) AS remote_name
FROM local_t l
WHERE l.id IS NULL OR l.id = 1
ORDER BY l.id;

DELETE FROM local_t WHERE id IS NULL AND name = 'local_n';
COMMIT;
