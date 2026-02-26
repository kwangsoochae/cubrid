-- TC-102: 0건 매칭(inner join) (FR-7, T5-1)
-- 전제: 동일 스키마·데이터. id=4는 로컬에만 있고 원격에는 없음.
-- 기대: id=4는 결과에 없음. 총 7행. 푸시 적용 시에도 동일.

SELECT l.id, l.name, r.name
FROM local_t l, remote_t@cubrid_conn r
WHERE l.id = r.id
ORDER BY l.id, r.name;
