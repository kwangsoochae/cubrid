-- TC-203: 앱 ? 있을 때 조인 키 푸시 미적용 (NFR-2, FR-6, T5-2)
-- 푸시된 predicate에 앱 host 변수(?)가 있으면 조인 키 푸시 미적용, 기존 방식으로 동작해야 함.
-- 참고: 앱 ?는 클라이언트 바인딩으로 전달되므로, csql에서 직접 실행하는 본 파일만으로는
--       "앱 ? 포함 쿼리"를 재현하기 어렵다. 실제 검증은 응용 프로그램/드라이버에서
--       prepared statement로 ? 를 바인딩한 조인 쿼리를 실행해 기존과 동일·regression 없음을 확인.
-- 아래는 동일 조인 쿼리(푸시 가능 형태)로, ? 없을 때 결과 7행 기준선만 확인.

SELECT l.id, l.name, r.name
FROM local_t l, remote_t@cubrid_conn r
WHERE l.id = r.id
ORDER BY l.id, r.name;
