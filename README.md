# Exchange Simulator Database

A relational database that simulates a simplified limit-order
cryptocurrency/asset exchange, developed as the graded project for
the Databases course in the Master 1 programme at *École
Polytechnique*.

The **domain** — users depositing assets, placing limit orders on
markets, the system matching orders into trades — is a vehicle for
exercising the course material: ER modelling, functional
dependencies, normalisation, relational algebra, SQL, B-tree
indexing, query optimisation, and concurrency control. The *object
of evaluation* is the database work, not a production exchange. See
[`docs/00_scope.md`](docs/00_scope.md) for the full scope argument.


## Quick start

Requires **PostgreSQL ≥ 14** and **Python ≥ 3.10** (for tests only).

```bash
# Create a database
createdb exchange

# Load schema + small hand-verifiable seed
psql -d exchange -f sql/01_schema.sql
psql -d exchange -f sql/02_seed_small.sql

# Run the 11-query catalogue
psql -d exchange -f sql/queries.sql
```

That gives you a working database with 5 users, 5 assets, 4 markets,
5 orders and 1 trade, all arithmetically hand-checked (see the
comment block in `sql/02_seed_small.sql`).


## Repository structure

```
exchange-simulator-db/
├── README.md                       ← you are here
├── LICENSE                         MIT
├── sql/                            Runnable SQL, numbered by load order
│   ├── 01_schema.sql               tables, constraints, trade trigger
│   ├── 02_seed_small.sql           5 users / 5 orders / 1 trade (hand-checked)
│   ├── 03_seed_large.sql           500 users / 50k orders / 15k trades (for benchmarks)
│   ├── 04_indexes.sql              the indexes with one-line rationale each
│   ├── 05_demo_functions.sql       place_limit_buy / place_limit_sell PL/pgSQL
│   ├── queries.sql                 the 11 queries, runnable with \echo markers
│   └── concurrency_sessions.sql    two-session scripts for the concurrency demos
├── docs/                           Prose writeups of each layer
│   ├── 00_scope.md                 what's in, what's out, why
│   ├── 01_er_and_normalization.md  ER diagram, FDs, 3NF decomposition
│   ├── 02_queries.md               queries with RA expressions + SQL + expected output
│   ├── 03_indexing.md              index benchmarks with EXPLAIN ANALYZE plans
│   └── 04_concurrency.md           lost update, deadlock, isolation levels
├── presentation/                   For the Friday presentation
│   ├── presentation.pdf            compiled slides (11 slides, Beamer)
│   ├── presentation.tex            source
│   ├── speaker_notes.md            what to say per slide, timings, Q&A
│   ├── demo_script.md              narrated live demo (S1, S2, S3)
│   └── demo_cheatsheet.txt         paste-ready command blocks for the demo
└── tests/                          Automated validation
    ├── validate_sqlite.py          translates schema to SQLite, runs all 11 queries
    └── validate_demo_functions.py  re-implements place_limit_buy in Python, tests logic
```


## The six project layers

The project was built up in six layers. Each numbered `sql/` and
`docs/` file corresponds to one.

| Layer | Topic                         | SQL                          | Prose writeup                         |
|-------|-------------------------------|------------------------------|---------------------------------------|
| 0     | Scope                         | —                            | `docs/00_scope.md`                    |
| 1     | ER + FDs + Normalisation      | —                            | `docs/01_er_and_normalization.md`     |
| 2     | Schema + small seed           | `sql/01_schema.sql`, `sql/02_seed_small.sql` | (included in Layer 1) |
| 3     | Relational algebra + SQL      | `sql/queries.sql`            | `docs/02_queries.md`                  |
| 4     | Indexes + query optimisation  | `sql/03_seed_large.sql`, `sql/04_indexes.sql` | `docs/03_indexing.md` |
| 5     | Concurrency                   | `sql/concurrency_sessions.sql`, `sql/05_demo_functions.sql` | `docs/04_concurrency.md` |


## Running the full workflow

### 1. Small hand-verifiable dataset (default)

```bash
createdb exchange
psql -d exchange -f sql/01_schema.sql
psql -d exchange -f sql/02_seed_small.sql
psql -d exchange -f sql/05_demo_functions.sql     # PL/pgSQL helpers
psql -d exchange -f sql/queries.sql                # runs all 11 queries
```

### 2. Benchmark dataset (for the indexing layer)

The benchmark dataset has ~50 000 orders and ~15 000 trades — enough
for the planner to make interesting decisions. It **replaces** the
small seed; run it against a schema-only database.

```bash
psql -d exchange -f sql/01_schema.sql
psql -d exchange -f sql/03_seed_large.sql   # ~30 sec on a laptop
# now run any query from queries.sql with EXPLAIN ANALYZE,
# then load the indexes and re-run
psql -d exchange -f sql/04_indexes.sql
```

See [`docs/03_indexing.md`](docs/03_indexing.md) for the four
benchmarks with before/after plan shapes and what each index does.

### 3. Concurrency scenarios (needs two psql sessions)

Open two `psql` windows connected to the same database. Follow
[`docs/04_concurrency.md`](docs/04_concurrency.md) — it walks
through lost update, `FOR UPDATE`, deadlock, and consistent lock
ordering with exact timing markers (`t=1`, `t=2`, …).

Before running, reset to the small seed:

```bash
psql -d exchange -f sql/02_seed_small.sql
```


## User scenarios (demonstrated in the live demo)

The demo on [presentation day](presentation/demo_script.md) walks
through three scenarios that exercise the concurrency machinery:

| Scenario | Challenge                                                   | Database technique                                |
|----------|-------------------------------------------------------------|---------------------------------------------------|
| **S1**   | Alice places a buy order — prevent overspending             | `available`/`locked` split + `FOR UPDATE` in `place_limit_buy` |
| **S2**   | Two concurrent trades debit the same account — prevent lost update | Row-level `SELECT … FOR UPDATE` on balance rows |
| **S3**   | Two transfers lock two accounts — prevent deadlock          | Consistent lock ordering via `ORDER BY` in `FOR UPDATE` |


## Testing

The project includes two Python test harnesses that validate
correctness without needing PostgreSQL, by translating the schema to
SQLite:

```bash
python3 tests/validate_sqlite.py          # schema + all 11 queries
python3 tests/validate_demo_functions.py  # place_limit_buy/sell logic
```

Both should print `ALL CHECKS PASSED` / `ALL FUNCTION TESTS
PASSED`. No dependencies outside the Python standard library.

**What these tests do not cover** (they require real PostgreSQL):

- `sql/03_seed_large.sql` — uses PostgreSQL-only `generate_series`,
  `random()`, `setseed()`.
- `sql/04_indexes.sql` — the indexes are syntactically valid, but
  their effect on query plans can only be measured with
  `EXPLAIN ANALYZE` on PostgreSQL.
- Concurrency demos (`sql/concurrency_sessions.sql`) — need two
  actual sessions, which SQLite doesn't support.


## What this project deliberately is *not*

The domain we chose (a cryptocurrency exchange) has a huge amount of
production complexity that is **out of scope** for this course:

- external matching engine / deterministic sharding
- Kafka / Debezium / CDC / transactional outbox
- blockchain custody modelling, deposit reorg handling
- KYC / AML / FATF Travel Rule / GDPR retention
- time-series partitioning, hot/warm/archive tiers
- HA standby, PITR, logical replication
- TLS / SCRAM / RLS / envelope encryption
- Monte Carlo order-flow simulation

None of these are on our syllabus; implementing any of them would
hide the course material behind infrastructure. We were given a
"hardening" document covering all of the above and explicitly scoped
it out — see [`docs/00_scope.md`](docs/00_scope.md) for the full
list with justifications.

**One feature worth adding if there were time:** a double-entry
ledger with a zero-sum trigger. It's the one item from the
hardening document that legitimately fits an intro DB project —
header + detail tables + a `CHECK` enforcing that postings sum to
zero per asset. It's mentioned in `docs/04_concurrency.md` and
could be a Layer 7 in a future version.


## Authors

- **Edoardo Ponti**
- **Amirhoussein Raufi**

Submitted for the Databases course, Master 1 in Applied Mathematics
and Statistics, École Polytechnique, Spring 2026.


## License

MIT — see [`LICENSE`](LICENSE).
