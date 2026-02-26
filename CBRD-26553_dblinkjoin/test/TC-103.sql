-- TC-103: 1:N 매칭 행 수 (FR-7, T5-1)
-- 전제: 동일 스키마·데이터. id=2는 원격 2건, id=5는 원격 3건 매칭.
-- 기대: 총 7행 (1+2+1+3). 푸시 적용 시 행 수 동일.

SELECT l.id, l.name, r.name
FROM local_t l, remote_t@cubrid_conn r
WHERE l.id = r.id
ORDER BY l.id, r.name;
