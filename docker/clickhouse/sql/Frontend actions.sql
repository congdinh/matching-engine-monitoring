CREATE TABLE frontend_actions
(
  event_time DateTime64(3),
  session_id String,
  user_id UInt64,
  event_type LowCardinality(String),
  element String,
  properties String, -- json
  metadata String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (session_id, event_time)
TTL event_time + INTERVAL 30 DAY;
