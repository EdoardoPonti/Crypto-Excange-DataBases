"""
Validate the logic of place_limit_buy / place_limit_sell by re-implementing
them in Python over SQLite. This catches logic bugs in the SQL function
bodies BEFORE the live demo. Does not test PostgreSQL-specific features
(FOR UPDATE, concurrent sessions) — those require a real PostgreSQL server.
"""
import sqlite3
import sys
from pathlib import Path

HERE = Path(__file__).parent
VALIDATE_PY = HERE / "validate_sqlite.py"
SCHEMA = VALIDATE_PY.read_text()
# We only need the SQLite-adapted SCHEMA_SQL and SEED_SQL from validate_sqlite.py
# Extract them with naive scanning.
def extract(var_name: str) -> str:
    start_token = f'{var_name} = """'
    i = SCHEMA.index(start_token) + len(start_token)
    j = SCHEMA.index('"""', i)
    return SCHEMA[i:j]

SCHEMA_SQL = extract("SCHEMA_SQL")
SEED_SQL   = extract("SEED_SQL")


def place_limit_buy(cur, user_id, market_id, price, quantity):
    # Mirror of the PL/pgSQL logic
    row = cur.execute(
        "SELECT quote_asset_id FROM markets WHERE market_id = ?", (market_id,)
    ).fetchone()
    if not row:
        raise RuntimeError(f"unknown market: {market_id}")
    quote_asset_id = row[0]
    required = price * quantity

    bal = cur.execute(
        "SELECT available_amount FROM balances "
        "WHERE user_id = ? AND asset_id = ?",
        (user_id, quote_asset_id)
    ).fetchone()
    if not bal:
        raise RuntimeError(
            f"no balance row for user {user_id} asset {quote_asset_id}"
        )
    available = bal[0]
    if available < required:
        raise RuntimeError(
            f"insufficient funds: need {required}, have {available}"
        )

    cur.execute(
        "UPDATE balances "
        "SET available_amount = available_amount - ?, "
        "    locked_amount    = locked_amount    + ? "
        "WHERE user_id = ? AND asset_id = ?",
        (required, required, user_id, quote_asset_id)
    )
    cur.execute(
        "INSERT INTO orders (user_id, market_id, side, price, quantity, status) "
        "VALUES (?, ?, 'BUY', ?, ?, 'OPEN')",
        (user_id, market_id, price, quantity)
    )
    return cur.lastrowid


def place_limit_sell(cur, user_id, market_id, price, quantity):
    row = cur.execute(
        "SELECT base_asset_id FROM markets WHERE market_id = ?", (market_id,)
    ).fetchone()
    base_asset_id = row[0]

    bal = cur.execute(
        "SELECT available_amount FROM balances "
        "WHERE user_id = ? AND asset_id = ?",
        (user_id, base_asset_id)
    ).fetchone()
    if not bal:
        raise RuntimeError(
            f"no balance row for user {user_id} asset {base_asset_id}"
        )
    available = bal[0]
    if available < quantity:
        raise RuntimeError(
            f"insufficient inventory: need {quantity}, have {available}"
        )

    cur.execute(
        "UPDATE balances "
        "SET available_amount = available_amount - ?, "
        "    locked_amount    = locked_amount    + ? "
        "WHERE user_id = ? AND asset_id = ?",
        (quantity, quantity, user_id, base_asset_id)
    )
    cur.execute(
        "INSERT INTO orders (user_id, market_id, side, price, quantity, status) "
        "VALUES (?, ?, 'SELL', ?, ?, 'OPEN')",
        (user_id, market_id, price, quantity)
    )
    return cur.lastrowid


def run():
    conn = sqlite3.connect(":memory:")
    cur = conn.cursor()
    cur.executescript(SCHEMA_SQL)
    cur.executescript(SEED_SQL)
    conn.commit()

    print("=" * 60)

    # --- Happy path: Alice places a valid buy ---
    # Alice has 30k available USD. She buys 0.1 BTC @ 40k = 4k USD.
    alice_usd_before = cur.execute(
        "SELECT available_amount, locked_amount FROM balances "
        "WHERE user_id = 1 AND asset_id = 1"
    ).fetchone()
    oid = place_limit_buy(cur, user_id=1, market_id=1, price=40000, quantity=0.1)
    alice_usd_after = cur.execute(
        "SELECT available_amount, locked_amount FROM balances "
        "WHERE user_id = 1 AND asset_id = 1"
    ).fetchone()
    print(f"Alice USD before: {alice_usd_before}")
    print(f"Alice USD after : {alice_usd_after}")
    print(f"New order id    : {oid}")
    assert alice_usd_after == (alice_usd_before[0] - 4000,
                               alice_usd_before[1] + 4000), "balance math wrong"
    assert oid is not None
    print("happy-path buy OK\n")

    # --- Sad path: insufficient funds ---
    # Alice's USD available is now 26000. Try to buy 1 BTC @ 100k = 100k.
    try:
        place_limit_buy(cur, user_id=1, market_id=1, price=100000, quantity=1)
        print("FAIL: insufficient-funds check did not fire")
        return 1
    except RuntimeError as e:
        print(f"insufficient-funds rejected OK: {e}\n")

    # --- Sad path: no balance row for asset ---
    # Alice has no ETH balance row. Try to sell 1 ETH.
    try:
        place_limit_sell(cur, user_id=1, market_id=2, price=2500, quantity=1)
        print("FAIL: missing-balance-row check did not fire")
        return 1
    except RuntimeError as e:
        print(f"missing-balance rejected OK: {e}\n")

    # --- Happy path: Bob places a valid sell ---
    # Bob has 8 ETH available (row id 2,4). Sell 2 ETH @ 2500.
    bob_eth_before = cur.execute(
        "SELECT available_amount, locked_amount FROM balances "
        "WHERE user_id = 2 AND asset_id = 4"
    ).fetchone()
    oid = place_limit_sell(cur, user_id=2, market_id=2, price=2500, quantity=2)
    bob_eth_after = cur.execute(
        "SELECT available_amount, locked_amount FROM balances "
        "WHERE user_id = 2 AND asset_id = 4"
    ).fetchone()
    print(f"Bob ETH before: {bob_eth_before}")
    print(f"Bob ETH after : {bob_eth_after}")
    # Bob already had 1 ETH locked from seed (order 2 partial). Now +2 more.
    assert bob_eth_after == (bob_eth_before[0] - 2,
                             bob_eth_before[1] + 2)
    print("happy-path sell OK\n")

    print("=" * 60)
    print("ALL FUNCTION TESTS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(run())
