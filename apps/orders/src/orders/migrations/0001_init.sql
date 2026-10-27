-- Orders, their items and the idempotency keys. Forward-only: never edit an applied migration, add a new one.

CREATE TABLE IF NOT EXISTS orders (
    id              uuid PRIMARY KEY,
    customer_id     text        NOT NULL CHECK (length(customer_id) BETWEEN 1 AND 64),
    currency        char(3)     NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    total_minor     bigint      NOT NULL CHECK (total_minor >= 0),
    status          text        NOT NULL CHECK (status IN ('pending', 'paid', 'failed')),
    payment_id      text,
    failure_reason  text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

-- Serves GET /orders: newest first, with a stable tie-break for paging.
CREATE INDEX IF NOT EXISTS orders_created_at_id_idx ON orders (created_at DESC, id DESC);

CREATE TABLE IF NOT EXISTS order_items (
    order_id          uuid   NOT NULL REFERENCES orders (id) ON DELETE CASCADE,
    position          int    NOT NULL CHECK (position >= 0),
    sku               text   NOT NULL CHECK (length(sku) BETWEEN 1 AND 64),
    quantity          int    NOT NULL CHECK (quantity > 0),
    unit_price_minor  bigint NOT NULL CHECK (unit_price_minor >= 0),
    PRIMARY KEY (order_id, position)
);

-- One row per Idempotency-Key. The primary key makes creation atomic: concurrent requests with the same key
-- cannot both insert. The order reference is deferred so the key can be claimed before the order row exists
-- in the same transaction.
CREATE TABLE IF NOT EXISTS idempotency_keys (
    key           text        PRIMARY KEY CHECK (length(key) BETWEEN 1 AND 128),
    request_hash  text        NOT NULL,
    order_id      uuid        NOT NULL REFERENCES orders (id) DEFERRABLE INITIALLY DEFERRED,
    created_at    timestamptz NOT NULL DEFAULT now()
);
