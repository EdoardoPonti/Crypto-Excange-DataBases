

-- ############################################################################
-- SCENARIO 1 — Lost update (bug demo under READ COMMITTED)
-- Expected:   final available_amount = 10000
-- Actual:     final available_amount = 20000   ← LOST UPDATE
-- ############################################################################

-- ---------- Session A, t=1 ----------
BEGIN;
SELECT available_amount FROM balances
WHERE  user_id = 1 AND asset_id = 1;
-- => 30000

-- ---------- Session B, t=2 ----------
BEGIN;
SELECT available_amount FROM balances
WHERE  user_id = 1 AND asset_id = 1;
-- => 30000

-- ---------- Session A, t=3 ----------
UPDATE balances SET available_amount = 30000 - 10000
WHERE  user_id = 1 AND asset_id = 1;
COMMIT;

-- ---------- Session B, t=4 ----------
UPDATE balances SET available_amount = 30000 - 10000   -- based on stale read
WHERE  user_id = 1 AND asset_id = 1;
COMMIT;

-- ---------- Either session ----------
SELECT available_amount FROM balances WHERE user_id=1 AND asset_id=1;
-- 20000 (BUG — should be 10000)


-- ############################################################################
-- SCENARIO 2 — Fix with SELECT ... FOR UPDATE
-- Expected:   final available_amount = 10000  ✓
-- Reset with 03_seed.sql first.
-- ############################################################################

-- ---------- Session A, t=1 ----------
BEGIN;
SELECT available_amount FROM balances
WHERE  user_id = 1 AND asset_id = 1
FOR UPDATE;
-- => 30000, row lock acquired

-- ---------- Session B, t=2 ----------
BEGIN;
SELECT available_amount FROM balances
WHERE  user_id = 1 AND asset_id = 1
FOR UPDATE;
-- BLOCKS until A commits/rolls back

-- ---------- Session A, t=3 ----------
UPDATE balances SET available_amount = 30000 - 10000
WHERE  user_id = 1 AND asset_id = 1;
COMMIT;
-- A releases its lock. B's t=2 query unblocks and returns 20000.

-- ---------- Session B, t=4 ----------
UPDATE balances SET available_amount = 20000 - 10000  -- fresh read
WHERE  user_id = 1 AND asset_id = 1;
COMMIT;

-- ---------- Either session ----------
SELECT available_amount FROM balances WHERE user_id=1 AND asset_id=1;
-- 10000  ✓


-- ############################################################################
-- SCENARIO 3 — Deadlock from inconsistent lock ordering
-- Expected:   one of the sessions gets "ERROR: deadlock detected"
-- Reset with 03_seed.sql first.
-- ############################################################################

-- ---------- Session A, t=1 ----------
BEGIN;
SELECT available_amount FROM balances
WHERE  user_id = 1 AND asset_id = 1       -- alice
FOR UPDATE;

-- ---------- Session B, t=2 ----------
BEGIN;
SELECT available_amount FROM balances
WHERE  user_id = 2 AND asset_id = 1       -- bob
FOR UPDATE;

-- ---------- Session A, t=3 ----------
SELECT available_amount FROM balances
WHERE  user_id = 2 AND asset_id = 1       -- wants bob, B has it
FOR UPDATE;
-- BLOCKS

-- ---------- Session B, t=4 ----------
SELECT available_amount FROM balances
WHERE  user_id = 1 AND asset_id = 1       -- wants alice, A has it
FOR UPDATE;
-- After deadlock_timeout (default 1s), PostgreSQL detects the cycle and
-- aborts ONE of the two sessions with:
--   ERROR:  deadlock detected

-- ---------- Both sessions ----------
-- The survivor proceeds; the victim's transaction is rolled back and must
-- be retried by the application.
ROLLBACK;


-- ############################################################################
-- SCENARIO 4 — No deadlock with consistent lock ordering
-- Rule: always lock the lower user_id first.
-- Reset with 03_seed.sql first.
-- ############################################################################

-- ---------- Session A, t=1 ----------
BEGIN;
SELECT available_amount FROM balances
WHERE  user_id = 1 AND asset_id = 1       -- alice FIRST (lower id)
FOR UPDATE;

-- ---------- Session B, t=2 ----------
BEGIN;
SELECT available_amount FROM balances
WHERE  user_id = 1 AND asset_id = 1       -- alice FIRST too
FOR UPDATE;
-- BLOCKS (waits for A)

-- ---------- Session A, t=3 ----------
SELECT available_amount FROM balances
WHERE  user_id = 2 AND asset_id = 1       -- now bob
FOR UPDATE;
-- OK

-- ---------- Session A, t=4 ----------
UPDATE balances SET available_amount = available_amount - 1000
WHERE  user_id = 1 AND asset_id = 1;
UPDATE balances SET available_amount = available_amount + 1000
WHERE  user_id = 2 AND asset_id = 1;
COMMIT;
-- A commits, releases locks. B's t=2 query unblocks.

-- ---------- Session B, t=5 ----------
-- (B's t=2 SELECT now returns alice's post-A balance)
SELECT available_amount FROM balances
WHERE  user_id = 2 AND asset_id = 1       -- now bob
FOR UPDATE;

UPDATE balances SET available_amount = available_amount + 500
WHERE  user_id = 1 AND asset_id = 1;
UPDATE balances SET available_amount = available_amount - 500
WHERE  user_id = 2 AND asset_id = 1;
COMMIT;

-- Both transfers completed, serialised by first-lock convention. No
-- deadlock.


-- ############################################################################
-- SCENARIO 5 — Isolation levels: non-repeatable read demo
-- Reset with 03_seed.sql first.
-- ############################################################################

-- -------- Part A: default READ COMMITTED shows non-repeatable reads --------

-- ---------- Session A, t=1 ----------
BEGIN;  -- default READ COMMITTED
SELECT available_amount FROM balances WHERE user_id=1 AND asset_id=1;
-- => 30000

-- ---------- Session B, t=2 ----------
BEGIN;
UPDATE balances SET available_amount = 25000
WHERE  user_id = 1 AND asset_id = 1;
COMMIT;

-- ---------- Session A, t=3 ----------
SELECT available_amount FROM balances WHERE user_id=1 AND asset_id=1;
-- => 25000   ← CHANGED under A's feet
COMMIT;

-- -------- Part B: REPEATABLE READ gives A a stable snapshot --------
-- Reset with 03_seed.sql first.

-- ---------- Session A, t=1 ----------
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT available_amount FROM balances WHERE user_id=1 AND asset_id=1;
-- => 30000

-- ---------- Session B, t=2 ----------
BEGIN;
UPDATE balances SET available_amount = 25000
WHERE  user_id = 1 AND asset_id = 1;
COMMIT;

-- ---------- Session A, t=3 ----------
SELECT available_amount FROM balances WHERE user_id=1 AND asset_id=1;
-- => 30000   ← A still sees its snapshot; B's update is invisible here
COMMIT;

-- Verify the final persisted state:
SELECT available_amount FROM balances WHERE user_id=1 AND asset_id=1;
-- => 25000  (B's update is durable; A just couldn't see it until commit)
