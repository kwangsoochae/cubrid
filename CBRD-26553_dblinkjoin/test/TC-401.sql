-- TC-401: 원격 전송 행 수·실행 계획 (선택, T5-3)
-- 푸시 적용 시 원격에서는 조인 조건 만족 행만 전송되므로, 전체 fetch 대비 전송 행 수 감소.
-- 기대: (선택) 실행 계획/트레이스에 rebind·execute 반영 여부 확인. 성능 측정 시 7행만 수신.

SELECT l.id, l.name, r.name
FROM local_t l, remote_t@cubrid_conn r
WHERE l.id = r.id
ORDER BY l.id, r.name;
