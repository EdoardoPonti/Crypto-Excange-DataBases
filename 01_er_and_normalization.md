# Project Scope — Exchange Simulator Database

## Purpose

This project implements a relational database for a simplified
cryptocurrency / asset exchange, as the graded deliverable for a Master 1
databases course. The exchange is the **domain** — a familiar setting that
naturally produces many-to-many relationships, integrity constraints, and
interesting queries. The **object of evaluation** is the database work
itself: ER modelling, normalisation, SQL, indexing, query optimisation, and
concurrency.

We deliberately do not try to build a production exchange. A separate
reference design (the "Hardening" document) describes what a production
system would look like; almost none of it is in our syllabus, and trying to
implement it would hide the course material behind infrastructure work.


## What the exchange does (domain)

Users hold balances in multiple assets (fiat and crypto). They can deposit
and withdraw assets, and they can place **limit orders** on **markets**
(ordered pairs of assets, e.g. `BTC/USD` means "price of BTC expressed in
USD"). The system matches compatible buy and sell orders, producing
**trades**. Each trade transfers quantity of the base asset from seller to
buyer, and (quantity × price) of the quote asset from buyer to seller.

An order that was resting on the book is the **maker**; the incoming order
that matches against it is the **taker**.


## Course topics demonstrated

| Topic                         | Where it appears                                   |
|-------------------------------|----------------------------------------------------|
| ER modelling                  | Layer 1 — full ER diagram, entity design           |
| Functional dependencies       | Layer 1 — FD list per relation, candidate keys     |
| Normalisation (3NF / BCNF)    | Layer 1 — decomposition of a naive design to 3NF   |
| Relational algebra            | Layer 3 — queries written as RA expressions + SQL  |
| SQL (DDL + DML)               | Layers 2–3 — constraints, complex queries          |
| Indexes (B-tree, hash)        | Layer 4 — chosen indexes with benchmarking         |
| Query optimisation            | Layer 4 — `EXPLAIN ANALYZE` before/after           |
| Locks, concurrency            | Layer 5 — lost updates, deadlocks, row locks       |


## In scope

- Single-node PostgreSQL (version ≥ 14)
- ER design, 3NF/BCNF schema, constraints enforced at the DB level
- Limit orders with maker/taker matching and partial fills
- Multi-asset user balances with `available` / `locked` split
- Deposits and withdrawals as explicit events with a status lifecycle
- A relational-algebra-backed query catalogue (Layer 3)
- Index tuning with before/after query plans (Layer 4)
- Transaction isolation demos — lost updates, deadlocks (Layer 5)


## Out of scope — deliberate, with justification

| Feature                                | Why excluded                                              |
|----------------------------------------|-----------------------------------------------------------|
| Distributed architecture, sharding     | Not in syllabus; single node is fine for our data scale   |
| Kafka, Debezium, CDC, outbox pattern   | Data engineering concern, not database theory             |
| External matching engine               | Matching implemented in PL/pgSQL or the app, to stay in domain |
| Blockchain-level custody modelling     | Deposits / withdrawals are abstract events                |
| KYC / AML / GDPR / Travel Rule         | Compliance domain, not DB theory                          |
| Time-series partitioning, retention    | Physical detail beyond our data volume                    |
| 18-decimal precision, lots/ticks split | `NUMERIC(20,8)` is adequate for us                        |
| Logical replication, HA standby, PITR  | Operations concern                                        |
| RLS, TLS, SCRAM, encryption at rest    | Security chapter is not in our syllabus                   |
| Monte Carlo simulation of order flow   | Quantitative finance research, not DB                     |

Each of these is a legitimate exchange concern; each is a project in itself.
Our goal is to stay inside the course and do it well.


## Target data volume

- **Seed dataset (Layer 2)** — ~5 users, 5 assets, 4 markets, 5 orders,
  1 trade, a handful of deposits/withdrawals. Hand-verifiable.
- **Benchmark dataset (Layer 4)** — ~1k users, ~100k orders, ~100k trades.
  Enough volume that the query planner picks non-trivial plans and indexes
  visibly change costs.
- **Concurrency dataset (Layer 5)** — small, crafted scenarios (two
  transactions racing on the same balance, etc.).


## Assumptions

1. Prices and quantities are stored as `NUMERIC(20,8)` — sufficient precision
   for an academic simulator and avoids floating-point error.
2. All timestamps are `TIMESTAMPTZ` (UTC).
3. Order matching uses **price-time priority**: best price first, older
   orders first at the same price.
4. The `maker` is whichever side was resting on the book; the incoming order
   is the `taker`.
5. Order status transitions: `OPEN → PARTIAL → FILLED`, or
   `OPEN | PARTIAL → CANCELLED`. Immutable fields (`side`, `price`,
   `quantity`) do not change after creation.
6. Deposits / withdrawals are events with a status; the mechanics of
   actually moving funds into/out of the exchange are abstracted away.


## Deliverables by layer

| Layer                          | Files                                          | Status     |
|--------------------------------|------------------------------------------------|------------|
| 0 — Scope                      | `docs/00_scope.md`                                  | ✅ this doc |
| 1 — ER + FDs + Normalisation   | `docs/01_er_and_normalization.md`                   | ✅ Layer 1  |
| 2 — DDL + Seed                 | `sql/01_schema.sql`, `sql/02_seed_small.sql`                 | ✅ Layer 2  |
| 3 — Query catalogue            | `docs/02_queries.md` (RA + SQL)                     | later      |
| 4 — Indexes + optimisation     | `05_indexing.md`, bench scripts                | later      |
| 5 — Concurrency                | `06_concurrency/` scripts                      | later      |
