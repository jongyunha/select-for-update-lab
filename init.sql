-- ============================================
-- SELECT FOR UPDATE 실습용 초기 데이터
-- ============================================

CREATE TABLE accounts (
    id          SERIAL PRIMARY KEY,
    owner       VARCHAR(50) NOT NULL,
    balance     NUMERIC(12,2) NOT NULL DEFAULT 0,
    version     INT NOT NULL DEFAULT 1,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE orders (
    id          SERIAL PRIMARY KEY,
    account_id  INT REFERENCES accounts(id),
    amount      NUMERIC(12,2) NOT NULL,
    status      VARCHAR(20) NOT NULL DEFAULT 'pending',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE inventory (
    id          SERIAL PRIMARY KEY,
    product     VARCHAR(100) NOT NULL,
    stock       INT NOT NULL DEFAULT 0
);

-- 테스트 데이터
INSERT INTO accounts (owner, balance) VALUES
    ('Alice', 10000.00),
    ('Bob',    5000.00),
    ('Charlie', 3000.00);

INSERT INTO inventory (product, stock) VALUES
    ('Widget-A', 10),
    ('Widget-B', 5),
    ('Widget-C', 1);

-- 락 모니터링용 뷰
CREATE VIEW lock_monitor AS
SELECT
    l.pid,
    a.usename,
    l.locktype,
    l.relation::regclass AS table_name,
    l.page,
    l.tuple,
    l.mode,
    l.granted,
    a.query,
    a.state,
    age(now(), a.query_start) AS query_age
FROM pg_locks l
JOIN pg_stat_activity a ON l.pid = a.pid
WHERE a.datname = 'lock_lab'
  AND l.locktype = 'tuple'
   OR (l.locktype = 'relation' AND l.mode LIKE '%RowExclusive%')
   OR (l.locktype = 'transactionid')
ORDER BY l.pid;

-- 간단한 락 상태 확인 뷰
CREATE VIEW active_locks AS
SELECT
    a.pid,
    a.usename,
    a.state,
    a.wait_event_type,
    a.wait_event,
    substring(a.query, 1, 80) AS query_snippet,
    l.locktype,
    l.mode,
    l.granted
FROM pg_stat_activity a
LEFT JOIN pg_locks l ON a.pid = l.pid
WHERE a.datname = 'lock_lab'
  AND a.pid != pg_backend_pid()
  AND a.state != 'idle'
ORDER BY a.pid, l.locktype;