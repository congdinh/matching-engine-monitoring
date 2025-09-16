CREATE TABLE social_buzz
(
  event_time DateTime64(3),
  symbol LowCardinality(String),         -- token symbol or null
  source LowCardinality(String),         -- twitter, reddit, news, telegram
  language LowCardinality(String),
  text String,
  sentiment_score Float32,               -- normalized [-1..1]
  sentiment_label LowCardinality(String),-- negative/neutral/positive
  tokens_count UInt32,
  embedding Array(Float32) DEFAULT [],   -- optional; be careful size
  metadata String                         -- raw json
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (symbol, event_time)
TTL event_time + INTERVAL 30 DAY;


-- Kafka engine table social sentiment
CREATE TABLE IF NOT EXISTS kafka_social
(
    source LowCardinality(String),              -- nguồn (X, Telegram, News, Reddit...)
    token_symbol LowCardinality(String),        -- token liên quan
    event_time DateTime,                        -- thời gian event
    text String,                                -- nội dung raw (đã qua preprocessing)
    sentiment_score Float32,                    -- điểm sentiment (-1..1)
    sentiment_label Enum8('NEG' = -1, 'NEU' = 0, 'POS' = 1), -- nhãn sentiment
    buzz Int32                                  -- số lần buzz hoặc weight (optional)
)
ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'kafka:9092',          -- chỉnh broker của bạn
    kafka_topic_list = 'social_processed',     -- topic Kafka chứa dữ liệu sentiment
    kafka_group_name = 'risk_social_consumer',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 1;

-- Storage table cho social sentiment
CREATE TABLE IF NOT EXISTS social_sentiment
(
    source LowCardinality(String),
    token_symbol LowCardinality(String),
    event_time DateTime,
    text String CODEC(ZSTD(3)),
    sentiment_score Float32 CODEC(Delta, ZSTD(1)),
    sentiment_label Enum8('NEG' = -1, 'NEU' = 0, 'POS' = 1),
    buzz Int32 CODEC(ZSTD(1))
)
ENGINE = MergeTree()
PARTITION BY toYYYYMMDD(event_time)
ORDER BY (token_symbol, event_time)
TTL event_time + INTERVAL 30 DAY
SETTINGS index_granularity = 4096;

-- Materialized View: đẩy từ Kafka engine sang bảng MergeTree
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_social_sentiment
TO social_sentiment
AS
SELECT
    source,
    token_symbol,
    event_time,
    text,
    sentiment_score,
    sentiment_label,
    buzz
FROM kafka_social;
