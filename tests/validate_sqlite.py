"""
Test harness: adapt the PostgreSQL DDL/DML to SQLite and verify that
  1. the small seed loads without violating any PK/FK/UNIQUE/CHECK
  2. every query from 04_queries.md returns the expected output
  3. the trade validation invariant (maker != taker, same market, opposite
     sides) is enforced (we'll re-implement it as a SQLite trigger so we can
     at least test the logic)

What this CANNOT check:
  * PostgreSQL-specific PL/pgSQL (we re-implement the trigger natively)
  * Large-seed generation (uses generate_series / random / setseed)
  * EXPLAIN ANALYZE plans (SQLite's planner is different)
  * FOR UPDATE locking semantics
"""
import sqlite3
import sys
import textwrap
from decimal import Decimal
from pathlib import Path

# ----------------------------------------------------------------------------
# SQLite-adapted schema  (mirrors /mnt/user-data/outputs/02_schema.sql)
# ----------------------------------------------------------------------------
SCHEMA_SQL = """
PRAGMA foreign_keys = ON;

CREATE TABLE users (
    user_id     INTEGER PRIMARY KEY AUTOINCREMENT,
    email       TEXT NOT NULL UNIQUE,
    username    TEXT NOT NULL UNIQUE,
    status      TEXT NOT NULL DEFAULT 'ACTIVE'
                  CHECK (status IN ('ACTIVE', 'SUSPENDED', 'CLOSED')),
    created_at  TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE assets (
    asset_id    INTEGER PRIMARY KEY AUTOINCREMENT,
    symbol      TEXT NOT NULL UNIQUE,
    name        TEXT NOT NULL,
    asset_type  TEXT NOT NULL CHECK (asset_type IN ('FIAT', 'CRYPTO')),
    precision   INTEGER NOT NULL CHECK (precision BETWEEN 0 AND 18)
);

CREATE TABLE markets (
    market_id       INTEGER PRIMARY KEY AUTOINCREMENT,
    base_asset_id   INTEGER NOT NULL REFERENCES assets(asset_id),
    quote_asset_id  INTEGER NOT NULL REFERENCES assets(asset_id),
    min_order_qty   NUMERIC NOT NULL CHECK (min_order_qty > 0),
    status          TEXT NOT NULL DEFAULT 'ACTIVE'
                      CHECK (status IN ('ACTIVE', 'HALTED', 'CLOSED')),
    UNIQUE (base_asset_id, quote_asset_id),
    CHECK  (base_asset_id <> quote_asset_id)
);

CREATE TABLE balances (
    user_id           INTEGER NOT NULL REFERENCES users(user_id),
    asset_id          INTEGER NOT NULL REFERENCES assets(asset_id),
    available_amount  NUMERIC NOT NULL DEFAULT 0 CHECK (available_amount >= 0),
    locked_amount     NUMERIC NOT NULL DEFAULT 0 CHECK (locked_amount >= 0),
    PRIMARY KEY (user_id, asset_id)
);

CREATE TABLE orders (
    order_id         INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id          INTEGER NOT NULL REFERENCES users(user_id),
    market_id        INTEGER NOT NULL REFERENCES markets(market_id),
    side             TEXT NOT NULL CHECK (side IN ('BUY', 'SELL')),
    order_type       TEXT NOT NULL DEFAULT 'LIMIT'
                       CHECK (order_type IN ('LIMIT')),
    price            NUMERIC NOT NULL CHECK (price > 0),
    quantity         NUMERIC NOT NULL CHECK (quantity > 0),
    filled_quantity  NUMERIC NOT NULL DEFAULT 0
                       CHECK (filled_quantity >= 0),
    status           TEXT NOT NULL DEFAULT 'OPEN'
                       CHECK (status IN ('OPEN','PARTIAL','FILLED','CANCELLED')),
    created_at       TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CHECK (filled_quantity <= quantity),
    CHECK (
        status = 'CANCELLED'
        OR (status = 'OPEN'    AND filled_quantity = 0)
        OR (status = 'PARTIAL' AND filled_quantity > 0
                               AND filled_quantity < quantity)
        OR (status = 'FILLED'  AND filled_quantity = quantity)
    )
);

CREATE TABLE trades (
    trade_id        INTEGER PRIMARY KEY AUTOINCREMENT,
    maker_order_id  INTEGER NOT NULL REFERENCES orders(order_id),
    taker_order_id  INTEGER NOT NULL REFERENCES orders(order_id),
    price           NUMERIC NOT NULL CHECK (price > 0),
    quantity        NUMERIC NOT NULL CHECK (quantity > 0),
    executed_at     TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CHECK (maker_order_id <> taker_order_id)
);

-- Re-implementation of the PL/pgSQL trg_validate_trade as a SQLite trigger
-- (logic is identical: same market, opposite sides).
CREATE TRIGGER trades_validate_biz_ins
BEFORE INSERT ON trades
FOR EACH ROW
BEGIN
    SELECT
        CASE
            WHEN (SELECT market_id FROM orders WHERE order_id = NEW.maker_order_id)
              != (SELECT market_id FROM orders WHERE order_id = NEW.taker_order_id)
            THEN RAISE(ABORT, 'trade rejected: different markets')
            WHEN (SELECT side FROM orders WHERE order_id = NEW.maker_order_id)
              =  (SELECT side FROM orders WHERE order_id = NEW.taker_order_id)
            THEN RAISE(ABORT, 'trade rejected: same side')
        END;
END;

CREATE TABLE deposits (
    deposit_id  INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id     INTEGER NOT NULL REFERENCES users(user_id),
    asset_id    INTEGER NOT NULL REFERENCES assets(asset_id),
    amount      NUMERIC NOT NULL CHECK (amount > 0),
    status      TEXT NOT NULL DEFAULT 'PENDING'
                  CHECK (status IN ('PENDING', 'COMPLETED', 'FAILED')),
    created_at  TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE withdrawals (
    withdrawal_id  INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id        INTEGER NOT NULL REFERENCES users(user_id),
    asset_id       INTEGER NOT NULL REFERENCES assets(asset_id),
    amount         NUMERIC NOT NULL CHECK (amount > 0),
    status         TEXT NOT NULL DEFAULT 'PENDING'
                     CHECK (status IN ('PENDING', 'COMPLETED', 'REJECTED')),
    created_at     TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
"""

# ----------------------------------------------------------------------------
# SQLite-adapted seed  (mirrors /mnt/user-data/outputs/03_seed.sql,
# but uses explicit INSERTs that SQLite understands — the Postgres version
# uses multi-row VALUES + sequence reset, which we don't need here)
# ----------------------------------------------------------------------------
SEED_SQL = """
INSERT INTO users (user_id, email, username) VALUES
    (1, 'alice@example.com', 'alice'),
    (2, 'bob@example.com',   'bob'),
    (3, 'carol@example.com', 'carol'),
    (4, 'dave@example.com',  'dave'),
    (5, 'eve@example.com',   'eve');

INSERT INTO assets (asset_id, symbol, name, asset_type, precision) VALUES
    (1, 'USD', 'US Dollar', 'FIAT',   2),
    (2, 'EUR', 'Euro',      'FIAT',   2),
    (3, 'BTC', 'Bitcoin',   'CRYPTO', 8),
    (4, 'ETH', 'Ethereum',  'CRYPTO', 8),
    (5, 'SOL', 'Solana',    'CRYPTO', 8);

INSERT INTO markets (market_id, base_asset_id, quote_asset_id, min_order_qty) VALUES
    (1, 3, 1, 0.00010000),
    (2, 4, 1, 0.00100000),
    (3, 5, 1, 0.01000000),
    (4, 4, 3, 0.00100000);

INSERT INTO deposits (deposit_id, user_id, asset_id, amount, status) VALUES
    (1, 1, 1,  50000.00000000, 'COMPLETED'),
    (2, 1, 3,      1.50000000, 'COMPLETED'),
    (3, 2, 1,  30000.00000000, 'COMPLETED'),
    (4, 2, 4,     10.00000000, 'COMPLETED'),
    (5, 3, 1, 100000.00000000, 'COMPLETED'),
    (6, 4, 3,      0.80000000, 'COMPLETED'),
    (7, 5, 1,  20000.00000000, 'COMPLETED'),
    (8, 5, 4,      5.00000000, 'COMPLETED'),
    (9, 4, 1,   5000.00000000, 'PENDING');

INSERT INTO withdrawals (withdrawal_id, user_id, asset_id, amount, status) VALUES
    (1, 3, 1, 1000.00000000, 'COMPLETED'),
    (2, 1, 3,    0.10000000, 'PENDING');

INSERT INTO orders
    (order_id, user_id, market_id, side, price, quantity, filled_quantity, status)
VALUES
    (1, 1, 1, 'BUY',  40000.00000000, 0.50000000, 0.00000000, 'OPEN'),
    (2, 2, 2, 'SELL',  2500.00000000, 2.00000000, 1.00000000, 'PARTIAL'),
    (3, 3, 2, 'BUY',   2500.00000000, 1.00000000, 1.00000000, 'FILLED'),
    (4, 4, 1, 'SELL', 41000.00000000, 0.30000000, 0.00000000, 'OPEN'),
    (5, 5, 1, 'BUY',  39500.00000000, 0.20000000, 0.00000000, 'OPEN');

INSERT INTO trades (trade_id, maker_order_id, taker_order_id, price, quantity) VALUES
    (1, 2, 3, 2500.00000000, 1.00000000);

INSERT INTO balances (user_id, asset_id, available_amount, locked_amount) VALUES
    (1, 1, 30000.00000000, 20000.00000000),
    (1, 3,     1.50000000,     0.00000000),
    (2, 1, 32500.00000000,     0.00000000),
    (2, 4,     8.00000000,     1.00000000),
    (3, 1, 96500.00000000,     0.00000000),
    (3, 4,     1.00000000,     0.00000000),
    (4, 3,     0.50000000,     0.30000000),
    (5, 1, 12100.00000000,  7900.00000000),
    (5, 4,     5.00000000,     0.00000000);
"""

# ----------------------------------------------------------------------------
# Queries from 04_queries.md, with Postgres-only syntax adapted for SQLite.
# Each entry has a function that returns (rows, columns) for easy comparison.
# ----------------------------------------------------------------------------

QUERIES = {}
EXPECTED = {}

# Q1
QUERIES["Q1"] = """
SELECT m.market_id, b.symbol AS base_symbol, q.symbol AS quote_symbol,
       m.min_order_qty
FROM   markets m
JOIN   assets b ON b.asset_id = m.base_asset_id
JOIN   assets q ON q.asset_id = m.quote_asset_id
WHERE  m.status = 'ACTIVE'
ORDER  BY m.market_id;
"""
EXPECTED["Q1"] = [
    (1, "BTC", "USD", 0.0001),
    (2, "ETH", "USD", 0.001),
    (3, "SOL", "USD", 0.01),
    (4, "ETH", "BTC", 0.001),
]

# Q2
QUERIES["Q2"] = """
SELECT a.symbol, bal.available_amount, bal.locked_amount,
       bal.available_amount + bal.locked_amount AS total
FROM   users u
JOIN   balances bal ON bal.user_id  = u.user_id
JOIN   assets   a   ON a.asset_id   = bal.asset_id
WHERE  u.username = 'alice'
ORDER  BY a.symbol;
"""
EXPECTED["Q2"] = [
    ("BTC", 1.5, 0.0, 1.5),
    ("USD", 30000.0, 20000.0, 50000.0),
]

# Q3 — order book for BTC/USD (wrapped UNION for portability)
QUERIES["Q3"] = """
SELECT label, order_id, price, remaining
FROM (
    SELECT 'ASKS' AS label, o.order_id, o.price,
           o.quantity - o.filled_quantity AS remaining
    FROM   orders o
    JOIN   markets m ON m.market_id = o.market_id
    JOIN   assets  b ON b.asset_id  = m.base_asset_id
    JOIN   assets  q ON q.asset_id  = m.quote_asset_id
    WHERE  b.symbol = 'BTC' AND q.symbol = 'USD'
      AND  o.side = 'SELL'
      AND  o.status IN ('OPEN', 'PARTIAL')
    UNION ALL
    SELECT 'BIDS', o.order_id, o.price,
           o.quantity - o.filled_quantity
    FROM   orders o
    JOIN   markets m ON m.market_id = o.market_id
    JOIN   assets  b ON b.asset_id  = m.base_asset_id
    JOIN   assets  q ON q.asset_id  = m.quote_asset_id
    WHERE  b.symbol = 'BTC' AND q.symbol = 'USD'
      AND  o.side = 'BUY'
      AND  o.status IN ('OPEN', 'PARTIAL')
) AS book
ORDER BY label,
         CASE WHEN label = 'ASKS' THEN  price ELSE -price END;
"""
EXPECTED["Q3"] = [
    ("ASKS", 4, 41000.0, 0.3),
    ("BIDS", 1, 40000.0, 0.5),
    ("BIDS", 5, 39500.0, 0.2),
]

# Q4 — Carol's trades with role
QUERIES["Q4"] = """
SELECT t.trade_id, 'MAKER' AS role, t.price, t.quantity
FROM   trades t
JOIN   orders o ON o.order_id = t.maker_order_id
JOIN   users  u ON u.user_id  = o.user_id
WHERE  u.username = 'carol'
UNION ALL
SELECT t.trade_id, 'TAKER', t.price, t.quantity
FROM   trades t
JOIN   orders o ON o.order_id = t.taker_order_id
JOIN   users  u ON u.user_id  = o.user_id
WHERE  u.username = 'carol'
ORDER  BY t.trade_id;
"""
EXPECTED["Q4"] = [
    (1, "TAKER", 2500.0, 1.0),
]

# Q5 — volume per market
QUERIES["Q5"] = """
SELECT m.market_id, b.symbol AS base_symbol, q.symbol AS quote_symbol,
       SUM(t.quantity) AS total_qty, COUNT(*) AS n_trades
FROM   trades t
JOIN   orders o ON o.order_id  = t.maker_order_id
JOIN   markets m ON m.market_id = o.market_id
JOIN   assets b ON b.asset_id = m.base_asset_id
JOIN   assets q ON q.asset_id = m.quote_asset_id
GROUP  BY m.market_id, b.symbol, q.symbol
ORDER  BY m.market_id;
"""
EXPECTED["Q5"] = [
    (2, "ETH", "USD", 1.0, 1),
]

# Q6 — VWAP
QUERIES["Q6"] = """
SELECT m.market_id,
       b.symbol || '/' || q.symbol AS symbol,
       SUM(t.price * t.quantity) / SUM(t.quantity) AS vwap,
       SUM(t.quantity) AS total_qty,
       COUNT(*)        AS n_trades
FROM   trades  t
JOIN   orders  o ON o.order_id  = t.maker_order_id
JOIN   markets m ON m.market_id = o.market_id
JOIN   assets  b ON b.asset_id  = m.base_asset_id
JOIN   assets  q ON q.asset_id  = m.quote_asset_id
GROUP  BY m.market_id, b.symbol, q.symbol;
"""
EXPECTED["Q6"] = [
    (2, "ETH/USD", 2500.0, 1.0, 1),
]

# Q7 — open orders per user  (SQLite does not support COUNT(…) FILTER WHERE,
# so use the CASE alternative we mentioned in the writeup)
QUERIES["Q7"] = """
SELECT u.username,
       COUNT(CASE WHEN o.status IN ('OPEN','PARTIAL') THEN 1 END) AS open_count
FROM   users u
LEFT   JOIN orders o ON o.user_id = u.user_id
GROUP  BY u.username
ORDER  BY u.username;
"""
EXPECTED["Q7"] = [
    ("alice", 1),
    ("bob", 1),
    ("carol", 0),
    ("dave", 1),
    ("eve", 1),
]

# Q8 — users with orders but no trades
QUERIES["Q8"] = """
SELECT u.username
FROM   users u
WHERE  u.user_id IN (SELECT user_id FROM orders)
  AND  u.user_id NOT IN (
        SELECT o.user_id FROM trades t
            JOIN orders o ON o.order_id = t.maker_order_id
        UNION
        SELECT o.user_id FROM trades t
            JOIN orders o ON o.order_id = t.taker_order_id
       )
ORDER  BY u.username;
"""
EXPECTED["Q8"] = [
    ("alice",),
    ("dave",),
    ("eve",),
]

# Q9 — trading pairs (SQLite supports LEAST/GREATEST as min/max)
QUERIES["Q9"] = """
SELECT MIN(um.username, ut.username) AS user_a,
       MAX(um.username, ut.username) AS user_b,
       COUNT(*)                      AS n_trades
FROM   trades t
JOIN   orders mo ON mo.order_id = t.maker_order_id
JOIN   orders tk ON tk.order_id = t.taker_order_id
JOIN   users  um ON um.user_id  = mo.user_id
JOIN   users  ut ON ut.user_id  = tk.user_id
WHERE  mo.user_id <> tk.user_id
GROUP  BY MIN(um.username, ut.username), MAX(um.username, ut.username);
"""
EXPECTED["Q9"] = [
    ("bob", "carol", 1),
]

# Q10 — top holder per asset
QUERIES["Q10"] = """
SELECT a.symbol, u.username,
       bal.available_amount + bal.locked_amount AS total
FROM   balances bal
JOIN   users    u ON u.user_id  = bal.user_id
JOIN   assets   a ON a.asset_id = bal.asset_id
WHERE  (bal.asset_id, bal.available_amount + bal.locked_amount) IN (
           SELECT asset_id, MAX(available_amount + locked_amount)
           FROM   balances
           GROUP  BY asset_id
       )
ORDER  BY a.symbol;
"""
EXPECTED["Q10"] = [
    ("BTC", "alice", 1.5),
    ("ETH", "bob", 9.0),
    ("USD", "carol", 96500.0),
]

# Q11 — users with orders in every market (division)
QUERIES["Q11"] = """
SELECT u.username
FROM   users u
WHERE  NOT EXISTS (
           SELECT 1 FROM markets m
           WHERE NOT EXISTS (
                     SELECT 1 FROM orders o
                     WHERE o.user_id   = u.user_id
                       AND o.market_id = m.market_id
                 )
       );
"""
EXPECTED["Q11"] = []  # empty — no user has orders in all 4 markets


# ----------------------------------------------------------------------------
# Run harness
# ----------------------------------------------------------------------------

def normalise_row(row):
    """Normalise numeric types so Decimal / float / int compare equal."""
    out = []
    for v in row:
        if isinstance(v, (int, float, Decimal)):
            out.append(float(v))
        else:
            out.append(v)
    return tuple(out)


def run():
    conn = sqlite3.connect(":memory:")
    cur = conn.cursor()

    # ---- Schema ----
    print("=" * 70)
    print("Loading schema (SQLite-adapted)…")
    try:
        cur.executescript(SCHEMA_SQL)
    except Exception as e:
        print(f"SCHEMA LOAD FAILED: {e}")
        return 1
    print("  schema OK")

    # ---- Seed ----
    print("Loading small seed…")
    try:
        cur.executescript(SEED_SQL)
        conn.commit()
    except Exception as e:
        print(f"SEED LOAD FAILED: {e}")
        return 1

    # Sanity checks: row counts
    expected_counts = {
        "users": 5, "assets": 5, "markets": 4,
        "balances": 9, "orders": 5, "trades": 1,
        "deposits": 9, "withdrawals": 2,
    }
    for table, expected in expected_counts.items():
        n = cur.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        status = "OK" if n == expected else f"MISMATCH (expected {expected})"
        print(f"  {table:13}{n:>4}   [{status}]")
        if n != expected:
            return 1

    # ---- Trigger sanity (valid-trade invariant) ----
    print("\nTesting trade validation trigger…")
    # Attempt to insert a bad trade: maker and taker on different markets
    try:
        cur.execute(
            "INSERT INTO trades (maker_order_id, taker_order_id, price, quantity) "
            "VALUES (1, 3, 2500, 1);"   # order 1 is BTC/USD, order 3 is ETH/USD
        )
        print("  FAIL: trigger did not block cross-market trade")
        return 1
    except sqlite3.IntegrityError as e:
        print(f"  cross-market trade rejected OK: {e}")

    try:
        cur.execute(
            "INSERT INTO trades (maker_order_id, taker_order_id, price, quantity) "
            "VALUES (1, 5, 40000, 0.1);"   # both BUY on BTC/USD
        )
        print("  FAIL: trigger did not block same-side trade")
        return 1
    except sqlite3.IntegrityError as e:
        print(f"  same-side trade rejected OK: {e}")
    conn.rollback()

    # ---- Queries ----
    print("\nRunning Q1–Q11…")
    failures = []
    for qid in sorted(QUERIES.keys(), key=lambda s: int(s[1:])):
        sql = QUERIES[qid]
        try:
            rows = cur.execute(sql).fetchall()
        except Exception as e:
            failures.append((qid, f"execution error: {e}"))
            print(f"  {qid}: ERROR — {e}")
            continue

        got = [normalise_row(r) for r in rows]
        want = [normalise_row(r) for r in EXPECTED[qid]]

        if got == want:
            print(f"  {qid}: OK  ({len(got)} rows)")
        else:
            failures.append((qid, "output mismatch"))
            print(f"  {qid}: MISMATCH")
            print("    got:")
            for r in got:
                print(f"      {r}")
            print("    want:")
            for r in want:
                print(f"      {r}")

    print("=" * 70)
    if failures:
        print(f"FAILED: {len(failures)} problems")
        for qid, msg in failures:
            print(f"  {qid}: {msg}")
        return 1
    print("ALL CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(run())
