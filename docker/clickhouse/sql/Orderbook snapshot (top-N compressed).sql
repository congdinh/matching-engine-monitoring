CREATE TABLE book_topn
(
  event_time DateTime64(3),
  symbol LowCardinality(String),
  bids Array(Tuple(Float64, Float64)),  -- [(price, qty), ...]
  asks Array(Tuple(Float64, Float64)),
  update_type LowCardinality(String),    -- 'snapshot'|'delta'
  metadata String
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (symbol, event_time)
TTL event_time + INTERVAL 30 DAY;