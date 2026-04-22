# Layer 5 — Concurrency

The exchange domain is the textbook setting for concurrency bugs: two
trades want to debit the same balance, two cancellations race on the same
order, a matching engine reserves funds that are being released by a
withdrawal. This layer demonstrates four scenarios:

1. **Lost update** — why reading without locking is wrong.
2. **`SELECT … FOR UPDATE`** — the fix.
3. **Deadlock** — two sessions locking in opposite order.
4. **Consistent lock ordering** — the fix.

A fifth short section covers **isolation levels** (`READ COMMITTED`,
`REPEATABLE READ`, `SERIALIZABLE`) for completeness.


## How to run the scenarios

Each scenario requires **two `psql` sessions** running simultaneously. We
will call them **A** and **B**. Open two terminal windows, connect each to
your database, and execute the commands in the order given by the timing
column (`t=1`, `t=2`, …). When a command **blocks**, the session will sit
waiting — leave it and move to the other session.

Reset to the **small** seed (`sql/02_seed_small.sql`) before each scenario so the
starting balances are predictable. We'll use Alice's USD balance
throughout:

```sql
SELECT user_id, asset_id, available_amount, locked_amount
FROM   balances
WHERE  user_id = 1 AND asset_id = 1;      -- alice, USD

-- Expected starting state: available=30000, locked=20000
```


## Scenario 1 — Lost update under READ COMMITTED (the bug)

Two transactions simultaneously debit 10 000 USD from Alice's account
(imagine two payments being processed in parallel). Each reads the current
balance, subtracts 10 000, and writes the result. Expected final balance:
30 000 − 10 000 − 10 000 = **10 000**. We will see what actually happens.

The default PostgreSQL isolation level is `READ COMMITTED`, which is what
both sessions use here.

### Timing

```
t=1  A:  BEGIN;
         SELECT available_amount FROM balances
         WHERE  user_id = 1 AND asset_id = 1;
         --  returns 30000

t=2  B:  BEGIN;
         SELECT available_amount FROM balances
         WHERE  user_id = 1 AND asset_id = 1;
         --  returns 30000   ← both sessions read the same starting value

t=3  A:  UPDATE balances
         SET   available_amount = 30000 - 10000   -- 20000
         WHERE user_id = 1 AND asset_id = 1;
         COMMIT;

t=4  B:  UPDATE balances
         SET   available_amount = 30000 - 10000   -- 20000, based on stale read
         WHERE user_id = 1 AND asset_id = 1;
         COMMIT;
```

### Result

```sql
SELECT available_amount FROM balances WHERE user_id=1 AND asset_id=1;
-- 20000   (expected: 10000)
```

**Ten thousand dollars lost.** This is the canonical *lost update*
anomaly. Both transactions ran to completion, each saw a consistent world
from its own viewpoint, and the database accepted both — but one debit
effectively disappeared.

Why it happened:

- At `t=2`, B read `30000`, a value that A had not yet modified.
- At `t=3`, A committed `20000`.
- At `t=4`, B wrote `30000 - 10000 = 20000`, overwriting A's update with
  its own conclusion drawn from a stale read.

`READ COMMITTED` guarantees that B does not see *uncommitted* values from
A. It does **not** guarantee that a `SELECT` followed by an `UPDATE`
observes a consistent view of the row over time.


## Scenario 2 — Fixing with `SELECT … FOR UPDATE`

`FOR UPDATE` tells PostgreSQL: "I intend to modify this row; lock it
against other writers." A second session trying to `SELECT … FOR UPDATE`
on the same row will **block** until the first session commits or rolls
back.

### Timing

```
t=1  A:  BEGIN;
         SELECT available_amount FROM balances
         WHERE  user_id = 1 AND asset_id = 1
         FOR UPDATE;
         --  returns 30000, row lock acquired

t=2  B:  BEGIN;
         SELECT available_amount FROM balances
         WHERE  user_id = 1 AND asset_id = 1
         FOR UPDATE;
         --  BLOCKS — A holds the lock

t=3  A:  UPDATE balances
         SET   available_amount = 30000 - 10000
         WHERE user_id = 1 AND asset_id = 1;
         COMMIT;
         --  A releases its lock

         -- B now UNBLOCKS and its SELECT completes, returning 20000
         -- (the value A just committed)

t=4  B:  UPDATE balances
         SET   available_amount = 20000 - 10000   -- 10000, based on the
                                                  -- fresh read
         WHERE user_id = 1 AND asset_id = 1;
         COMMIT;
```

### Result

```sql
SELECT available_amount FROM balances WHERE user_id=1 AND asset_id=1;
-- 10000   ✓
```

The transactions were **serialised by the row lock**: B had to wait for A,
and once it got through, it read the post-A balance and produced the
correct answer.

Lesson: any read-modify-write on a balance must use `FOR UPDATE` on the
read. A bare `SELECT` under `READ COMMITTED` is a bug waiting to happen.


## Scenario 3 — Deadlock from inconsistent lock order

Now two transactions each need to update **two** rows, but they acquire
the locks in opposite order. This is the classic two-lock deadlock.

Setup: A transfers 1 000 USD from alice(1) to bob(2); B transfers 500 USD
from bob(2) to alice(1). Both are valid, both should succeed — but if
they interleave badly, they deadlock.

### Timing

```
t=1  A:  BEGIN;
         SELECT available_amount FROM balances
         WHERE  user_id = 1 AND asset_id = 1      -- alice
         FOR UPDATE;
         --  A holds the lock on alice

t=2  B:  BEGIN;
         SELECT available_amount FROM balances
         WHERE  user_id = 2 AND asset_id = 1      -- bob
         FOR UPDATE;
         --  B holds the lock on bob

t=3  A:  SELECT available_amount FROM balances
         WHERE  user_id = 2 AND asset_id = 1      -- bob
         FOR UPDATE;
         --  BLOCKS — B holds bob

t=4  B:  SELECT available_amount FROM balances
         WHERE  user_id = 1 AND asset_id = 1      -- alice
         FOR UPDATE;
         --  BLOCKS — A holds alice
         --  A is waiting for B, B is waiting for A:  DEADLOCK.
```

### Result

After a short interval (configured by `deadlock_timeout`, default 1 s),
PostgreSQL detects the cycle in its lock graph and aborts **one** of the
transactions:

```
ERROR:  deadlock detected
DETAIL: Process XXXX waits for ShareLock on transaction YYYY; blocked by
        process ZZZZ.
        Process ZZZZ waits for ShareLock on transaction WWWW; blocked by
        process XXXX.
HINT:   See server log for query details.
```

Which session gets killed is not guaranteed — the planner picks the
"cheaper" victim. The surviving session proceeds as if nothing happened;
the aborted one must retry the whole transaction.

Deadlock is not an unrecoverable bug — PostgreSQL resolves it. But
relying on detection is slow (you pay `deadlock_timeout` every time) and
wastes work (the victim's transaction has to be redone). The correct fix
is to not create the cycle in the first place.


## Scenario 4 — Fixing with consistent lock ordering

Rule: **always lock the lower `user_id` (or `account_id`) first.** If both
A and B follow the rule, they cannot create a cycle.

### Timing

```
t=1  A:  BEGIN;
         SELECT available_amount FROM balances
         WHERE  user_id = 1 AND asset_id = 1      -- lower id first
         FOR UPDATE;

t=2  B:  BEGIN;
         SELECT available_amount FROM balances
         WHERE  user_id = 1 AND asset_id = 1      -- lower id first
         FOR UPDATE;
         --  BLOCKS — A holds alice

t=3  A:  SELECT available_amount FROM balances
         WHERE  user_id = 2 AND asset_id = 1      -- now bob
         FOR UPDATE;
         -- OK — no one else has bob

t=4  A:  [... do the transfer math ...]
         UPDATE balances SET available_amount = ... WHERE user_id = 1;
         UPDATE balances SET available_amount = ... WHERE user_id = 2;
         COMMIT;

         -- A releases locks, B unblocks on t=2's SELECT

t=5  B:  SELECT ... WHERE user_id = 2 ... FOR UPDATE;
         [... do the transfer math ...]
         UPDATE ...;
         UPDATE ...;
         COMMIT;
```

Both transfers complete, serialised by the first-lock convention. Nobody
gets killed.

### Takeaway

Any procedure that takes multiple row locks should sort its targets by a
canonical key (here, `(user_id, asset_id)` lexicographically) before
acquiring any lock. This is a discipline imposed by the application, not
the database — but it's cheap, easy to audit, and eliminates an entire
class of bugs.

A slicker alternative in PostgreSQL is `SELECT … FOR UPDATE` on all rows
in a single statement, ordering with `ORDER BY`:

```sql
SELECT * FROM balances
WHERE  (user_id, asset_id) IN ((1,1), (2,1))
ORDER  BY user_id, asset_id
FOR UPDATE;
```

The `ORDER BY` determines the lock acquisition order within that
statement, and a second concurrent caller will acquire the same locks in
the same order.


## Scenario 5 — Isolation levels (brief tour)

PostgreSQL supports three isolation levels above its default:

| Level             | What it prevents (vs READ COMMITTED)              |
|-------------------|---------------------------------------------------|
| `READ COMMITTED`  | Dirty reads only. Default.                         |
| `REPEATABLE READ` | + Non-repeatable reads: a re-read of the same row inside a transaction always returns the first-observed value. |
| `SERIALIZABLE`    | + Phantom writes: the database guarantees an equivalent *serial* history. May abort transactions with `could_not_serialize`. |

### Quick demonstration: non-repeatable read

Under `READ COMMITTED`, re-reading a row can see a new value committed by
another transaction:

```
t=1  A:  BEGIN;                       -- READ COMMITTED (default)
         SELECT available_amount FROM balances
         WHERE user_id=1 AND asset_id=1;
         --  30000

t=2  B:  BEGIN;
         UPDATE balances
         SET available_amount = 25000
         WHERE user_id=1 AND asset_id=1;
         COMMIT;

t=3  A:  SELECT available_amount FROM balances
         WHERE user_id=1 AND asset_id=1;
         --  25000    ← value changed under A's feet
         COMMIT;
```

Same scenario under `REPEATABLE READ`:

```
t=1  A:  BEGIN ISOLATION LEVEL REPEATABLE READ;
         SELECT available_amount FROM balances ...;
         --  30000

t=2  B:  BEGIN; UPDATE ...=25000; COMMIT;

t=3  A:  SELECT available_amount FROM balances ...;
         --  30000    ← A still sees its original snapshot
         COMMIT;
```

A's transaction sees a single, stable snapshot of the database taken at
its first query.

### Optimistic vs pessimistic

- `FOR UPDATE` is **pessimistic**: it blocks writers on conflict.
- `SERIALIZABLE` is **optimistic**: it lets transactions proceed
  independently and aborts them at commit time if a conflict is detected.

Neither is universally better. For the hot-path matching workload that
this project simulates, pessimistic row locks on balances are the right
call because the conflict rate is high and aborts are expensive. For
periodic reporting / reconciliation jobs, `SERIALIZABLE` is more natural
because retries are cheap and the isolation guarantees are stronger.


## What to write up in the report

- **For each scenario**: paste the actual session transcripts (output of
  your two `psql` windows), show the final state of the `balances` row,
  and explain in one sentence what went right or wrong.
- **Pin the observations to the course material**: lost update is the
  direct motivation for 2-phase locking; deadlock is the direct
  motivation for lock ordering or deadlock detection; the isolation
  level differences are the direct motivation for the ANSI isolation
  hierarchy.
- Don't claim more than you've shown. `SERIALIZABLE` *prevents* anomalies
  your demo doesn't exhibit (phantom writes, skew-write) — mention them
  by name but don't pretend to have demonstrated them unless you wrote
  the extra test.


## Companion runnable SQL

See `sql/concurrency_sessions.sql`. It contains the four scenarios as
labelled blocks, ready to copy into two `psql` sessions. Between scenarios,
reset state by re-running `sql/02_seed_small.sql`.


## Appendix — a correctly locked `place_order` procedure

For completeness, here is the pattern a production-ish limit-order
placement procedure would follow. You don't need to implement this for
Layer 5 — it's a template showing how the locking primitives combine.

```sql
CREATE OR REPLACE FUNCTION place_limit_buy(
    p_user_id    bigint,
    p_market_id  int,
    p_price      numeric(20,8),
    p_quantity   numeric(20,8)
) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_quote_asset_id smallint;
    v_required       numeric(20,8);
    v_available      numeric(20,8);
    v_new_order_id   bigint;
BEGIN
    -- 1. Look up the quote asset of this market
    SELECT quote_asset_id INTO v_quote_asset_id
    FROM   markets WHERE market_id = p_market_id;

    v_required := p_price * p_quantity;

    -- 2. Lock the user's quote-asset balance row
    SELECT available_amount INTO v_available
    FROM   balances
    WHERE  user_id = p_user_id AND asset_id = v_quote_asset_id
    FOR UPDATE;

    IF v_available IS NULL OR v_available < v_required THEN
        RAISE EXCEPTION 'insufficient funds: need %, have %',
            v_required, COALESCE(v_available, 0);
    END IF;

    -- 3. Move funds from available to locked
    UPDATE balances
    SET    available_amount = available_amount - v_required,
           locked_amount    = locked_amount    + v_required
    WHERE  user_id = p_user_id AND asset_id = v_quote_asset_id;

    -- 4. Insert the order
    INSERT INTO orders (user_id, market_id, side, price, quantity, status)
    VALUES (p_user_id, p_market_id, 'BUY', p_price, p_quantity, 'OPEN')
    RETURNING order_id INTO v_new_order_id;

    RETURN v_new_order_id;
END;
$$;
```

Notes on the pattern:

- The `FOR UPDATE` at step 2 is what prevents two concurrent
  `place_limit_buy` calls from both seeing the same available balance
  (the lost-update bug from Scenario 1).
- The function has a single lock on the balance row and no other
  row-level lock, so by construction it cannot participate in the
  deadlock cycle of Scenario 3.
- A real matching engine would also lock and update the opposite side's
  resting orders and their balances. That introduces multi-row locking,
  at which point the consistent-ordering rule from Scenario 4 kicks in.
