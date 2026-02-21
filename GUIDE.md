# PostgreSQL SELECT FOR UPDATE 완전 실습 가이드

## 환경 셋업

```bash
cd select-for-update-lab
docker compose up -d
```

터미널 **3개**를 열고 각각 psql 접속:

```bash
# Terminal 1 (TX-A)
docker exec -it pg-lock-lab psql -U lab -d lock_lab

# Terminal 2 (TX-B)
docker exec -it pg-lock-lab psql -U lab -d lock_lab

# Terminal 3 (Monitor) — 락 상태 관찰용
docker exec -it pg-lock-lab psql -U lab -d lock_lab
```

> **팁**: 각 터미널에서 `SELECT pg_backend_pid();`를 실행해 PID를 기억해 두세요.

---

## 0. 사전 지식: PostgreSQL의 Row-Level Lock 구조

`SELECT FOR UPDATE`는 **Row-Level Lock** 중 하나입니다. PostgreSQL은 별도의 락 테이블(lock table)이 아니라 **힙 튜플(heap tuple)의 헤더**에 직접 락 정보를 기록합니다.

### 튜플 헤더의 핵심 필드

| 필드 | 역할 |
|------|------|
| `xmin` | 이 튜플을 INSERT/UPDATE한 트랜잭션 ID |
| `xmax` | 이 튜플을 DELETE/UPDATE 했거나, **FOR UPDATE 락을 잡은** 트랜잭션 ID |
| `infomask` | 비트 플래그 — 락 모드(shared/exclusive), 트랜잭션 상태 등 |
| `t_ctid` | 튜플의 현재 위치 (page, offset) |

**핵심**: `SELECT FOR UPDATE`를 실행하면 해당 행의 `xmax`에 현재 트랜잭션 ID가 기록되고, `infomask`에 "이것은 DELETE가 아니라 락이다"라는 비트가 설정됩니다.

```
┌─ Heap Page ─────────────────────────────┐
│  Tuple Header                           │
│  ┌─────────────────────────────────────┐│
│  │ xmin = 100  (INSERT한 TX)          ││
│  │ xmax = 205  (FOR UPDATE 잡은 TX)   ││
│  │ infomask = HEAP_XMAX_KEYSHR_LOCK   ││
│  │ ...                                ││
│  └─────────────────────────────────────┘│
│  Tuple Data: (1, 'Alice', 10000.00)     │
└─────────────────────────────────────────┘
```

---

## Lab 1: 기본 동작 — xmax에 락이 기록되는 것 확인

### Step 1: 락 걸기 전 상태 확인

**TX-A:**

```sql
-- 현재 튜플 헤더 상태 확인
SELECT ctid, xmin, xmax, id, owner, balance
FROM accounts;
```

```
 ctid  | xmin | xmax | id |  owner  |  balance
-------+------+------+----+---------+----------
 (0,1) |  741 |    0 | 1  | Alice   | 10000.00
 (0,2) |  741 |    0 | 2  | Bob     |  5000.00
 (0,3) |  741 |    0 | 3  | Charlie |  3000.00
```

> `xmax = 0`은 아무도 이 행에 락을 잡지 않았다는 뜻입니다.

### Step 2: SELECT FOR UPDATE 실행

**TX-A:**

```sql
BEGIN;
SELECT txid_current();  -- 현재 트랜잭션 ID 기억 (예: 742)

SELECT * FROM accounts WHERE id = 1 FOR UPDATE;
```

### Step 3: xmax 변화 관찰

**TX-B (또는 Monitor):**

```sql
-- 다른 세션에서 xmax 확인
SELECT ctid, xmin, xmax, id, owner, balance
FROM accounts;
```

```
 ctid  | xmin | xmax | id |  owner  |  balance
-------+------+------+----+---------+----------
 (0,1) |  741 |  742 | 1  | Alice   | 10000.00  ← xmax에 TX-A의 ID가 기록됨!
 (0,2) |  741 |    0 | 2  | Bob     |  5000.00
 (0,3) |  741 |    0 | 3  | Charlie |  3000.00
```

> **핵심 발견**: `SELECT FOR UPDATE`는 디스크(힙 페이지)에 있는 튜플의 `xmax`를 실제로 수정합니다. 이것이 "in-place" 락의 핵심입니다.

### Step 4: infomask 비트 플래그 확인 (pageinspect 확장)

**Monitor:**

```sql
CREATE EXTENSION IF NOT EXISTS pageinspect;

SELECT t_xmin, t_xmax, t_ctid,
       t_infomask::bit(16) AS infomask_bits,
       CASE
         WHEN (t_infomask & 128) > 0 THEN 'XMAX_IS_LOCK (not delete)'
         ELSE 'XMAX_IS_DELETE_OR_NONE'
       END AS lock_flag
FROM heap_page_items(get_raw_page('accounts', 0))
WHERE t_data IS NOT NULL;
```

> `infomask`의 비트 128 (`HEAP_XMAX_LOCK_ONLY`)이 설정되어 있으면, xmax는 DELETE가 아니라 FOR UPDATE 락을 의미합니다.

### Step 5: 정리

**TX-A:**

```sql
COMMIT;
```

**확인:**

```sql
SELECT ctid, xmin, xmax, id, owner FROM accounts WHERE id = 1;
-- COMMIT 후에도 xmax = 742로 남아 있을 수 있지만, 
-- infomask에 "committed" 비트가 설정되어 PostgreSQL은 이를 무시합니다.
```

---

## Lab 2: Blocking 동작 — 두 번째 트랜잭션이 대기하는 과정

### Step 1: TX-A가 락을 잡음

**TX-A:**

```sql
BEGIN;
SELECT * FROM accounts WHERE id = 1 FOR UPDATE;
-- Alice 행에 exclusive row lock 획득
```

### Step 2: TX-B가 같은 행에 접근 시도

**TX-B:**

```sql
BEGIN;
SELECT * FROM accounts WHERE id = 1 FOR UPDATE;
-- ⏳ 여기서 블로킹됨! TX-A가 COMMIT/ROLLBACK할 때까지 대기
```

### Step 3: 블로킹 상태 모니터링

**Monitor:**

```sql
-- 누가 누구를 블로킹하는지 확인
SELECT
    blocked.pid AS blocked_pid,
    blocked.query AS blocked_query,
    blocking.pid AS blocking_pid,
    blocking.query AS blocking_query
FROM pg_stat_activity blocked
JOIN pg_locks bl ON blocked.pid = bl.pid AND NOT bl.granted
JOIN pg_locks kl ON bl.locktype = kl.locktype
    AND bl.database IS NOT DISTINCT FROM kl.database
    AND bl.relation IS NOT DISTINCT FROM kl.relation
    AND bl.page IS NOT DISTINCT FROM kl.page
    AND bl.tuple IS NOT DISTINCT FROM kl.tuple
    AND bl.transactionid IS NOT DISTINCT FROM kl.transactionid
    AND bl.pid != kl.pid
    AND kl.granted
JOIN pg_stat_activity blocking ON kl.pid = blocking.pid
WHERE blocked.state = 'active';
```

```
 blocked_pid |          blocked_query           | blocking_pid |          blocking_query
-------------+----------------------------------+--------------+----------------------------------
         156 | SELECT * FROM accounts WHERE ... |          148 | SELECT * FROM accounts WHERE ...
```

### Step 4: 락 해제

**TX-A:**

```sql
UPDATE accounts SET balance = balance - 500 WHERE id = 1;
COMMIT;
```

> TX-A가 COMMIT하는 순간, TX-B의 `SELECT FOR UPDATE`가 즉시 실행됩니다.
> **중요**: TX-B는 TX-A의 UPDATE 결과(`balance = 9500`)를 읽습니다.

**TX-B:**

```sql
-- 이제 결과가 반환됨
-- balance = 9500.00 (TX-A의 변경이 반영된 최신 값)

COMMIT;
```

---

## Lab 3: 내부 락 메커니즘 — pg_locks로 깊이 파기

### Step 1: 락 상세 분석

**TX-A:**

```sql
BEGIN;
SELECT * FROM accounts WHERE id = 1 FOR UPDATE;
```

**Monitor:**

```sql
-- TX-A가 잡고 있는 모든 락 조회
SELECT
    l.locktype,
    l.relation::regclass,
    l.page,
    l.tuple,
    l.transactionid,
    l.mode,
    l.granted
FROM pg_locks l
JOIN pg_stat_activity a ON l.pid = a.pid
WHERE a.pid = (SELECT pid FROM pg_stat_activity WHERE query LIKE '%FOR UPDATE%' AND state != 'idle' LIMIT 1);
```

예상 결과:

```
   locktype    | relation | page | tuple | transactionid |       mode       | granted
---------------+----------+------+-------+---------------+------------------+---------
 relation      | accounts |      |       |               | RowShareLock     | t        ← 테이블 레벨
 transactionid |          |      |       |           742 | ExclusiveLock    | t        ← 자기 TX ID
```

> **설명:**
> - `RowShareLock`: 테이블 수준의 의향 락 (intention lock). DDL(DROP TABLE 등)과 충돌 방지용
> - `ExclusiveLock on transactionid`: 자신의 트랜잭션 ID에 대한 락
> - 행 자체의 락은 **pg_locks에 나타나지 않습니다** — 힙 튜플 헤더에만 존재!

### Step 2: 대기 시 tuple lock 등장

**TX-B:**

```sql
BEGIN;
SELECT * FROM accounts WHERE id = 1 FOR UPDATE;
-- 블로킹됨
```

**Monitor:**

```sql
SELECT
    l.locktype,
    l.relation::regclass,
    l.page,
    l.tuple,
    l.transactionid,
    l.mode,
    l.granted,
    a.pid,
    a.state
FROM pg_locks l
JOIN pg_stat_activity a ON l.pid = a.pid
WHERE a.datname = 'lock_lab'
  AND l.locktype IN ('tuple', 'transactionid', 'relation')
ORDER BY a.pid, l.locktype;
```

TX-B에 대해 다음이 보일 수 있습니다:

```
   locktype    | relation | page | tuple | transactionid |       mode        | granted | pid | state
---------------+----------+------+-------+---------------+-------------------+---------+-----+--------
 tuple         | accounts |    0 |     1 |               | ExclusiveLock     | t       | 156 | active
 transactionid |          |      |       |           742 | ShareLock         | f       | 156 | active
```

> **핵심 발견:**
> - `tuple lock (granted=t)`: TX-B는 튜플(0,1)의 "대기열 순서" 락을 잡음
> - `transactionid 742 ShareLock (granted=f)`: TX-A(742)의 트랜잭션이 끝나기를 대기 중!

**TX-A:**

```sql
COMMIT;
-- TX-B가 해제됨
```

**TX-B:**

```sql
COMMIT;
```

---

## Lab 4: 실전 패턴 — 계좌 이체 (Lost Update 방지)

### 문제 상황: FOR UPDATE 없이

두 트랜잭션이 동시에 Alice 잔액을 읽고 각각 차감하면 Lost Update 발생.

**TX-A (FOR UPDATE 없음):**

```sql
BEGIN;
SELECT balance FROM accounts WHERE id = 1;
-- balance = 10000 (이 시점의 값을 읽음)
```

**TX-B (FOR UPDATE 없음):**

```sql
BEGIN;
SELECT balance FROM accounts WHERE id = 1;
-- balance = 10000 (같은 값!)
```

**TX-A:**

```sql
UPDATE accounts SET balance = 10000 - 3000 WHERE id = 1;
COMMIT;
-- balance = 7000
```

**TX-B:**

```sql
UPDATE accounts SET balance = 10000 - 2000 WHERE id = 1;
COMMIT;
-- balance = 8000 ← 3000원 차감이 사라짐! (Lost Update)
```

### 해결: FOR UPDATE 사용

먼저 잔액을 리셋합니다:

```sql
UPDATE accounts SET balance = 10000 WHERE id = 1;
```

**TX-A:**

```sql
BEGIN;
SELECT balance FROM accounts WHERE id = 1 FOR UPDATE;
-- balance = 10000, 락 획득
```

**TX-B:**

```sql
BEGIN;
SELECT balance FROM accounts WHERE id = 1 FOR UPDATE;
-- ⏳ TX-A 완료까지 대기
```

**TX-A:**

```sql
UPDATE accounts SET balance = 10000 - 3000 WHERE id = 1;
COMMIT;
-- balance = 7000
```

**TX-B (이제 실행됨):**

```sql
-- balance = 7000 (TX-A의 결과를 읽음!)
UPDATE accounts SET balance = 7000 - 2000 WHERE id = 1;
COMMIT;
-- balance = 5000 ✅ 정확!
```

---

## Lab 5: FOR UPDATE의 변형들 비교

### 준비

```sql
-- 데이터 리셋
UPDATE accounts SET balance = 10000 WHERE id = 1;
UPDATE accounts SET balance = 5000 WHERE id = 2;
```

### 5-1. FOR UPDATE vs FOR SHARE

| 모드 | 의미 | 동시성 |
|------|------|--------|
| `FOR UPDATE` | Exclusive row lock | 다른 FOR UPDATE/UPDATE/DELETE 블로킹 |
| `FOR SHARE` | Shared row lock | 다른 FOR SHARE 허용, UPDATE/DELETE 블로킹 |
| `FOR NO KEY UPDATE` | UPDATE는 하되 FK 참조 행은 블로킹 안 함 | |
| `FOR KEY SHARE` | FK 무결성 확인용 최소 락 | |

**TX-A:**

```sql
BEGIN;
SELECT * FROM accounts WHERE id = 1 FOR SHARE;
-- shared lock 획득
```

**TX-B:**

```sql
BEGIN;
SELECT * FROM accounts WHERE id = 1 FOR SHARE;
-- ✅ 성공! (shared끼리는 호환)
```

**TX-B (계속):**

```sql
UPDATE accounts SET balance = 9999 WHERE id = 1;
-- ⏳ 블로킹! (shared lock이 걸려있으면 UPDATE 불가)
```

**TX-A, TX-B 둘 다:**

```sql
ROLLBACK;
```

### 5-2. FOR UPDATE NOWAIT

```sql
BEGIN;
-- TX-A: 락 잡기
SELECT * FROM accounts WHERE id = 1 FOR UPDATE;
```

```sql
-- TX-B: 대기 대신 즉시 에러
BEGIN;
SELECT * FROM accounts WHERE id = 1 FOR UPDATE NOWAIT;
-- ERROR: could not obtain lock on row in relation "accounts"
ROLLBACK;
```

### 5-3. FOR UPDATE SKIP LOCKED

대기 대신 락이 걸린 행을 건너뛰는 패턴 — **작업 큐(Job Queue)** 구현에 필수!

```sql
-- 주문 데이터 넣기
INSERT INTO orders (account_id, amount, status) VALUES
    (1, 100, 'pending'),
    (2, 200, 'pending'),
    (3, 300, 'pending');
```

**Worker-A:**

```sql
BEGIN;
SELECT * FROM orders
WHERE status = 'pending'
ORDER BY id
LIMIT 1
FOR UPDATE SKIP LOCKED;
-- id=1 을 가져감
```

**Worker-B:**

```sql
BEGIN;
SELECT * FROM orders
WHERE status = 'pending'
ORDER BY id
LIMIT 1
FOR UPDATE SKIP LOCKED;
-- id=1은 건너뛰고 id=2 를 가져감!
```

**Worker-C:**

```sql
BEGIN;
SELECT * FROM orders
WHERE status = 'pending'
ORDER BY id
LIMIT 1
FOR UPDATE SKIP LOCKED;
-- id=3 을 가져감
```

> **이 패턴이 중요한 이유**: 별도의 메시지 큐(Redis, Kafka) 없이도 PostgreSQL만으로 안전한 작업 분배가 가능합니다.

각 워커:

```sql
UPDATE orders SET status = 'processing' WHERE id = <가져온 id>;
COMMIT;
```

---

## Lab 6: Deadlock 발생과 감지

### Step 1: 교차 락으로 데드락 유발

**TX-A:**

```sql
BEGIN;
SELECT * FROM accounts WHERE id = 1 FOR UPDATE;
-- Alice 락 획득
```

**TX-B:**

```sql
BEGIN;
SELECT * FROM accounts WHERE id = 2 FOR UPDATE;
-- Bob 락 획득
```

**TX-A:**

```sql
SELECT * FROM accounts WHERE id = 2 FOR UPDATE;
-- ⏳ TX-B가 Bob 락을 잡고 있으므로 대기
```

**TX-B:**

```sql
SELECT * FROM accounts WHERE id = 1 FOR UPDATE;
-- 💀 DEADLOCK!
-- ERROR: deadlock detected
-- DETAIL: Process 156 waits for ShareLock on transaction 742;
--         blocked by process 148.
--         Process 148 waits for ShareLock on transaction 743;
--         blocked by process 156.
```

> PostgreSQL은 `deadlock_timeout`(우리 설정: 1초) 후에 데드락을 감지하고 하나의 트랜잭션을 강제 롤백합니다.

### 데드락 방지 패턴

```sql
-- 항상 같은 순서로 락을 잡으면 데드락이 발생하지 않음
BEGIN;
SELECT * FROM accounts WHERE id IN (1, 2) ORDER BY id FOR UPDATE;
-- 두 행을 ID 순서로 한번에 락 → 데드락 불가능
COMMIT;
```

---

## Lab 7: MVCC와의 관계 — Isolation Level별 동작 차이

### READ COMMITTED (기본값)에서의 동작

```sql
UPDATE accounts SET balance = 10000 WHERE id = 1;
```

**TX-A:**

```sql
BEGIN;
UPDATE accounts SET balance = 7000 WHERE id = 1;
-- 아직 COMMIT 안 함
```

**TX-B:**

```sql
BEGIN;
SELECT * FROM accounts WHERE id = 1 FOR UPDATE;
-- ⏳ TX-A 대기... TX-A COMMIT 후 balance=7000 을 읽음
COMMIT;
```

### REPEATABLE READ에서의 동작

```sql
UPDATE accounts SET balance = 10000 WHERE id = 1;
```

**TX-A:**

```sql
BEGIN;
UPDATE accounts SET balance = 7000 WHERE id = 1;
```

**TX-B:**

```sql
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT * FROM accounts WHERE id = 1 FOR UPDATE;
-- ⏳ TX-A 대기...
```

**TX-A:**

```sql
COMMIT;
```

**TX-B:**

```sql
-- ERROR: could not serialize access due to concurrent update
-- REPEATABLE READ에서는 "내 스냅샷 시작 이후 변경된 행"에
-- FOR UPDATE를 시도하면 serialization failure 발생!
ROLLBACK;
```

> **핵심 차이:**
> - `READ COMMITTED`: 대기 후 최신 값을 읽음 (재시도 불필요)
> - `REPEATABLE READ`: 대기 후 serialization error 발생 (애플리케이션에서 재시도 필요)

---

## Lab 8: pageinspect로 내부 저장 구조 직접 관찰

```sql
CREATE EXTENSION IF NOT EXISTS pageinspect;

-- 현재 페이지 0의 모든 튜플 헤더 확인
SELECT
    lp         AS line_pointer,
    lp_off     AS offset,
    t_xmin,
    t_xmax,
    t_ctid,
    t_infomask::bit(16) AS infomask,
    -- 주요 비트 해석
    CASE WHEN (t_infomask & 16)   > 0 THEN 'XMIN_COMMITTED ' ELSE '' END ||
    CASE WHEN (t_infomask & 32)   > 0 THEN 'XMIN_ABORTED '   ELSE '' END ||
    CASE WHEN (t_infomask & 64)   > 0 THEN 'XMAX_COMMITTED ' ELSE '' END ||
    CASE WHEN (t_infomask & 128)  > 0 THEN 'XMAX_LOCK_ONLY ' ELSE '' END ||
    CASE WHEN (t_infomask & 256)  > 0 THEN 'XMAX_IS_MULTI '  ELSE '' END AS flags
FROM heap_page_items(get_raw_page('accounts', 0))
WHERE t_data IS NOT NULL;
```

**FOR UPDATE 전:**

```
 lp | t_xmin | t_xmax | t_ctid | flags
----+--------+--------+--------+----------------------------
  1 |    741 |      0 | (0,1)  | XMIN_COMMITTED
  2 |    741 |      0 | (0,2)  | XMIN_COMMITTED
  3 |    741 |      0 | (0,3)  | XMIN_COMMITTED
```

**FOR UPDATE 실행 후 (다른 세션에서 조회):**

```
 lp | t_xmin | t_xmax | t_ctid | flags
----+--------+--------+--------+-------------------------------------------
  1 |    741 |    742 | (0,1)  | XMIN_COMMITTED XMAX_LOCK_ONLY  ← 핵심!
  2 |    741 |      0 | (0,2)  | XMIN_COMMITTED
  3 |    741 |      0 | (0,3)  | XMIN_COMMITTED
```

> `XMAX_LOCK_ONLY` 플래그가 있으면 PostgreSQL은 `xmax`를 "이 행을 삭제한 TX"가 아니라 "이 행에 락을 잡은 TX"로 해석합니다.

---

## 핵심 정리: 데이터 흐름

```
SELECT * FROM accounts WHERE id = 1 FOR UPDATE;

1. [Executor] → Heap Scan으로 (page=0, tuple=1) 위치를 찾음

2. [Lock Manager] → 튜플 헤더의 xmax 확인
   ├─ xmax = 0 → 아무도 안 잡고 있음 → 3으로
   ├─ xmax = 다른TX, 아직 진행중 → 대기 (pg_locks에 tuple lock + transactionid lock 등록)
   └─ xmax = 다른TX, 이미 종료 → 3으로

3. [Heap] → 튜플 헤더에 직접 기록
   ├─ xmax = 현재 TX ID
   └─ infomask에 HEAP_XMAX_LOCK_ONLY 비트 설정

4. [WAL] → 변경 사항을 WAL(Write-Ahead Log)에 기록
   └─ 이 변경은 crash recovery에도 반영됨

5. [Return] → 결과 행 반환
```

## 정리 & 팁

```bash
# 환경 종료
docker compose down -v
```

### FOR UPDATE 사용 시 주의사항

1. **트랜잭션을 짧게**: 락 보유 시간 = 다른 트랜잭션 대기 시간
2. **일관된 락 순서**: 여러 행을 잡을 때 항상 같은 순서(예: PK ASC)로 잡아 데드락 방지
3. **NOWAIT/SKIP LOCKED 활용**: 대기가 허용 안 되는 상황에서 사용
4. **인덱스 확인**: WHERE 조건이 Index Scan을 타지 않으면 불필요한 행까지 락이 걸릴 수 있음
5. **REPEATABLE READ 주의**: serialization error 처리 로직이 애플리케이션에 필요