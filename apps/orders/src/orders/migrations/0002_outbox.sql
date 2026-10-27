-- Transactional outbox: events are written in the same transaction as the order change and published to the
-- broker by a relay. published_at stays NULL until the broker has confirmed the message.

CREATE TABLE IF NOT EXISTS outbox_events (
    id            uuid        PRIMARY KEY,
    event_type    text        NOT NULL CHECK (event_type IN ('order.created', 'order.paid', 'order.failed')),
    aggregate_id  uuid        NOT NULL,
    payload       jsonb       NOT NULL,
    request_id    text,
    traceparent   text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    published_at  timestamptz,
    attempts      int         NOT NULL DEFAULT 0 CHECK (attempts >= 0)
);

-- The relay reads only unpublished rows, oldest first; a partial index keeps that cheap as history grows.
CREATE INDEX IF NOT EXISTS outbox_unpublished_idx ON outbox_events (created_at, id) WHERE published_at IS NULL;
