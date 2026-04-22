-- ============================================================================
-- Exchange Simulator — Seed Data (Layer 2)
--
-- A small, hand-verifiable dataset:
--   5 users, 5 assets, 4 markets, 5 orders, 1 trade,
--   9 deposits (8 completed + 1 pending), 2 withdrawals.
--
-- Narrative / timeline (used to compute the final balances):
--   t0  deposits processed         -> available balances seeded
--   t1  carol withdraws 1000 USD   (COMPLETED)
--   t2  five orders placed         -> locks move from available to locked
--   t3  one trade executes:
--         bob's  SELL 2 ETH @ 2500 is the maker (rested on the book)
--         carol's BUY  1 ETH @ 2500 is the taker, fully filled
--
-- Run AFTER 02_schema.sql.
-- ============================================================================

-- Clean slate (reverse-dependency order)
TRUNCATE trades, orders, balances, withdrawals, deposits,
         markets, assets, users
RESTART IDENTITY CASCADE;


-- ---------------------------------------------------------------------------
-- USERS
-- ---------------------------------------------------------------------------
INSERT INTO users (user_id, email, username) VALUES
    (1, 'alice@example.com', 'alice'),
    (2, 'bob@example.com',   'bob'),
    (3, 'carol@example.com', 'carol'),
    (4, 'dave@example.com',  'dave'),
    (5, 'eve@example.com',   'eve');


-- ---------------------------------------------------------------------------
-- ASSETS
-- ---------------------------------------------------------------------------
INSERT INTO assets (asset_id, symbol, name, asset_type, precision) VALUES
    (1, 'USD', 'US Dollar', 'FIAT',   2),
    (2, 'EUR', 'Euro',      'FIAT',   2),
    (3, 'BTC', 'Bitcoin',   'CRYPTO', 8),
    (4, 'ETH', 'Ethereum',  'CRYPTO', 8),
    (5, 'SOL', 'Solana',    'CRYPTO', 8);


-- ---------------------------------------------------------------------------
-- MARKETS
-- ---------------------------------------------------------------------------
INSERT INTO markets (market_id, base_asset_id, quote_asset_id, min_order_qty) VALUES
    (1, 3, 1, 0.00010000),  -- BTC/USD
    (2, 4, 1, 0.00100000),  -- ETH/USD
    (3, 5, 1, 0.01000000),  -- SOL/USD
    (4, 4, 3, 0.00100000);  -- ETH/BTC


-- ---------------------------------------------------------------------------
-- DEPOSITS
-- ---------------------------------------------------------------------------
INSERT INTO deposits (deposit_id, user_id, asset_id, amount, status) VALUES
    (1, 1, 1,  50000.00000000, 'COMPLETED'),  -- alice  50 000 USD
    (2, 1, 3,      1.50000000, 'COMPLETED'),  -- alice       1.5 BTC
    (3, 2, 1,  30000.00000000, 'COMPLETED'),  -- bob    30 000 USD
    (4, 2, 4,     10.00000000, 'COMPLETED'),  -- bob         10 ETH
    (5, 3, 1, 100000.00000000, 'COMPLETED'),  -- carol 100 000 USD
    (6, 4, 3,      0.80000000, 'COMPLETED'),  -- dave       0.8 BTC
    (7, 5, 1,  20000.00000000, 'COMPLETED'),  -- eve    20 000 USD
    (8, 5, 4,      5.00000000, 'COMPLETED'),  -- eve          5 ETH
    (9, 4, 1,   5000.00000000, 'PENDING');    -- dave pending 5 000 USD


-- ---------------------------------------------------------------------------
-- WITHDRAWALS
-- ---------------------------------------------------------------------------
INSERT INTO withdrawals (withdrawal_id, user_id, asset_id, amount, status) VALUES
    (1, 3, 1, 1000.00000000, 'COMPLETED'),  -- carol withdraws 1000 USD
    (2, 1, 3,    0.10000000, 'PENDING');    -- alice requests 0.1 BTC out


-- ---------------------------------------------------------------------------
-- ORDERS
-- ---------------------------------------------------------------------------
--  id  user   market    side   price   qty    filled   status
--  1   alice  BTC/USD   BUY    40 000  0.5    0        OPEN
--  2   bob    ETH/USD   SELL    2 500  2.0    1.0      PARTIAL   (maker of trade 1)
--  3   carol  ETH/USD   BUY     2 500  1.0    1.0      FILLED    (taker of trade 1)
--  4   dave   BTC/USD   SELL   41 000  0.3    0        OPEN
--  5   eve    BTC/USD   BUY    39 500  0.2    0        OPEN
-- ---------------------------------------------------------------------------
INSERT INTO orders
    (order_id, user_id, market_id, side, price, quantity, filled_quantity, status)
VALUES
    (1, 1, 1, 'BUY',  40000.00000000, 0.50000000, 0.00000000, 'OPEN'),
    (2, 2, 2, 'SELL',  2500.00000000, 2.00000000, 1.00000000, 'PARTIAL'),
    (3, 3, 2, 'BUY',   2500.00000000, 1.00000000, 1.00000000, 'FILLED'),
    (4, 4, 1, 'SELL', 41000.00000000, 0.30000000, 0.00000000, 'OPEN'),
    (5, 5, 1, 'BUY',  39500.00000000, 0.20000000, 0.00000000, 'OPEN');


-- ---------------------------------------------------------------------------
-- TRADES
--   bob's SELL order (id=2) was resting on the book -> maker
--   carol's BUY order (id=3) came in and matched    -> taker
--   1 ETH exchanged at 2500 USD/ETH = 2500 USD total
-- ---------------------------------------------------------------------------
INSERT INTO trades (trade_id, maker_order_id, taker_order_id, price, quantity) VALUES
    (1, 2, 3, 2500.00000000, 1.00000000);


-- ---------------------------------------------------------------------------
-- BALANCES  (final state after deposits -> withdrawals -> orders -> trade 1)
--
-- Hand-check:
--
-- alice  (user 1)
--   USD  deposited  50 000
--        locked by order 1 (BUY 0.5 BTC @ 40 000 = 20 000 USD reserved)
--        => available = 30 000, locked = 20 000
--   BTC  deposited 1.5, no active lock (withdrawal of 0.1 is PENDING, so
--        policies vary; we keep it simple and do NOT lock on pending)
--        => available = 1.5, locked = 0
--
-- bob    (user 2)
--   USD  deposited 30 000, received 2 500 from trade 1 proceeds
--        => available = 32 500, locked = 0
--   ETH  deposited 10, order 2 locks 2, then 1 ETH was delivered in trade 1
--        => 10 - 1 delivered = 9 total; of which 1 is still locked
--           (the remaining 1 ETH of the partially-filled SELL order)
--        => available = 8, locked = 1
--
-- carol  (user 3)
--   USD  deposited 100 000, withdrew 1 000, spent 2 500 on trade 1
--        order 3 is FILLED so nothing is locked
--        => available = 96 500, locked = 0
--   ETH  received 1 from trade 1
--        => available = 1, locked = 0
--
-- dave   (user 4)
--   BTC  deposited 0.8, order 4 locks 0.3
--        => available = 0.5, locked = 0.3
--   (No USD balance row — pending deposit not yet credited.)
--
-- eve    (user 5)
--   USD  deposited 20 000, order 5 locks (0.2 * 39 500) = 7 900
--        => available = 12 100, locked = 7 900
--   ETH  deposited 5, no active order
--        => available = 5, locked = 0
-- ---------------------------------------------------------------------------
INSERT INTO balances (user_id, asset_id, available_amount, locked_amount) VALUES
    (1, 1, 30000.00000000, 20000.00000000),  -- alice USD
    (1, 3,     1.50000000,     0.00000000),  -- alice BTC
    (2, 1, 32500.00000000,     0.00000000),  -- bob   USD
    (2, 4,     8.00000000,     1.00000000),  -- bob   ETH
    (3, 1, 96500.00000000,     0.00000000),  -- carol USD
    (3, 4,     1.00000000,     0.00000000),  -- carol ETH
    (4, 3,     0.50000000,     0.30000000),  -- dave  BTC
    (5, 1, 12100.00000000,  7900.00000000),  -- eve   USD
    (5, 4,     5.00000000,     0.00000000);  -- eve   ETH


-- ---------------------------------------------------------------------------
-- Sequence reset — because we inserted explicit IDs with GENERATED BY
-- DEFAULT AS IDENTITY, the underlying sequences are NOT automatically
-- advanced. Without this, the next auto-generated ID would collide with 1.
-- ---------------------------------------------------------------------------
SELECT setval(pg_get_serial_sequence('users',       'user_id'),       (SELECT MAX(user_id)       FROM users));
SELECT setval(pg_get_serial_sequence('assets',      'asset_id'),      (SELECT MAX(asset_id)      FROM assets));
SELECT setval(pg_get_serial_sequence('markets',     'market_id'),     (SELECT MAX(market_id)     FROM markets));
SELECT setval(pg_get_serial_sequence('orders',      'order_id'),      (SELECT MAX(order_id)      FROM orders));
SELECT setval(pg_get_serial_sequence('trades',      'trade_id'),      (SELECT MAX(trade_id)      FROM trades));
SELECT setval(pg_get_serial_sequence('deposits',    'deposit_id'),    (SELECT MAX(deposit_id)    FROM deposits));
SELECT setval(pg_get_serial_sequence('withdrawals', 'withdrawal_id'), (SELECT MAX(withdrawal_id) FROM withdrawals));


-- ---------------------------------------------------------------------------
-- Sanity-check summary (expected row counts below)
-- ---------------------------------------------------------------------------
-- users:5 assets:5 markets:4 balances:9 orders:5 trades:1
-- deposits:9 withdrawals:2
SELECT 'users'       AS table_name, COUNT(*) AS rows FROM users UNION ALL
SELECT 'assets',       COUNT(*) FROM assets       UNION ALL
SELECT 'markets',      COUNT(*) FROM markets      UNION ALL
SELECT 'balances',     COUNT(*) FROM balances     UNION ALL
SELECT 'orders',       COUNT(*) FROM orders       UNION ALL
SELECT 'trades',       COUNT(*) FROM trades       UNION ALL
SELECT 'deposits',     COUNT(*) FROM deposits     UNION ALL
SELECT 'withdrawals',  COUNT(*) FROM withdrawals;
