CREATE TABLE trades
(
  event_time DateTime64(3),
  symbol LowCardinality(String),
  trade_id UInt64,
  price Float64,
  quantity Float64,
  side Enum8('BUY' = 1, 'SELL' = 2),
  taker Boolean,
  order_id UInt64,
  metadata String
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (symbol, event_time)
TTL event_time + INTERVAL 30 DAY;
