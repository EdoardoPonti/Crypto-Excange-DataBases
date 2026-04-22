# Exchange Simulator Database

This is our project for the Databases course, Master 1 in Applied
Mathematics and Statistics at École Polytechnique. We built a
relational database that simulates a limit-order exchange: users
deposit assets, place buy or sell orders on a market, and the
system matches compatible orders into trades.

We picked this domain because it naturally produces most of the
things the course asked us to work with: foreign keys that point
twice to the same table, normalization decisions that are not
obvious, queries that use the full range of relational algebra,
concurrent transactions that can step on each other, and indexes
that genuinely matter for performance.

The point of the project is the database, not a working exchange.
We did not build a matching engine, a web UI, or anything that
would let a real trader use this.

## What's in the repo

There are three folders and a handful of top-level files.

`sql/` holds everything that runs against the database:

- `01_schema.sql` creates the tables, the constraints, and the
  trigger that validates trades.
- `02_seed_small.sql` loads a tiny dataset (5 users, 5 orders, 1
  trade) that you can check by hand.
- `03_seed_large.sql` loads a bigger dataset (500 users, ~50k
  orders, ~15k trades) that we used for the indexing benchmarks.
- `04_indexes.sql` adds the indexes we chose, with a short comment
  per index explaining why.
- `05_demo_functions.sql` defines two PL/pgSQL functions,
  `place_limit_buy` and `place_limit_sell`, that we call during
  the live demo.
- `queries.sql` runs all 11 queries from Layer 3 in order.
- `concurrency_sessions.sql` has the two-session scripts for the
  concurrency scenarios.

`docs/` has the writeups:

- `00_scope.md` — what we decided to include and what we left out.
- `01_er_and_normalization.md` — the ER diagram, the functional
  dependencies, and the one 3NF decomposition we did.
- `02_queries.md` — each query shown as a relational-algebra
  expression and then as SQL, with the expected output on the
  small seed.
- `03_indexing.md` — four indexing benchmarks, before and after,
  with a short commentary on each.
- `04_concurrency.md` — lost update, row locks, deadlock, lock
  ordering, and a short note on isolation levels.

`tests/` has two Python scripts that validate the schema and the
queries against a SQLite-translated copy of the database, so we
could catch bugs without needing PostgreSQL running:

- `validate_sqlite.py` — loads the schema, seeds it, runs all 11
  queries, checks each result against what we expected.
- `validate_demo_functions.py` — reimplements `place_limit_buy`
  and `place_limit_sell` in Python and tests the happy and sad
  paths.

At the root: `presentation.pdf` (the slides we used on April 24),
`LICENSE` (MIT), and this README.

## Running it

You need PostgreSQL 14 or later. Python 3.10+ only if you want to
run the tests.

```bash
createdb exchange

psql -d exchange -f sql/01_schema.sql
psql -d exchange -f sql/02_seed_small.sql
psql -d exchange -f sql/05_demo_functions.sql
psql -d exchange -f sql/queries.sql
```

That gets you the small seed and runs all 11 queries. The output
of `queries.sql` has `\echo` markers so you can find each query's
result in the scroll.

For the indexing benchmarks, start fresh and load the large seed
instead:

```bash
createdb exchange
psql -d exchange -f sql/01_schema.sql
psql -d exchange -f sql/03_seed_large.sql
```

Then pick a query from `queries.sql`, run it with `EXPLAIN
(ANALYZE, BUFFERS)`, apply `04_indexes.sql`, and run it again. The
plan shapes and the before/after timings we saw are written up in
`docs/03_indexing.md`.

For the concurrency scenarios you need two `psql` sessions open at
the same time. Reset to the small seed between runs. The exact
commands, with time markers, are in `docs/04_concurrency.md`.

## Running the tests

From the repo root:

```bash
python3 tests/validate_sqlite.py
python3 tests/validate_demo_functions.py
```

Both should end with `ALL CHECKS PASSED` or `ALL FUNCTION TESTS
PASSED`. They only need the Python standard library. They don't
replace real PostgreSQL testing — they don't run the large seed,
they don't test indexes, and they can't simulate two sessions —
but they cover the schema, the 11 queries, and the function logic.

## User scenarios

There are three scenarios we use to frame the concurrency part of
the project. They are also the spine of our live demo.

**S1** is about placing an order. When a user places a buy, how do
we stop her from spending money she doesn't have, especially if
she has other orders already sitting on the book? Our answer: a
balance is split into `available` and `locked`, and `place_limit_buy`
moves funds from one to the other inside a transaction that has
`SELECT ... FOR UPDATE` on the balance row.

**S2** is the classic lost update. Two transactions both debit the
same balance at the same time. Without row locking, one of the
debits disappears. With `FOR UPDATE`, the second transaction waits
for the first one and reads the fresh value after the commit.

**S3** is deadlock. Two transactions each need to lock two rows.
If they try to acquire the rows in opposite order you get a cycle
and Postgres kills one of them. The fix is not to create the cycle
in the first place: always acquire locks in the same canonical
order, which we do with `ORDER BY user_id` inside the `FOR UPDATE`.

The full walkthrough of each scenario, including the exact SQL and
the expected session transcripts, is in `docs/04_concurrency.md`.

## What we deliberately left out

A real crypto exchange has a lot of moving parts that this project
does not even try to address: an external matching engine, event
streaming to Kafka or similar, blockchain custody modelling,
compliance data (KYC, AML, Travel Rule), GDPR retention policies,
HA replication and PITR backups, row-level security, TLS
everywhere, and quantitative simulation of order flow. We were
given a reference document from an industry-style "hardening"
review that covered all of that, and we explicitly scoped it out.
The reason is that almost none of it exercises course material.
Trying to implement any of it would have meant less time on the
parts the course actually tests.

The one piece from that document that would fit here but which we
did not build is a double-entry ledger with a zero-sum trigger. A
header table, a detail table, and a deferred constraint that
forces postings to sum to zero per asset per entry. It would be a
clean Layer 6 for a later version.

## Authors

Edoardo Ponti and Amirhoussein Raufi.


