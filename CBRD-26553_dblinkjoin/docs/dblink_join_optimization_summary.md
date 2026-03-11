# DBLINK 조인 최적화 — 요약

상세 내용은 [dblink_join_optimization_work.md](dblink_join_optimization_work.md) 참고. 구현 단계·자료 구조는 [dblink_join_optimization_plan.md](dblink_join_optimization_plan.md) 참고.

---

## 한 줄 요약
리모트 테이블 **전체**를 가져와 로컬에서 조인하는 대신, **prepare + 조인 키 binding**으로 조인 키 등치(`remote.key = local.key`)를 **원격 WHERE 절에 직접 푸시**하고, 그 조건을 만족하는 행만 원격에서 가져오도록 변경한다. 푸시가 적용되지 않는 경우에는 기존 방식(전체 fetch 후 로컬 조인)을 그대로 유지한다.

**적용 조건**: Nested loop에서 **inner가 dblink인 경우에만** 적용. dblink가 outer이면 기존 방식(1회 execute 후 fetch) 유지.

---

## 현재 vs 목표

| 구분 | 현재 | 목표 |
|------|------|------|
| 원격 실행 | `cci_execute` 1회 → 결과셋 전체 확보 | prepare 1회, outer 행마다 **rebind → execute** |
| 데이터량 | 원격 테이블 전체(또는 푸시된 WHERE만) | 조인 조건 만족 행만 |
| 조인 조건 | 로컬에서 evaluation (correlated라 푸시 안 함) | `remote.key = ?` 로 푸시, ?에 로컬 조인 키 binding |

---

## 핵심 변경 포인트
- **Parser**: 조인 조건(원격 컬럼 = 로컬 컬럼)을 `?` 로 푸시 가능하도록 식별·치환 (WHERE만; ON 조건은 현재 미푸시).
- **Executor**: dblink open 시 prepare만, **outer 행 바뀔 때마다** vd로 rebind 후 execute → fetch.
- **Inner 판별 (T0-3)**: `is_generating_dblink_inner_scan` 플래그로 dblink가 NL/IDX inner일 때만 `join_key_count`·`rewritten` 적용. outer/hash/merge일 때는 기존 방식 유지.
- **XASL 구조 변경 (T4-3)**: push-down 후보 dblink spec은 rewrite 생략 → `PT_DERIVED_DBLINK_TABLE` 유지 → dblink scan이 `scan_ptr`에 직접 위치 → reset 시 rebind+execute 가능.
- **추가된 자료 구조**: PT(`join_key_local_refs`), XASL(`join_key_count`, `join_key_regu_list`), 실행기(scan_info에 `join_key_count`·`join_key_regus` 복사). 상세는 [dblink_join_optimization_plan.md](dblink_join_optimization_plan.md) 참고.

---

## 주요 파일
- 푸시 조건·rewrite 건너뛰기 (T4-3): `src/parser/view_transform.c`
- dblink 스펙/ host_var: `src/parser/xasl_generation.c`, `src/query/xasl.h`
- inner 판별 플래그: `src/optimizer/plan_generation.c` (`gen_inner`), `src/parser/parse_tree.h`
- 스캔/실행: `src/query/dblink_scan.c`, `src/query/scan_manager.c`

---

## 주의
- 푸시 조건이 불명확하면 **기존 방식(전체 fetch)** 유지.
- Oracle/MySQL Gateway 경유 조인에도 동일 최적화 적용 시 이득 있음.
