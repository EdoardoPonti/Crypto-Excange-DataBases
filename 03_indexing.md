# Query Catalogue — Layer 3

Eleven queries of increasing complexity against the schema in `sql/01_schema.sql`
and seed data in `sql/02_seed_small.sql`. For each query:

1. the **question** in English,
2. the **relational algebra** expression,
3. the **SQL**, and
4. the **expected output** on the seed data (so the professor can verify by
   inspection).

Relational algebra and SQL are not a perfect match — some SQL features
(ordering, `CASE`, arithmetic inside aggregates, `FILTER`) are extensions
beyond the pure 6-operator RA. Each query flags where extensions appear.


## Notation Legend

| Symbol             | Meaning                                                    |
|--------------------|------------------------------------------------------------|
| σ_{φ}(R)           | **selection** — rows of R satisfying predicate φ           |
| π_{L}(R)           | **projection** — keep only the attribute list L            |
| R ⋈ S              | **natural join** (on shared attribute names)               |
| R ⋈_{θ} S          | **theta join** with predicate θ                            |
| R ⟕ S              | **left outer join**                                        |
| ρ_{x}(R)           | **rename** — give relation R the alias `x`                 |
| R ∪ S, R ∩ S, R − S | union, intersection, difference                           |
| R × S              | Cartesian product                                          |
| γ_{G; A}(R)        | **grouping & aggregation** — group by G, compute aggregates A |
| R ÷ S              | **division**                                               |

Extensions used (flagged in each query):

- **ordering** (`ORDER BY`): presentation only, not part of RA
- **`CASE`** / constant-valued projection: derived attribute with a literal
- **arithmetic in aggregates** (e.g. `SUM(price*qty)`): extended γ


## Index

| #  | Title                                         | Techniques                             |
|----|-----------------------------------------------|----------------------------------------|
| 1  | Active markets with base/quote symbols        | σ, π, ⋈ with self-renamed `Asset`      |
| 2  | A user's balances                             | σ, π, 3-way ⋈                          |
| 3  | Order book for `BTC/USD`                      | σ on compound predicate, ∪, ORDER BY   |
| 4  | A user's trade history with maker/taker role  | ∪ with constant-valued projection       |
| 5  | Total traded volume per market                | γ with `SUM`, `COUNT`                  |
| 6  | VWAP per market                               | γ with arithmetic (extension)          |
| 7  | Open-order count per user                     | ⟕ (outer join) + γ                     |
| 8  | Users with orders but never traded            | − (set difference)                     |
| 9  | Pairs of users who have traded together       | self-⋈, renaming, `LEAST`/`GREATEST`    |
| 10 | Top holder per asset                          | γ MAX + semi-join via tuple `IN`       |
| 11 | Users who have placed orders in *every* market | ÷ (division)                           |


---

## Q1. Active markets with base/quote symbols

**Question.** List every market currently marked `ACTIVE`, showing the pair
symbol (base/quote) and the minimum order quantity.

**Relational algebra.**

Let `Ab = ρ_{b}(Asset)` and `Aq = ρ_{q}(Asset)` be two renamed copies of
`Asset`:

```
π_{market_id, b.symbol, q.symbol, min_order_qty}(
    σ_{status='ACTIVE'}(Market)
  ⋈_{base_asset_id = b.asset_id}  Ab
  ⋈_{quote_asset_id = q.asset_id} Aq
)
```

**SQL.**

```sql
SELECT m.market_id,
       b.symbol AS base_symbol,
       q.symbol AS quote_symbol,
       m.min_order_qty
FROM   markets m
JOIN   assets b ON b.asset_id = m.base_asset_id
JOIN   assets q ON q.asset_id = m.quote_asset_id
WHERE  m.status = 'ACTIVE'
ORDER  BY m.market_id;
```

**Expected result.**

| market_id | base_symbol | quote_symbol | min_order_qty |
|-----------|-------------|--------------|---------------|
| 1         | BTC         | USD          | 0.00010000    |
| 2         | ETH         | USD          | 0.00100000    |
| 3         | SOL         | USD          | 0.01000000    |
| 4         | ETH         | BTC          | 0.00100000    |

**Notes.** Demonstrates renaming (ρ) — a relation must be referenced under
two different aliases because `Market` has two FKs into `Asset`.


---

## Q2. A user's balances (filter + 3-way join)

**Question.** List Alice's balances, showing the asset symbol, the
available amount, the locked amount, and the total.

**Relational algebra.**

```
π_{a.symbol, bal.available_amount, bal.locked_amount,
   bal.available_amount + bal.locked_amount → total}(
    σ_{u.username='alice'}(User(u))
  ⋈  Balance(bal)
  ⋈  Asset(a)
)
```

(Computed column is an extension of pure π.)

**SQL.**

```sql
SELECT a.symbol,
       bal.available_amount,
       bal.locked_amount,
       bal.available_amount + bal.locked_amount AS total
FROM   users u
JOIN   balances bal ON bal.user_id  = u.user_id
JOIN   assets   a   ON a.asset_id   = bal.asset_id
WHERE  u.username = 'alice'
ORDER  BY a.symbol;
```

**Expected result.**

| symbol | available_amount | locked_amount | total       |
|--------|------------------|---------------|-------------|
| BTC    | 1.50000000       | 0.00000000    | 1.50000000  |
| USD    | 30000.00000000   | 20000.00000000| 50000.00000000 |

**Notes.** Straightforward filter + two joins. The computed `total` column
exists only in extended RA (pure π cannot compute expressions).


---

## Q3. Order book for `BTC/USD`

**Question.** Show the open (`OPEN` or `PARTIAL`) orders on `BTC/USD`,
labelled `ASKS` (sell) or `BIDS` (buy), ordered so that the best ask (lowest
sell price) and best bid (highest buy price) appear at the top of their
respective sections.

**Relational algebra.**

Let `M1 = σ_{market_id = 1}(Market)` (the `BTC/USD` market — or written
more faithfully as `σ_{b.symbol='BTC' ∧ q.symbol='USD'}(Market ⋈ b ⋈ q)`).

```
Asks = π_{order_id, 'ASKS' → label, price, quantity - filled_quantity → rem}(
          σ_{side='SELL' ∧ status ∈ {OPEN, PARTIAL}}(Orders ⋈ M1)
       )

Bids = π_{order_id, 'BIDS' → label, price, quantity - filled_quantity → rem}(
          σ_{side='BUY'  ∧ status ∈ {OPEN, PARTIAL}}(Orders ⋈ M1)
       )

Result = Asks ∪ Bids
```

Ordering is not part of RA — applied at the SQL layer.

**SQL.** We wrap the `UNION ALL` in a subquery so the outer `ORDER BY` can
use a `CASE` expression over the output columns. (The unwrapped form —
`ORDER BY` directly after the `UNION ALL` — works in PostgreSQL but is
rejected by stricter dialects such as SQLite; wrapping is the portable
idiom.)

```sql
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
ORDER BY label,                                   -- 'ASKS' < 'BIDS'
         CASE WHEN label = 'ASKS' THEN  price     -- asks: lowest first
              ELSE                    -price END;  -- bids: highest first
```

**Expected result.**

| label | order_id | price      | remaining  |
|-------|----------|------------|------------|
| ASKS  | 4        | 41000.00   | 0.30000000 |
| BIDS  | 1        | 40000.00   | 0.50000000 |
| BIDS  | 5        | 39500.00   | 0.20000000 |

**Notes.** The spread is `41000 - 40000 = 1000` USD. The `CASE` expression
inside `ORDER BY` is the standard SQL trick to apply different sort
directions to different sections of a `UNION`.


---

## Q4. A user's trade history with maker/taker role

**Question.** For Carol, list every trade she was involved in, labelled
`MAKER` or `TAKER`.

**Relational algebra.**

```
MakerTrades = π_{t.trade_id, 'MAKER' → role, t.price, t.quantity, t.executed_at}(
                σ_{u.username='carol'}(
                    Trade(t) ⋈_{t.maker_order_id = o.order_id} Orders(o)
                    ⋈_{o.user_id = u.user_id}                   User(u)
                )
              )

TakerTrades = π_{t.trade_id, 'TAKER' → role, t.price, t.quantity, t.executed_at}(
                σ_{u.username='carol'}(
                    Trade(t) ⋈_{t.taker_order_id = o.order_id} Orders(o)
                    ⋈_{o.user_id = u.user_id}                   User(u)
                )
              )

Result = MakerTrades ∪ TakerTrades
```

The constant-valued attribute (`'MAKER'` / `'TAKER'`) is an extension of
pure π; it is standard in extended RA.

**SQL.**

```sql
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
```

**Expected result.**

| trade_id | role  | price   | quantity    |
|----------|-------|---------|-------------|
| 1        | TAKER | 2500.00 | 1.00000000  |

**Notes.** This is the pattern to reach for any time a relation refers to
another relation in multiple roles (maker/taker, buyer/seller,
author/reviewer…) and you want a single row per involvement. Alternative:
a single `SELECT` with a `CASE` in the projection and an `OR` in the join
condition — works, but is harder to reason about.


---

## Q5. Total traded volume per market

**Question.** For each market that has trades, show the base/quote symbols,
the total traded base quantity, and the number of trades.

**Relational algebra.**

```
γ_{m.market_id, b.symbol, q.symbol;
   SUM(t.quantity) → total_qty,
   COUNT(*)        → n_trades}(
    Trade(t)
  ⋈_{t.maker_order_id = o.order_id} Orders(o)
  ⋈_{o.market_id = m.market_id}     Market(m)
  ⋈ ρ_b(Asset) ⋈ ρ_q(Asset)
)
```

**SQL.**

```sql
SELECT m.market_id,
       b.symbol AS base_symbol,
       q.symbol AS quote_symbol,
       SUM(t.quantity) AS total_qty,
       COUNT(*)        AS n_trades
FROM   trades  t
JOIN   orders  o ON o.order_id  = t.maker_order_id   -- any side would work
JOIN   markets m ON m.market_id = o.market_id
JOIN   assets  b ON b.asset_id  = m.base_asset_id
JOIN   assets  q ON q.asset_id  = m.quote_asset_id
GROUP  BY m.market_id, b.symbol, q.symbol
ORDER  BY m.market_id;
```

**Expected result.**

| market_id | base_symbol | quote_symbol | total_qty  | n_trades |
|-----------|-------------|--------------|------------|----------|
| 2         | ETH         | USD          | 1.00000000 | 1        |

**Notes.** `market_id` is recovered through the maker order — the same
value would come from `taker_order_id` thanks to the trigger invariant (see
`sql/01_schema.sql`). This is the query that *pays the cost* of the 3NF
decomposition in §3.6 of `docs/01_er_and_normalization.md`: we had to join to
recover an attribute we removed. That trade-off is worth stating in the
report.


---

## Q6. VWAP per market (computed aggregation)

**Question.** For each market with trades, compute the volume-weighted
average price:

  VWAP = ∑(price × quantity) / ∑(quantity)

**Relational algebra (extended).**

```
γ_{m.market_id, b.symbol, q.symbol;
   SUM(t.price * t.quantity) / SUM(t.quantity) → vwap,
   SUM(t.quantity)                             → total_qty,
   COUNT(*)                                    → n_trades}(
    Trade(t) ⋈ Orders(o) ⋈ Market(m) ⋈ ρ_b(Asset) ⋈ ρ_q(Asset)
)
```

Arithmetic inside an aggregate is **not** part of pure RA — it is a
standard extension supported by SQL.

**SQL.**

```sql
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
```

**Expected result.**

| market_id | symbol   | vwap    | total_qty  | n_trades |
|-----------|----------|---------|------------|----------|
| 2         | ETH/USD  | 2500.00 | 1.00000000 | 1        |


---

## Q7. Open-order count per user (outer join)

**Question.** For every user, show how many open orders (`OPEN` or
`PARTIAL`) they currently have — including 0 for users with none.

**Relational algebra.**

Break the computation into steps to keep γ clean:

```
OpenOrders = σ_{status ∈ {OPEN, PARTIAL}}(Orders)
Counts     = γ_{user_id; COUNT(*) → n}(OpenOrders)
Result     = π_{u.username, COALESCE(c.n, 0) → open_count}(
               User(u) ⟕_{u.user_id = c.user_id} ρ_c(Counts)
             )
```

`⟕` is the **left outer join** — keeps users with no matching row in
`Counts`, padding `n` with `NULL`, which `COALESCE` turns into `0`.

**SQL.**

```sql
SELECT u.username,
       COUNT(o.order_id) FILTER (WHERE o.status IN ('OPEN','PARTIAL'))
            AS open_count
FROM   users u
LEFT   JOIN orders o ON o.user_id = u.user_id
GROUP  BY u.username
ORDER  BY u.username;
```

`COUNT(…) FILTER (WHERE …)` is the SQL-standard way to count a subset per
group. A pre-`FILTER` equivalent is `COUNT(CASE WHEN … THEN 1 END)`.

**Expected result.**

| username | open_count |
|----------|------------|
| alice    | 1          |
| bob      | 1          |
| carol    | 0          |
| dave     | 1          |
| eve      | 1          |

**Notes.** Carol's order is `FILLED`, not open. Because we used a **left**
join, a user with no rows in `orders` at all would still appear with
`open_count = 0`. Change `LEFT JOIN` to `INNER JOIN` and that user would
vanish — a good thing to demonstrate in the report by inserting a
no-orders test user.


---

## Q8. Users with orders but who have never traded

**Question.** Which users have placed at least one order but have never
been a party (maker or taker) to any trade?

**Relational algebra.**

```
HasOrder    = π_{user_id}(Orders)

TradedAsMaker = π_{o.user_id}(Trade ⋈_{t.maker_order_id = o.order_id} Orders(o))
TradedAsTaker = π_{o.user_id}(Trade ⋈_{t.taker_order_id = o.order_id} Orders(o))
Traded        = TradedAsMaker ∪ TradedAsTaker

Result = HasOrder − Traded
```

**SQL.**

```sql
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
```

**Expected result.**

| username |
|----------|
| alice    |
| dave     |
| eve      |

**Notes.** Classic use of `−` / `NOT IN`. **Watch out for `NULL`:**
`NOT IN` returns `UNKNOWN` if the subquery produces any `NULL`, which makes
the outer `WHERE` drop the row. Our FK columns are `NOT NULL` so we are
safe, but it is worth calling out — this is the single most common SQL bug
students hit with set difference.


---

## Q9. Pairs of users who have traded together

**Question.** For every pair of distinct users who have traded at least
once (in either role), list the pair and the number of trades between them.

**Relational algebra.**

```
Pairs = π_{mo.user_id, tk.user_id}(
           Trade(t) ⋈_{t.maker_order_id = mo.order_id} ρ_{mo}(Orders)
                    ⋈_{t.taker_order_id = tk.order_id} ρ_{tk}(Orders)
        )

Distinct = σ_{mo.user_id ≠ tk.user_id}(Pairs)

Result = γ_{LEAST(mo.user_id, tk.user_id) → a,
            GREATEST(mo.user_id, tk.user_id) → b;
            COUNT(*) → n_trades}(Distinct)
```

**SQL.**

```sql
SELECT LEAST(um.username, ut.username)    AS user_a,
       GREATEST(um.username, ut.username) AS user_b,
       COUNT(*)                           AS n_trades
FROM   trades t
JOIN   orders mo ON mo.order_id = t.maker_order_id
JOIN   orders tk ON tk.order_id = t.taker_order_id
JOIN   users  um ON um.user_id  = mo.user_id
JOIN   users  ut ON ut.user_id  = tk.user_id
WHERE  mo.user_id <> tk.user_id                 -- exclude wash trades
GROUP  BY LEAST(um.username, ut.username),
          GREATEST(um.username, ut.username);
```

**Expected result.**

| user_a | user_b | n_trades |
|--------|--------|----------|
| bob    | carol  | 1        |

**Notes.** The `LEAST`/`GREATEST` trick canonicalises each unordered pair
so `{bob, carol}` is counted once — not twice as `(bob, carol)` and
`(carol, bob)`. The schema does not prevent a "wash trade" where maker and
taker are the same user (that would need extra CHECKs or application-level
prevention); the `<>` guard keeps them out of the result.


---

## Q10. Top holder per asset (subquery with MAX per group)

**Question.** For each asset that anyone holds, name the user with the
largest total holding (available + locked) and that total.

**Relational algebra.**

```
Totals = π_{user_id, asset_id, available_amount + locked_amount → total}(Balance)
MaxPerAsset = γ_{asset_id; MAX(total) → max_total}(Totals)
Winners = Totals ⋈_{Totals.asset_id = MaxPerAsset.asset_id
                    ∧ Totals.total = MaxPerAsset.max_total} MaxPerAsset
Result  = π_{a.symbol, u.username, Winners.total}(Winners ⋈ User ⋈ Asset)
```

**SQL.**

```sql
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
```

**Expected result.**

| symbol | username | total          |
|--------|----------|----------------|
| BTC    | alice    | 1.50000000     |
| ETH    | bob      | 9.00000000     |
| USD    | carol    | 96500.00000000 |

**Notes.** The tuple-`IN` pattern `WHERE (k, v) IN (SELECT k, MAX(v) …)` is
the cleanest pre-window-functions way to pick the argmax per group. If two
users tied for the top of an asset, both would appear — the query does not
arbitrarily pick one. Window functions (`ROW_NUMBER() OVER (PARTITION BY
asset_id ORDER BY total DESC)`) give a more flexible alternative, but they
belong in a later chapter.


---

## Q11. Users who have placed orders in *every* market (division)

**Question.** Which users have placed at least one order in every existing
market?

**Relational algebra.**

This is the textbook form of **division**:

```
π_{user_id, market_id}(Orders)  ÷  π_{market_id}(Market)
```

Division has no direct SQL operator. The standard SQL encoding is the
**double-`NOT EXISTS`** idiom, which literally reads as "there is no market
for which there is no matching order from this user":

**SQL.**

```sql
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
```

An equivalent formulation using aggregation:

```sql
SELECT u.username
FROM   orders o
JOIN   users  u ON u.user_id = o.user_id
GROUP  BY u.username
HAVING COUNT(DISTINCT o.market_id) = (SELECT COUNT(*) FROM markets);
```

**Expected result.** Empty — no user has placed orders in all four markets.

| username |
|----------|
| *(none)* |

**Notes.** An empty result is the *correct* answer for this seed and is
still pedagogically valuable: it shows the technique works without
requiring artificial data. If you want a non-empty demo for the report,
either (a) add a second order per user on a second market, or (b) restrict
the divisor to `σ_{status='ACTIVE'}(Market)` and make some markets
`HALTED`. The **double-`NOT EXISTS`** form is what every DB course
eventually asks about — make sure you can write it from memory.


---

## Summary — what each query demonstrates

| # | Topic on your syllabus                 | Appears as                       |
|---|----------------------------------------|----------------------------------|
| 1 | Relational algebra: σ, π, ⋈, ρ         | Q1                               |
| 2 | Multi-way join                         | Q2, Q5                           |
| 3 | Union with derived attribute           | Q3, Q4                           |
| 4 | Aggregation (γ) with/without arithmetic| Q5, Q6, Q9                       |
| 5 | Outer join                             | Q7                               |
| 6 | Set difference (−)                     | Q8                               |
| 7 | Self-join                              | Q9                               |
| 8 | Subquery with `MAX`, tuple `IN`        | Q10                              |
| 9 | Division (÷)                           | Q11                              |

A companion runnable file is in `sql/queries.sql`.
