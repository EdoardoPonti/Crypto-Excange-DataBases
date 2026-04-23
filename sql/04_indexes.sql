CREATE INDEX idx_orders_book
    ON orders (market_id, side, status, price);


CREATE INDEX idx_orders_user
    ON orders (user_id);

CREATE INDEX idx_trades_maker_order
    ON trades (maker_order_id);

CREATE INDEX idx_trades_taker_order
    ON trades (taker_order_id);



CREATE INDEX idx_trades_executed_at
    ON trades (executed_at);



CREATE INDEX idx_orders_open
    ON orders (market_id, side, price)
 WHERE status IN ('OPEN', 'PARTIAL');


