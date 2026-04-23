

DROP FUNCTION IF EXISTS place_limit_buy(bigint, int, numeric, numeric);
DROP FUNCTION IF EXISTS place_limit_sell(bigint, int, numeric, numeric);

-- ---------------------------------------------------------------------------
-- place_limit_buy
-- ---------------------------------------------------------------------------
CREATE FUNCTION place_limit_buy(
    p_user_id    bigint,
    p_market_id  int,
    p_price      numeric,
    p_quantity   numeric
) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_quote_asset_id smallint;
    v_required       numeric(20,8);
    v_available      numeric(20,8);
    v_new_order_id   bigint;
BEGIN
    -- 1. Look up the quote asset of this market
    SELECT quote_asset_id INTO v_quote_asset_id
    FROM   markets
    WHERE  market_id = p_market_id;

    IF v_quote_asset_id IS NULL THEN
        RAISE EXCEPTION 'unknown market: %', p_market_id;
    END IF;

    v_required := p_price * p_quantity;

    -- 2. Lock the user's quote-asset balance row
    --    (FOR UPDATE prevents the lost-update anomaly, Scenario 2)
    SELECT available_amount INTO v_available
    FROM   balances
    WHERE  user_id = p_user_id AND asset_id = v_quote_asset_id
    FOR UPDATE;

    IF v_available IS NULL THEN
        RAISE EXCEPTION 'no balance row for user % asset %',
            p_user_id, v_quote_asset_id;
    END IF;

    IF v_available < v_required THEN
        RAISE EXCEPTION 'insufficient funds: need %, have %',
            v_required, v_available;
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


-- ---------------------------------------------------------------------------
-- place_limit_sell (symmetric)
-- ---------------------------------------------------------------------------
CREATE FUNCTION place_limit_sell(
    p_user_id    bigint,
    p_market_id  int,
    p_price      numeric,
    p_quantity   numeric
) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_base_asset_id smallint;
    v_available     numeric(20,8);
    v_new_order_id  bigint;
BEGIN
    SELECT base_asset_id INTO v_base_asset_id
    FROM   markets
    WHERE  market_id = p_market_id;

    IF v_base_asset_id IS NULL THEN
        RAISE EXCEPTION 'unknown market: %', p_market_id;
    END IF;

    SELECT available_amount INTO v_available
    FROM   balances
    WHERE  user_id = p_user_id AND asset_id = v_base_asset_id
    FOR UPDATE;

    IF v_available IS NULL THEN
        RAISE EXCEPTION 'no balance row for user % asset %',
            p_user_id, v_base_asset_id;
    END IF;

    IF v_available < p_quantity THEN
        RAISE EXCEPTION 'insufficient inventory: need %, have %',
            p_quantity, v_available;
    END IF;

    UPDATE balances
    SET    available_amount = available_amount - p_quantity,
           locked_amount    = locked_amount    + p_quantity
    WHERE  user_id = p_user_id AND asset_id = v_base_asset_id;

    INSERT INTO orders (user_id, market_id, side, price, quantity, status)
    VALUES (p_user_id, p_market_id, 'SELL', p_price, p_quantity, 'OPEN')
    RETURNING order_id INTO v_new_order_id;

    RETURN v_new_order_id;
END;
$$;


-- ---------------------------------------------------------------------------
-- Quick self-tests (will show in psql output after install)
-- ---------------------------------------------------------------------------
-- SELECT 'Functions installed. Try:' AS info
-- UNION ALL SELECT '  SELECT place_limit_buy(1, 1, 40000, 0.1);'
-- UNION ALL SELECT '  SELECT place_limit_sell(2, 2, 2500, 0.5);';
