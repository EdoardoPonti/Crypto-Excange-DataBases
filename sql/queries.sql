-- ============================================================================
-- Exchange Simulator — Query Catalogue (runnable)
--
-- Run AFTER 02_schema.sql and 03_seed.sql.
-- Each query is bracketed with \echo so you can find its output in psql.
-- See 04_queries.md for the relational-algebra expressions and commentary.
-- ============================================================================


-- ------------------------------------------------------------------
\echo '--- Q1. Active markets with base/quote symbols ---'
-- ------------------------------------------------------------------
SELECT m.market_id,
       b.symbol AS base_symbol,
       q.symbol AS quote_symbol,
       m.min_order_qty
FROM   markets m
JOIN   assets b ON b.asset_id = m.base_asset_id
JOIN   assets q ON q.asset_id = m.quote_asset_id
WHERE  m.status = 'ACTIVE'
ORDER  BY m.market_id;


-- ------------------------------------------------------------------
\echo '--- Q2. Alice''s balances ---'
-- ------------------------------------------------------------------
SELECT a.symbol,
       bal.available_amount,
       bal.locked_amount,
       bal.available_amount + bal.locked_amount AS total
FROM   users u
JOIN   balances bal ON bal.user_id  = u.user_id
JOIN   assets   a   ON a.asset_id   = bal.asset_id
WHERE  u.username = 'alice'
ORDER  BY a.symbol;


-- ------------------------------------------------------------------
\echo '--- Q3. Order book for BTC/USD ---'
-- ------------------------------------------------------------------
-- Wrapping the UNION ALL in a subquery keeps the outer ORDER BY portable
-- (PostgreSQL accepts the unwrapped form; stricter dialects do not).
SELECT label, order_id, price, remaining
FROM (
    SELECT 'ASKS' AS label,
           o.order_id, o.price,
           o.quantity - o.filled_quantity AS remaining
    FROM   orders o
    JOIN   markets m ON m.market_id = o.market_id
    JOIN   assets  b ON b.asset_id  = m.base_asset_id
    JOIN   assets  q ON q.asset_id  = m.quote_asset_id
    WHERE  b.symbol = 'BTC' AND q.symbol = 'USD'
      AND  o.side = 'SELL'
      AND  o.status IN ('OPEN', 'PARTIAL')

    UNION ALL

    SELECT 'BIDS',
           o.order_id, o.price,
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
         CASE WHEN label = 'ASKS' THEN  price
              ELSE                    -price END;


-- ------------------------------------------------------------------
\echo '--- Q4. Carol''s trade history with maker/taker role ---'
-- ------------------------------------------------------------------
SELECT t.trade_id, 'MAKER' AS role, t.price, t.quantity, t.executed_at
FROM   trades t
JOIN   orders o ON o.order_id = t.maker_order_id
JOIN   users  u ON u.user_id  = o.user_id
WHERE  u.username = 'carol'

UNION ALL

SELECT t.trade_id, 'TAKER', t.price, t.quantity, t.executed_at
FROM   trades t
JOIN   orders o ON o.order_id = t.taker_order_id
JOIN   users  u ON u.user_id  = o.user_id
WHERE  u.username = 'carol'

ORDER BY executed_at;


-- ------------------------------------------------------------------
\echo '--- Q5. Total traded volume per market ---'
-- ------------------------------------------------------------------
SELECT m.market_id,
       b.symbol AS base_symbol,
       q.symbol AS quote_symbol,
       SUM(t.quantity) AS total_qty,
       COUNT(*)        AS n_trades
FROM   trades  t
JOIN   orders  o ON o.order_id  = t.maker_order_id
JOIN   markets m ON m.market_id = o.market_id
JOIN   assets  b ON b.asset_id  = m.base_asset_id
JOIN   assets  q ON q.asset_id  = m.quote_asset_id
GROUP  BY m.market_id, b.symbol, q.symbol
ORDER  BY m.market_id;


-- ------------------------------------------------------------------
\echo '--- Q6. VWAP per market ---'
-- ------------------------------------------------------------------
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


-- ------------------------------------------------------------------
\echo '--- Q7. Open-order count per user (outer join) ---'
-- ------------------------------------------------------------------
SELECT u.username,
       COUNT(o.order_id) FILTER (WHERE o.status IN ('OPEN','PARTIAL'))
            AS open_count
FROM   users u
LEFT   JOIN orders o ON o.user_id = u.user_id
GROUP  BY u.username
ORDER  BY u.username;


-- ------------------------------------------------------------------
\echo '--- Q8. Users with orders but who have never traded ---'
-- ------------------------------------------------------------------
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


-- ------------------------------------------------------------------
\echo '--- Q9. Pairs of users who have traded together ---'
-- ------------------------------------------------------------------
SELECT LEAST(um.username, ut.username)    AS user_a,
       GREATEST(um.username, ut.username) AS user_b,
       COUNT(*)                           AS n_trades
FROM   trades t
JOIN   orders mo ON mo.order_id = t.maker_order_id
JOIN   orders tk ON tk.order_id = t.taker_order_id
JOIN   users  um ON um.user_id  = mo.user_id
JOIN   users  ut ON ut.user_id  = tk.user_id
WHERE  mo.user_id <> tk.user_id
GROUP  BY LEAST(um.username, ut.username),
          GREATEST(um.username, ut.username)
ORDER  BY user_a, user_b;


-- ------------------------------------------------------------------
\echo '--- Q10. Top holder per asset (subquery with MAX per group) ---'
-- ------------------------------------------------------------------
SELECT a.symbol,
       u.username,
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


-- ------------------------------------------------------------------
\echo '--- Q11. Users who placed orders in every market (division) ---'
-- ------------------------------------------------------------------

-- Form 1: double NOT EXISTS (the canonical "divide" encoding)
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

-- Form 2: GROUP BY + HAVING COUNT (equivalent on this schema)
-- SELECT u.username
-- FROM   orders o
-- JOIN   users  u ON u.user_id = o.user_id
-- GROUP  BY u.username
-- HAVING COUNT(DISTINCT o.market_id) = (SELECT COUNT(*) FROM markets);
