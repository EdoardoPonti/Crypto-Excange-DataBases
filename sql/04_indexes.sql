-- ============================================================================
-- Layer 4 — Indexes
--
-- Run AFTER 05_large_seed.sql (and ANALYZE; has run).
-- Each CREATE INDEX has a one-line rationale; see 06_indexing.md for the
-- full benchmark write-up.
--
-- To see a plan change, run the corresponding query with
-- EXPLAIN (ANALYZE, BUFFERS) before and after creating each index.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- Benchmark 1: order book for a market
-- Composite, leftmost-equality + trailing-sort pattern.
-- ---------------------------------------------------------------------------
CREATE INDEX idx_orders_book
    ON orders (market_id, side, status, price);


-- ---------------------------------------------------------------------------
-- Benchmark 2: find all orders / trades for a user
-- PostgreSQL does NOT auto-index FK columns.
-- ---------------------------------------------------------------------------
CREATE INDEX idx_orders_user
    ON orders (user_id);

CREATE INDEX idx_trades_maker_order
    ON trades (maker_order_id);

CREATE INDEX idx_trades_taker_order
    ON trades (taker_order_id);


-- ---------------------------------------------------------------------------
-- Benchmark 3: time-window queries on trades
-- Range predicate on an append-mostly timestamp column; classic B-tree win.
-- ---------------------------------------------------------------------------
CREATE INDEX idx_trades_executed_at
    ON trades (executed_at);


-- ---------------------------------------------------------------------------
-- Benchmark 4: partial index replacing idx_orders_status
--
-- The naive `CREATE INDEX ON orders (status)` was ignored by the planner
-- (see 06_indexing.md §4). A PARTIAL index on the selective subset
-- (OPEN/PARTIAL) stays small and actually gets used by order-book queries.
--
-- NOTE: this overlaps with idx_orders_book. For a write-heavy workload
-- you might keep only one of the two; for a project deliverable it is
-- fine to benchmark both and discuss the trade-off.
-- ---------------------------------------------------------------------------
CREATE INDEX idx_orders_open
    ON orders (market_id, side, price)
 WHERE status IN ('OPEN', 'PARTIAL');


-- ---------------------------------------------------------------------------
-- Useful diagnostics after creating the indexes
-- ---------------------------------------------------------------------------

-- List every index, with size:
--   SELECT schemaname, relname, indexrelname,
--          pg_size_pretty(pg_relation_size(indexrelid)) AS idx_size,
--          idx_scan, idx_tup_read, idx_tup_fetch
--   FROM pg_stat_user_indexes
--   ORDER BY pg_relation_size(indexrelid) DESC;

-- Show whether an index has ever been used:
--   SELECT indexrelname, idx_scan
--   FROM pg_stat_user_indexes
--   WHERE idx_scan = 0;
