# TC 질의 결과 정답지 (Expected Results)

기준: `test_setup_dblink_databases.sh` + `test_run_dblink_join.sh` 후 `./run_tc.sh all` 실행 결과.  
출처: 터미널 실행 결과(정상 7행/8행 등)를 기록.

---

## TC-101 (단일 등치 조인 결과 일치)

**기대 행 수**: 7

```
           id  name                  name                
=========================================================
            1  'local_1'             'remote_a1'         
            2  'local_2'             'remote_b1'         
            2  'local_2'             'remote_b2'         
            3  'local_3'             'remote_c1'         
            5  'local_5'             'remote_e1'         
            5  'local_5'             'remote_e2'         
            5  'local_5'             'remote_e3'         
```

---

## TC-102 (0건 매칭 inner join)

**기대 행 수**: 7 (id=4는 원격에 없으므로 결과에 없음)

```
           id  name                  name                
=========================================================
            1  'local_1'             'remote_a1'         
            2  'local_2'             'remote_b1'         
            2  'local_2'             'remote_b2'         
            3  'local_3'             'remote_c1'         
            5  'local_5'             'remote_e1'         
            5  'local_5'             'remote_e2'         
            5  'local_5'             'remote_e3'         
```

---

## TC-103 (1:N 매칭 행 수)

**기대 행 수**: 7

```
           id  name                  name                
=========================================================
            1  'local_1'             'remote_a1'         
            2  'local_2'             'remote_b1'         
            2  'local_2'             'remote_b2'         
            3  'local_3'             'remote_c1'         
            5  'local_5'             'remote_e1'         
            5  'local_5'             'remote_e2'         
            5  'local_5'             'remote_e3'         
```

---

## TC-201 (푸시 불가 쿼리)

**기대 행 수**: 7

```
           id  name                  name                
=========================================================
            1  'local_1'             'remote_a1'         
            2  'local_2'             'remote_b1'         
            2  'local_2'             'remote_b2'         
            3  'local_3'             'remote_c1'         
            5  'local_5'             'remote_e1'         
            5  'local_5'             'remote_e2'         
            5  'local_5'             'remote_e3'         
```

---

## TC-202 (단일 dblink, 조인 없음)

**기대 행 수**: 7

```
           id  name                
===================================
            1  'remote_a1'         
            2  'remote_b1'         
            2  'remote_b2'         
            3  'remote_c1'         
            5  'remote_e1'         
            5  'remote_e2'         
            5  'remote_e3'         
```

---

## TC-203 (앱 ? 시 푸시 미적용 기준선)

**기대 행 수**: 7

```
           id  name                  name                
=========================================================
            1  'local_1'             'remote_a1'         
            2  'local_2'             'remote_b1'         
            2  'local_2'             'remote_b2'         
            3  'local_3'             'remote_c1'         
            5  'local_5'             'remote_e1'         
            5  'local_5'             'remote_e2'         
            5  'local_5'             'remote_e3'         
```

---

## TC-204 (LEFT JOIN ON)

**기대 행 수**: 8 (id=4는 r 쪽 NULL)

```
           id  name                  name                
=========================================================
            1  'local_1'             'remote_a1'         
            2  'local_2'             'remote_b1'         
            2  'local_2'             'remote_b2'         
            3  'local_3'             'remote_c1'         
            4  'local_4'             NULL                
            5  'local_5'             'remote_e1'         
            5  'local_5'             'remote_e2'         
            5  'local_5'             'remote_e3'         
```

---

## TC-301 (에러 전파)

수동/스크립트 검증. 결과 집합 정답지 없음. `test/TC-301.md` 참고.

---

## TC-401 (성능·실행 계획)

**기대 행 수**: 7 (TC-101과 동일 결과)

```
           id  name                  name                
=========================================================
            1  'local_1'             'remote_a1'         
            2  'local_2'             'remote_b1'         
            2  'local_2'             'remote_b2'         
            3  'local_3'             'remote_c1'         
            5  'local_5'             'remote_e1'         
            5  'local_5'             'remote_e2'         
            5  'local_5'             'remote_e3'         
```

---

## 요약 (행 수만)

| TC     | 기대 행 수 |
|--------|------------|
| TC-101 | 7          |
| TC-102 | 7          |
| TC-103 | 7          |
| TC-201 | 7          |
| TC-202 | 7          |
| TC-203 | 7          |
| TC-204 | 8          |
| TC-301 | — (수동)   |
| TC-401 | 7          |
