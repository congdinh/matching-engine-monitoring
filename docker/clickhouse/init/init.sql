-- Check kafka consumers
-- SELECT *
-- FROM system.kafka_consumers
-- WHERE table = 'kafka_orders';
-- Check errors
-- SELECT *
-- FROM system.errors
-- WHERE name LIKE '%Kafka%';
-- Check if stream_like_engine_allow_direct_select is enabled
-- SET stream_like_engine_allow_direct_select = 1;
-- Check data from kafka_orders
-- SELECT *
-- FROM kafka_orders
-- LIMIT 10;
-- Create the Kafka engine table to consume from the Kafka topics
CREATE TABLE
  kafka_consumer_orders (
    `engineAction` Nullable (String),
    `engineAmount` Float64,
    `engineFunds` Float64,
    `enginePrice` Float64,
    `engineSide` String,
    `engineStop` String,
    `engineStopPrice` Float64,
    `engineType` String,
    `fee` Float64,
    `feeAssetId` UInt32,
    `leverage` Nullable (UInt32),
    `marginAmount` Float64,
    `orderId` String,
    `quoteAssetId` UInt32,
    `symbol` String,
    `timestamp` String,
    `userId` UInt64
  ) ENGINE = Kafka SETTINGS kafka_broker_list = 'kafka:9092',
  kafka_topic_list = 'futures.order.create.event,futures.order.cancel.event',
  kafka_group_name = 'clickhouse_consumer',
  kafka_format = 'JSONEachRow',
  kafka_num_consumers = 1;
-- Create the target table with the correct timestamp type
CREATE TABLE
  orders_all (
    `orderId` String,
    `userId` UInt64,
    `symbol` LowCardinality (String),
    `engineAction` Nullable (String), -- chỉ có ở create
    `engineSide` LowCardinality (String),
    `engineType` LowCardinality (String),
    `engineStop` LowCardinality (String),
    `enginePrice` Float64,
    `engineAmount` Float64,
    `engineFunds` Float64,
    `engineStopPrice` Float64,
    `fee` Float64,
    `feeAssetId` UInt32,
    `quoteAssetId` UInt32,
    `leverage` Nullable (UInt32), -- chỉ có ở create
    `marginAmount` Float64,
    `timestamp` DateTime
  ) ENGINE = MergeTree
PARTITION BY
  toYYYYMM (timestamp)
ORDER BY
  (symbol, timestamp, orderId);
SET
  date_time_input_format = 'best_effort';
-- Create the materialized view again with the correct timestamp parsing
CREATE MATERIALIZED VIEW mv_orders TO orders_all AS
SELECT
  engineAction,
  engineAmount,
  engineFunds,
  enginePrice,
  engineSide,
  engineStop,
  engineStopPrice,
  engineType,
  fee,
  feeAssetId,
  leverage,
  marginAmount,
  orderId,
  quoteAssetId,
  symbol,
  userId,
  parseDateTime64BestEffortOrNull (timestamp) AS timestamp
FROM
  kafka_consumer_orders;