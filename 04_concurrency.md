# Layer 4 — Indexes and Query Optimization

## Setup

1. Run `sql/01_schema.sql` — fresh schema, PK/UNIQUE indexes only.
2. Run `sql/03_seed_large.sql` — loads ~500 users / 50k orders / 15k trades and
   calls `ANALYZE` at the end (without fresh statistics the planner can pick
   terrible plans for the wrong reasons).
3. Turn on timing in `psql`: `\timing on`.
4. For each benchmark below, run
   `EXPLAIN (ANALYZE, BUFFERS) <query>;` — the plans shown below are
   **illustrative**. Absolute numbers will differ on your hardware, but the
   *shape* of the plan (which nodes appear, whether it's a `Seq Scan` or an
   `Index Scan`) should match.


## Methodology for each benchmark

1. **Baseline** — run `EXPLAIN (ANALYZE, BUFFERS)` with no secondary index.
2. **Reason** — identify the access pattern (point lookup / range scan /
   join on FK / aggregation).
3. **Add one index** — with a one-line justification.
4. **Re-run** — capture the new plan and the speed-up.
5. **Summarise** — tie the observed change back to the chapter on indexes.

Reminders:

- After adding an index you do **not** need to re-`ANALYZE`; the index is
  populated immediately and the planner updates its statistics.
- Use `DROP INDEX idx_name;` to revert and re-check; the plan should
  revert to the baseline.
- The planner is cost-based, not rule-based. An index that "should" help
  can be ignored if the statistics say a sequential scan is cheaper —
  that's the topic of Benchmark 4.


## Benchmark 1 — Order book for BTC/USD

**Query** (simplified from Q3 of the catalogue — just the ask side, for
focus):

```sql
SELECT o.order_id, o.price, o.quantity - o.filled_quantity AS remaining
FROM   orders o
WHERE  o.market_id = 1                   -- BTC/USD
  AND  o.side      = 'SELL'
  AND  o.status    IN ('OPEN', 'PARTIAL')
ORDER BY o.price ASC;
```

### 1.1 Baseline plan (no secondary index)

```
Sort  (cost=1350.00..1360.00 rows=4000 width=24) (actual time=25.3..25.9 rows=2500)
  Sort Key: price
  Sort Method: quicksort  Memory: 350kB
  ->  Seq Scan on orders o  (cost=0.00..1200.00 rows=4000 width=24)
                            (actual time=0.02..22.1 rows=2500)
        Filter: ((market_id = 1) AND (side = 'SELL'::varchar)
                 AND (status = ANY ('{OPEN,PARTIAL}'::varchar[])))
        Rows Removed by Filter: 47500
 Planning Time: 0.3 ms
 Execution Time: 26.4 ms
```

The planner has no choice: with only the PK index on `order_id`, it must
read all 50k rows and discard 95% via the `Filter`. The `Rows Removed by
Filter: 47500` line is the giveaway — almost everything we read was thrown
away.

### 1.2 Reasoning

The access pattern is:

- **equality** on `market_id` and `side` (high selectivity),
- **set-membership** on `status` (a prefix of the status domain),
- **ordered read** on `price`.

A composite B-tree on `(market_id, side, status, price)` gives us:

1. an equality seek on the first two columns,
2. a second equality/IN on `status`, and
3. a pre-sorted walk over `price`, which eliminates the separate sort.

### 1.3 Index

```sql
CREATE INDEX idx_orders_book
    ON orders (market_id, side, status, price);
```

### 1.4 Plan after indexing

```
Index Scan using idx_orders_book on orders o
    (cost=0.29..120.50 rows=2500 width=24)
    (actual time=0.05..1.9 rows=2500)
  Index Cond: ((market_id = 1) AND (side = 'SELL'::varchar)
               AND (status = ANY ('{OPEN,PARTIAL}'::varchar[])))
 Planning Time: 0.2 ms
 Execution Time: 2.2 ms
```

- `Seq Scan` → `Index Scan` ✓
- No separate `Sort` node — the index returns rows in `price` order ✓
- ~10× speed-up and, importantly, a plan whose cost grows with the *result
  size*, not the table size.

### 1.5 Takeaway

Column order matters. `(market_id, side, status, price)` works because the
query filters on the first three with equality/`IN` and then wants `price`
sorted. Reversing the order to `(price, market_id, side, status)` would
force an index scan over every price point and still need a sort per
filter combination. Index column order is a cost model question, not a
stylistic one.


## Benchmark 2 — Trades involving a specific user

**Query** (Q4-like: fetch all trades user 42 was party to):

```sql
SELECT t.trade_id, 'MAKER' AS role, t.price, t.quantity, t.executed_at
FROM   trades t
JOIN   orders o ON o.order_id = t.maker_order_id
WHERE  o.user_id = 42
UNION ALL
SELECT t.trade_id, 'TAKER', t.price, t.quantity, t.executed_at
FROM   trades t
JOIN   orders o ON o.order_id = t.taker_order_id
WHERE  o.user_id = 42;
```

### 2.1 Baseline plan

```
Append  (cost=... rows=... width=...) (actual time=45.0..90.2 rows=60)
  ->  Hash Join  (cost=... rows=... width=...)
        Hash Cond: (t.maker_order_id = o.order_id)
        ->  Seq Scan on trades t    (rows=15000)
        ->  Hash
              ->  Seq Scan on orders o
                    Filter: (user_id = 42)
                    Rows Removed by Filter: 49940
  ->  Hash Join  (cost=... rows=... width=...)
        Hash Cond: (t.taker_order_id = o.order_id)
        ->  Seq Scan on trades t    (rows=15000)
        ->  Hash
              ->  Seq Scan on orders o
                    Filter: (user_id = 42)
 Execution Time: 92 ms
```

Two sequential scans of `orders` (one per `UNION ALL` branch), two full
scans of `trades`. We look at 130k rows to return ~60.

### 2.2 Reasoning

- The predicate `user_id = 42` is highly selective (~60 / 50 000).
  → index on `orders(user_id)`.
- The join keys on `trades` (`maker_order_id`, `taker_order_id`) have no
  index. Without them the planner chooses hash joins and rebuilds a hash
  table on 15k rows twice.
  → index on each FK column in `trades`.

### 2.3 Indexes

```sql
CREATE INDEX idx_orders_user           ON orders (user_id);
CREATE INDEX idx_trades_maker_order    ON trades (maker_order_id);
CREATE INDEX idx_trades_taker_order    ON trades (taker_order_id);
```

A general rule of thumb: **PostgreSQL does *not* automatically index
foreign-key columns**. It only auto-indexes PKs and UNIQUE constraints.
FK columns that will appear on the right-hand side of joins (the
"pointer-chased" side) or in equality filters need explicit indexes.

### 2.4 Plan after indexing

```
Append  (rows=60)
  ->  Nested Loop  (actual time=0.08..0.45 rows=30)
        ->  Index Scan using idx_orders_user on orders o
              Index Cond: (user_id = 42)
        ->  Index Scan using idx_trades_maker_order on trades t
              Index Cond: (maker_order_id = o.order_id)
  ->  Nested Loop  (actual time=0.05..0.42 rows=30)
        ->  Index Scan using idx_orders_user on orders o
              Index Cond: (user_id = 42)
        ->  Index Scan using idx_trades_taker_order on trades t
              Index Cond: (taker_order_id = o.order_id)
 Execution Time: 1.1 ms
```

- `Hash Join` → `Nested Loop` with two `Index Scan`s ✓
- ~80× speed-up.
- Plan cost is now `O(matching_orders × avg_trades_per_order)`, not
  `O(|trades| + |orders|)`.

### 2.5 Takeaway

When the planner has no index on a join column, it defaults to a hash
join — fine when both sides are huge, terrible when one side is tiny
(here: 60 matching orders). An index on the join column lets the planner
switch to a nested-loop with index lookups, which is ideal when the
outer side is small.


## Benchmark 3 — Trades in a time window

**Query** (daily volume for the last 7 days, per market):

```sql
SELECT o.market_id,
       date_trunc('day', t.executed_at) AS day,
       SUM(t.quantity)                  AS qty
FROM   trades t
JOIN   orders o ON o.order_id = t.maker_order_id
WHERE  t.executed_at >= NOW() - INTERVAL '7 days'
GROUP BY o.market_id, date_trunc('day', t.executed_at)
ORDER BY o.market_id, day;
```

### 3.1 Baseline plan (with the indexes from Benchmark 2 already in place)

```
Sort  (actual time=18.5..18.7 rows=28)
  ->  HashAggregate  (actual time=18.0..18.3 rows=28)
        ->  Hash Join  (actual time=0.5..15.5 rows=1160)
              Hash Cond: (t.maker_order_id = o.order_id)
              ->  Seq Scan on trades t
                    Filter: (executed_at >= (now() - '7 days'::interval))
                    Rows Removed by Filter: 13840
              ->  Hash  (rows=50000)
                    ->  Seq Scan on orders o
 Execution Time: 19 ms
```

The planner still seq-scans `trades` because there is no index on
`executed_at`.

### 3.2 Reasoning

`executed_at >= X` is a **range predicate** — classic B-tree territory.
With 15k trades spread over 90 days, the last 7 days are ~1/13th of the
table: selective enough that a range scan beats a sequential scan.

### 3.3 Index

```sql
CREATE INDEX idx_trades_executed_at ON trades (executed_at);
```

### 3.4 Plan after indexing

```
Sort  (actual time=3.1..3.1 rows=28)
  ->  HashAggregate  (rows=28)
        ->  Nested Loop  (rows=1160)
              ->  Index Scan using idx_trades_executed_at on trades t
                    Index Cond: (executed_at >= (now() - '7 days'::interval))
              ->  Index Scan using orders_pkey on orders o
                    Index Cond: (order_id = t.maker_order_id)
 Execution Time: 3.4 ms
```

- `Seq Scan on trades` + `Filter` → `Index Scan` with `Index Cond` ✓
- The orders-side lookup is now a PK probe (no secondary index needed
  for that direction).

### 3.5 Takeaway

Time-series filters are the single best use case for B-tree indexes: the
data is append-mostly, the index is naturally ordered, and the typical
query is "the last N days" which is always selective. `executed_at` on
`trades` is the index you would never drop.


## Benchmark 4 — The index that doesn't help

Not every index pays for itself. Indexes slow writes (every `INSERT` and
`UPDATE` touches every index on the table) and the planner will refuse
to use an index it judges more expensive than a seq scan. This benchmark
shows both.

### 4.1 Query: count filled orders

```sql
SELECT COUNT(*) FROM orders WHERE status = 'FILLED';
```

### 4.2 Add a naive index

```sql
CREATE INDEX idx_orders_status ON orders (status);
```

### 4.3 Plan

```
Aggregate  (actual time=9.8..9.8 rows=1)
  ->  Seq Scan on orders  (actual time=0.01..7.5 rows=30000)
        Filter: (status = 'FILLED'::varchar)
        Rows Removed by Filter: 20000
 Execution Time: 9.9 ms
```

**The planner ignored the index.** Thirty thousand of the fifty thousand
rows match (≈60%), and reading 60% of a table through an index is
strictly more expensive than reading the whole thing sequentially — the
index adds a pointer dereference per row for no selectivity benefit.
This is the planner doing its job.

### 4.4 When `status` *does* help: partial index

The order-book query from Benchmark 1 filtered on
`status IN ('OPEN', 'PARTIAL')`, which is only ~40% of orders and is
concentrated in the queries we care about. A **partial index** on just
those statuses stays small and is useful for exactly that workload:

```sql
DROP INDEX idx_orders_status;

CREATE INDEX idx_orders_open
    ON orders (market_id, side, price)
 WHERE status IN ('OPEN', 'PARTIAL');
```

The index only stores rows we will actually look at (~20k instead of
50k), and the `WHERE` clause makes the planner use it for matching
queries — often eliminating the need for the composite index from
Benchmark 1 entirely. Good problem for the report: benchmark B1 with
`idx_orders_book` vs with `idx_orders_open` and discuss which you would
keep in a write-heavy workload.

### 4.5 Takeaway

Three lessons from one benchmark:

1. **Selectivity matters.** An index on a low-selectivity predicate may
   be strictly ignored.
2. **Indexes cost writes.** If you never benefit on reads, you pay
   forever on writes.
3. **Partial indexes** let you target the slice of the table you
   actually query — a free win when the filtered subset is small.


## Summary — observed speed-ups

Fill in with your actual timings. The illustrative numbers above suggest
the orders-of-magnitude you should expect.

| # | Query                    | Before   | After    | Speed-up | Index                        |
|---|--------------------------|----------|----------|----------|------------------------------|
| 1 | Order book               | ~26 ms   | ~2 ms    | ~10×     | `(market_id, side, status, price)` |
| 2 | User's trade history     | ~92 ms   | ~1 ms    | ~80×     | `orders(user_id)`, `trades(maker_order_id)`, `trades(taker_order_id)` |
| 3 | Time-window aggregation  | ~19 ms   | ~3 ms    | ~6×      | `trades(executed_at)`        |
| 4 | Count filled orders      | ~10 ms   | ~10 ms   | 0×       | *(none; planner ignored the attempted index)* |


## Bonus topics worth a paragraph each in the report

**B-tree vs hash.** PostgreSQL's B-tree supports equality, range, ordering,
and `IN`. Its hash index supports only equality. Hash is rarely worth
picking today — the B-tree is competitive on equality and more versatile
everywhere else. Mention this but don't build the project around it.

**`EXPLAIN` vs `EXPLAIN ANALYZE` vs `EXPLAIN (ANALYZE, BUFFERS)`.** The
first shows the plan; the second actually runs the query and reports
observed row counts and timings; the third adds buffer-hit counts, which
show whether data came from memory or disk. Use `(ANALYZE, BUFFERS)` for
benchmarking.

**Index maintenance cost.** Every index is paid for on every `INSERT` /
`UPDATE` / `DELETE` that touches an indexed column. For a write-heavy
table (`trades`, `orders`) each extra index is real overhead. This is why
you index what you query, not everything you can.

**`pg_stat_statements`.** A PostgreSQL extension that records every query
executed, with aggregated time and buffer-hit stats. In a real project
you would use it to find the queries worth optimising rather than
guessing. Worth mentioning as "what a production workflow looks like"
even if you don't install it.


## Files

- `sql/04_indexes.sql` — the `CREATE INDEX` statements, with one-line
  rationale comments, ready to run after the large seed.
