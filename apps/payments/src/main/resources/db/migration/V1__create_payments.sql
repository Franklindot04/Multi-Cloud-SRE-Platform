-- Simulated payment authorizations. Money is an integer in minor units, identifiers are UUIDs and
-- timestamps are stored in UTC. The unique idempotency key makes a replay of the same request return
-- the stored decision instead of creating a second payment.
CREATE TABLE payments (
    id               uuid PRIMARY KEY,
    idempotency_key  text        NOT NULL,
    request_hash     text        NOT NULL,
    order_id         text        NOT NULL,
    amount_minor     bigint      NOT NULL,
    currency         char(3)     NOT NULL,
    status           text        NOT NULL,
    decline_reason   text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT payments_idempotency_key_uniq UNIQUE (idempotency_key),
    CONSTRAINT payments_amount_positive CHECK (amount_minor > 0),
    CONSTRAINT payments_currency_format CHECK (currency ~ '^[A-Z]{3}$'),
    CONSTRAINT payments_status_valid CHECK (status IN ('approved', 'declined')),
    CONSTRAINT payments_decline_reason_matches CHECK ((status = 'declined') = (decline_reason IS NOT NULL))
);

CREATE INDEX payments_order_id_idx ON payments (order_id);
