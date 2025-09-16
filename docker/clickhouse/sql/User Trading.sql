CREATE TABLE user_orders
(
  event_time DateTime64(3),
  user_id UInt64,
  order_id UInt64,
  symbol LowCardinality(String),
  side Enum8('BUY'=1,'SELL'=2),
  type LowCardinality(String),
  price Float64,
  quantity Float64,
  filled_quantity Float64,
  status LowCardinality(String),
  metadata String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time)
TTL event_time + INTERVAL 30 DAY;
