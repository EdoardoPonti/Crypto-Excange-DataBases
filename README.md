# Exchange Simulator Database

A relational database that simulates a simplified limit-order
cryptocurrency / asset exchange, developed as the graded project
for the Databases course in the Master 1 programme at *École
Polytechnique*.

The **domain** — users depositing assets, placing limit orders on
markets, the system matching orders into trades — is a vehicle for
exercising the course material: ER modelling, functional
dependencies, normalisation, relational algebra, SQL, B-tree
indexing, query optimisation, and concurrency control. The object
of evaluation is the database work, not a production exchange. See
[`docs/00_scope.md`](docs/00_scope.md) for the full scope argument.


## Quick start

Requires **PostgreSQL ≥ 14** and **Python ≥ 3.10** (for tests only).

```bash
# Create a database
createdb exchange

# Load schema and the small hand-verifiable seed
psql -d exchange -f sql/01_schema.sql
psql -d exchange -f sql/02_seed_small.sql

# Run all 11 queries with section markers
psql -d exchange -f sql/queries.sql
```

That gives you a working database with 5 users, 5 assets, 4 markets,
5 orders and 1 trade. The arithmetic for every row in every table is
hand-checked in the comment block of
[`sql/02_seed_small.sql`](sql/02_seed_small.sql).


## Repository contents — every file

```
exchange-simulator-db/
├── README.md                                ← this file
├── LICENSE                                  MIT
├── .gitignore
│
├── sql/                                     runnable SQL, numbered by load order
│   ├── 01_schema.sql                          tables, constraints, trade trigger
│   ├── 02_seed_small.sql                      5 users / 5 orders / 1 trade
│   ├── 03_seed_large.sql                      500 users / 50k orders / 15k trades
│   ├── 04_indexes.sql                         indexes + one-line rationale each
│   ├── 05_demo_functions.sql                  place_limit_buy / place_limit_sell
│   ├── queries.sql                            all 11 queries, runnable
│   └── concurrency_sessions.sql               two-session scripts for Layer 5
│
├── docs/                                    prose writeups of each project layer
│   ├── 00_scope.md                            what's in, what's out, why
│   ├── 01_er_and_normalization.md             ER diagram, FDs, 3NF decomposition
│   ├── 02_queries.md                          queries with RA expressions and expected output
│   ├── 03_indexing.md                         benchmarks with EXPLAIN ANALYZE plans
│   └── 04_concurrency.md                      lost update, deadlock, isolation levels
│
├── presentation/                            everything for the Friday presentation
│   ├── presentation.pdf                       compiled Beamer slides, 11 pages
│   ├── presentation.tex                       LaTeX source for the slides
│   ├── speaker_notes.md                       per-slide talking points, timings, Q&A
│   ├── demo_script.md                         narrated live demo walkthrough
│   └── demo_cheatsheet.txt                    paste-ready commands for the demo
│
└── tests/                                   automated validation (Python + SQLite)
    ├── validate_sqlite.py                     schema + all 11 queries
    └── validate_demo_functions.py             place_limit_buy/sell logic
```

That's **22 files** in total across **4 subfolders**. If any of
these are missing from the GitHub repo, the upload was incomplete —
GitHub's web drag-and-drop silently skips subfolders.


## The six project layers

Each numbered file corresponds to one layer of work.

| Layer | Topic                        | SQL                                                               | Prose                                                     |
|-------|------------------------------|-------------------------------------------------------------------|-----------------------------------------------------------|
| 0     | Scope                        | —                                                                 | [`docs/00_scope.md`](docs/00_scope.md)                    |
| 1     | ER, FDs, Normalisation       | —                                                                 | [`docs/01_er_and_normalization.md`](docs/01_er_and_normalization.md) |
| 2     | Schema and small seed        | [`sql/01_schema.sql`](sql/01_schema.sql), [`sql/02_seed_small.sql`](sql/02_seed_small.sql) | included in Layer 1                                       |
| 3     | Relational algebra and SQL   | [`sql/queries.sql`](sql/queries.sql)                              | [`docs/02_queries.md`](docs/02_queries.md)                |
| 4     | Indexes, query optimisation  | [`sql/03_seed_large.sql`](sql/03_seed_large.sql), [`sql/04_indexes.sql`](sql/04_indexes.sql) | [`docs/03_indexing.md`](docs/03_indexing.md)              |
| 5     | Concurrency                  | [`sql/concurrency_sessions.sql`](sql/concurrency_sessions.sql), [`sql/05_demo_functions.sql`](sql/05_demo_functions.sql) | [`docs/04_concurrency.md`](docs/04_concurrency.md)        |


## Running the full workflow

### 1. Small hand-verifiable dataset (default)

```bash
createdb exchange
psql -d exchange -f sql/01_schema.sql
psql -d exchange -f sql/02_seed_small.sql
psql -d exchange -f sql/05_demo_functions.sql
psql -d exchange -f sql/queries.sql
```

### 2. Benchmark dataset (for the indexing layer)

The benchmark dataset has ~50 000 orders and ~15 000 trades — enough
for the planner to make interesting decisions. It **replaces** the
small seed; run it against a schema-only database.

```bash
psql -d exchange -f sql/01_schema.sql
psql -d exchange -f sql/03_seed_large.sql

# Run any query from queries.sql with EXPLAIN ANALYZE before indexing,
# then load the indexes and rerun it to see the plan change
psql -d exchange -f sql/04_indexes.sql
```

See [`docs/03_indexing.md`](docs/03_indexing.md) for the four
benchmarks, before and after plan shapes, and a rationale per index.

### 3. Concurrency scenarios (needs two psql sessions)

Open two `psql` windows connected to the same database. Follow
[`docs/04_concurrency.md`](docs/04_concurrency.md), which walks
through lost update, `FOR UPDATE`, deadlock, and consistent lock
ordering with exact timing markers. Reset to the small seed between
scenarios:

```bash
psql -d exchange -f sql/02_seed_small.sql
```


## User scenarios (demonstrated in the live demo)

The demo walks through three scenarios that exercise the
concurrency and integrity machinery. Full narration is in
[`presentation/demo_script.md`](presentation/demo_script.md);
paste-ready commands are in
[`presentation/demo_cheatsheet.txt`](presentation/demo_cheatsheet.txt).

| Scenario | Challenge                                                    | Database technique                                                 |
|----------|--------------------------------------------------------------|--------------------------------------------------------------------|
| **S1**   | Alice places a buy order — prevent overspending              | `available` / `locked` split + `FOR UPDATE` in `place_limit_buy`   |
| **S2**   | Two concurrent trades debit the same account                 | Row-level `SELECT … FOR UPDATE` on balance rows                    |
| **S3**   | Two transfers lock two accounts — prevent deadlock           | Consistent lock ordering via `ORDER BY` in `FOR UPDATE`            |


## Testing

Two Python test harnesses validate correctness without needing
PostgreSQL, by translating the schema to SQLite:

```bash
python3 tests/validate_sqlite.py
python3 tests/validate_demo_functions.py
```

Both should print `ALL CHECKS PASSED` / `ALL FUNCTION TESTS
PASSED`. No dependencies outside the Python standard library.

**What these tests do not cover** (they require real PostgreSQL):

- [`sql/03_seed_large.sql`](sql/03_seed_large.sql) uses
  PostgreSQL-only `generate_series`, `random()`, `setseed()`.
- [`sql/04_indexes.sql`](sql/04_indexes.sql) is syntactically
  valid; its effect on query plans requires `EXPLAIN ANALYZE` on
  PostgreSQL.
- Concurrency demos in
  [`sql/concurrency_sessions.sql`](sql/concurrency_sessions.sql)
  need two real sessions.



## Authors

- **Edoardo Ponti**
- **Amirhoussein Raufi**

Submitted for the Databases course, Master 1 in Applied Mathematics
and Statistics, École Polytechnique, Spring 2026.


## License

MIT — see [`LICENSE`](LICENSE).
