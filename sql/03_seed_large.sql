-- ============================================================================
-- Layer 4 — Large seed for benchmarking
--
-- Produces a dataset big enough that the query planner picks non-trivial
-- plans and that index additions produce visible cost changes.
--
--   500 users
--   5 assets, 4 markets (same reference data as the small seed)
--   ~50 000 orders   (30 000 FILLED paired + 20 000 OPEN/CANCELLED noise)
--   ~15 000 trades
--   Timestamps spread over the last 90 days
--
-- Run AFTER 02_schema.sql. This REPLACES the small seed (03_seed.sql).
--
-- Expect ~10-30 seconds to run; the trigger on trades fires once per row.
-- ============================================================================

TRUNCATE trades, orders, balances, withdrawals, deposits,
         markets, assets, users
RESTART IDENTITY CASCADE;

-- Reproducibility: same data on every run
SELECT setseed(0.42);


-- ---------------------------------------------------------------------------
-- Reference data (same as small seed)
-- ---------------------------------------------------------------------------
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


-- ---------------------------------------------------------------------------
-- 500 users
-- ---------------------------------------------------------------------------
INSERT INTO users (user_id, email, username)
SELECT n, 'user' || n || '@ex.com', 'user' || n
FROM generate_series(1, 500) AS n;


-- ---------------------------------------------------------------------------
-- Trade specifications (15 000 pairs).
--   For each spec we will insert two FILLED orders (buy + sell, opposite
--   users, same market, same price) and one trade linking them.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE trade_specs AS
SELECT
    gs,
    1 + (random() * 499)::int AS user_a,                 -- buyer  (taker)
    1 + (random() * 499)::int AS user_b,                 -- seller (maker)
    1 + (random() * 3)::int   AS market_id,
    round((100 + random() * 49900)::numeric, 8) AS price,
    round((0.01 + random() * 5)::numeric, 8)     AS qty,
    NOW() - (random() * 90 || ' days')::interval AS ts
FROM generate_series(1, 15000) gs;

-- Guarantee buyer ≠ seller
UPDATE trade_specs SET user_b = ((user_b) % 500) + 1 WHERE user_a = user_b;


-- ---------------------------------------------------------------------------
-- Insert FILLED orders in pairs with deterministic IDs so we can link trades.
--   Buyers  get odd  IDs (gs*2 - 1)  and are takers
--   Sellers get even IDs (gs*2)      and are makers
-- ---------------------------------------------------------------------------
INSERT INTO orders (order_id, user_id, market_id, side, price, quantity,
                    filled_quantity, status, created_at)
SELECT gs*2 - 1, user_a, market_id, 'BUY',
       price, qty, qty, 'FILLED', ts
FROM trade_specs;

INSERT INTO orders (order_id, user_id, market_id, side, price, quantity,
                    filled_quantity, status, created_at)
SELECT gs*2,     user_b, market_id, 'SELL',
       price, qty, qty, 'FILLED', ts - '1 minute'::interval
FROM trade_specs;


-- ---------------------------------------------------------------------------
-- Trades
-- ---------------------------------------------------------------------------
INSERT INTO trades (maker_order_id, taker_order_id, price, quantity, executed_at)
SELECT gs*2, gs*2 - 1, price, qty, ts
FROM trade_specs;


-- ---------------------------------------------------------------------------
-- Noise orders: 20 000 OPEN or CANCELLED orders, no trades attached.
--   ~80% OPEN, ~20% CANCELLED. IDs start at 30 001 to avoid colliding.
-- ---------------------------------------------------------------------------
INSERT INTO orders (order_id, user_id, market_id, side, price, quantity,
                    filled_quantity, status, created_at)
SELECT
    30000 + gs,
    1 + (random() * 499)::int,
    1 + (random() * 3)::int,
    CASE WHEN random() < 0.5 THEN 'BUY' ELSE 'SELL' END,
    round((100 + random() * 49900)::numeric, 8),
    round((0.01 + random() * 5)::numeric, 8),
    0,
    CASE WHEN random() < 0.2 THEN 'CANCELLED' ELSE 'OPEN' END,
    NOW() - (random() * 90 || ' days')::interval
FROM generate_series(1, 20000) gs;


-- ---------------------------------------------------------------------------
-- Balances: USD for all, BTC/ETH for ~70% each
-- ---------------------------------------------------------------------------
INSERT INTO balances (user_id, asset_id, available_amount, locked_amount)
SELECT user_id, 1, round((10000 + random() * 90000)::numeric, 2), 0
FROM users;

INSERT INTO balances (user_id, asset_id, available_amount, locked_amount)
SELECT user_id, 3, round((0.1 + random() * 10)::numeric, 8), 0
FROM users WHERE random() < 0.7;

INSERT INTO balances (user_id, asset_id, available_amount, locked_amount)
SELECT user_id, 4, round((1 + random() * 100)::numeric, 8), 0
FROM users WHERE random() < 0.7;


-- ---------------------------------------------------------------------------
-- Deposits: one per balance row
-- ---------------------------------------------------------------------------
INSERT INTO deposits (user_id, asset_id, amount, status, created_at)
SELECT user_id, asset_id, available_amount, 'COMPLETED',
       NOW() - (random() * 180 || ' days')::interval
FROM balances;


-- ---------------------------------------------------------------------------
-- Reset sequences
-- ---------------------------------------------------------------------------
SELECT setval(pg_get_serial_sequence('users',    'user_id'),    (SELECT MAX(user_id)    FROM users));
SELECT setval(pg_get_serial_sequence('assets',   'asset_id'),   (SELECT MAX(asset_id)   FROM assets));
SELECT setval(pg_get_serial_sequence('markets',  'market_id'),  (SELECT MAX(market_id)  FROM markets));
SELECT setval(pg_get_serial_sequence('orders',   'order_id'),   (SELECT MAX(order_id)   FROM orders));
SELECT setval(pg_get_serial_sequence('trades',   'trade_id'),   (SELECT MAX(trade_id)   FROM trades));
SELECT setval(pg_get_serial_sequence('deposits', 'deposit_id'), (SELECT MAX(deposit_id) FROM deposits));


-- ---------------------------------------------------------------------------
-- IMPORTANT: refresh planner statistics before benchmarking
-- ---------------------------------------------------------------------------
ANALYZE;


-- ---------------------------------------------------------------------------
-- Row counts (expected shape)
-- ---------------------------------------------------------------------------
--   users     500
--   orders  50000
--   trades  15000
--   balances  ~1700
--   deposits  ~1700
SELECT 'users'     AS tbl, COUNT(*) FROM users
UNION ALL SELECT 'orders',    COUNT(*) FROM orders
UNION ALL SELECT 'trades',    COUNT(*) FROM trades
UNION ALL SELECT 'balances',  COUNT(*) FROM balances
UNION ALL SELECT 'deposits',  COUNT(*) FROM deposits;
