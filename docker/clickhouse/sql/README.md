# Stream processors (pattern)

- Social pipeline: social_raw → SocialConsumer (Node/Go) batch N msgs → call OpenAI bulk (gpt 4o-mini 2024 0.0075$/1M) → push social_processed → storage tokenizer sentiment buzz
- Market pipeline: raw L2 diffs → Normalizer (aggregate 100ms window, compress topN) → push to market_l2 → ClickHouse ingestion (Kafka engine)
- User actions: Gateway collects via batch (sendBeacon) → push frontend_events
- Alerts: Materialized Views or stream processors compute and push to alerts
- Kafka Topics:
  - social_raw (partitions: 12, retention: 7d for raw)
  - social_processed (embedding/sentiment) (retention: 30d)
  - market_l2 (orderbook diffs)
  - market_trades
  - user_actions
  - frontend_events
  - alerts (compact topic, small retention)

# 1) Architecture Overview (high-level)

- Sources: Social (Twitter/X, RSS/news, Telegram, Reddit, on-chain crawlers), Market data (orderbook, trades), User events (order API, browser actions), Backend actions (deposits/withdrawals).
- Ingest/Streaming layer: `Producers → Kafka` (decouple & scale).
- Processing layer:

  - Social batch → OpenAI (tokenize / sentiment / embeddings) → write results to ClickHouse.
  - Stream processors (Flink/ksql/consumer Node/Go) normalize events → ClickHouse (bulk/HTTP/Kafka engine).

- Storage: Single-node ClickHouse (MergeTree variants). Metadata/transactional DB: MongoDB (user account, configs, risk policies).
- Alerting + Visualization: HyperDX self-host (metrics + traces + alerting) + Grafana/HyperDX dashboards reading ClickHouse (or push metrics to HyperDX). Alert webhook from consumer (or from HyperDX) to risk ops.
- Observability: node & CH metrics, JVM/consumer metrics, ingest lag, backpressure.

# 2) Data (flow)

1. **Social ingest**

   - Collect raw messages → enqueue Kafka topic `social_raw`.
   - Consumer batches (per minute or N messages) → send to OpenAI for tokenization/sentiment (bulk).
   - Receive sentiment + tokens + embedding → write to ClickHouse `social_buzz`.

2. **Market data (orderbook & trades)**

   - Orderbook feed (L2 diffs or snapshots) → normalize to compact events (e.g., top-10 bids/asks or aggregated deltas) → publish to Kafka `market_l2`.
   - Trade feed → Kafka `trades`.
   - Consumer writes to ClickHouse with batching (use Buffer table or Kafka engine).

3. **User actions**

   - Order API events, trade actions → publish to `user_actions`.
   - Frontend browser events → batch (navigator.sendBeacon or periodic batch) to gateway → Kafka `frontend_actions`.

4. **Post-processing & alerts**

   - Materialized views / continuous aggregations in ClickHouse compute rolling metrics (e.g., aggressive cancels, excessive execs, abnormal liquidity changes).
   - When threshold hit: push event to `alerts` Kafka topic via MV or external consumer -> webhook sender -> HyperDX/Grafana + Ops.

# 3) ClickHouse: table patterns + example DDLs

Key principles:

- Use `MergeTree` family. Partition by day for retention & efficient drops.
- `ORDER BY` should match common query filters (e.g., `(symbol, toDate(event_time), event_time)`).
- TTL: automatic retention `TTL event_time + INTERVAL 30 DAY`.
- Use compression codecs per column (e.g., `codec(ZSTD(3))`), Float64 for prices, LowCardinality(String) for repetitive strings.
- For high insert rates, prefer `Buffer` table or `Kafka` engine + Materialized View consuming Kafka -> MergeTree.

### Social buzz (post-OpenAI)

```sql
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
TTL event_time + INTERVAL 30 DAY
SETTINGS index_granularity = 8192;
```

Notes: embeddings can be large — consider separate table `embeddings` or store only vectors for top posts.

### Trades

```sql
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
```

### Orderbook snapshot (top-N compressed)

Store condensed snapshots every N ms or on change of top levels.

```sql
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
```

### User orders / actions / deposits

Keep normalized tables with `user_id` referencing MongoDB user id (or hashed/anonymized).

```sql
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
```

### Frontend/browser actions

Batch small events, group by session id optionally.

```sql
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
```

# 4) Ingest patterns & reliability

- **Prefer Kafka as buffer**. ClickHouse `Kafka` engine + `Materialized View` can stream directly into MergeTree.
- **Batch insert** for HTTP: use `JSONEachRow` newline-delimited, send batches of \~1k–10k rows.
- For high-frequency orderbook: **don't insert every raw tick**; compress diffs:

  - store top-N snapshots every X ms or only when topN changes beyond threshold.
  - store L2 deltas aggregated per 100ms window.

- Use ClickHouse `Buffer` table as ingress to absorb bursts (autoflush).
- Implement idempotency keys (e.g., `event_id`) and dedupe logic in CH or preprocess.

# 5) ClickHouse single-node tuning

**Hardware**

- NVMe SSD (local): 1–2 TB (depending retention + indexes), RAID not necessary if single node; for production consider replication.
- RAM: 32–64 GB (prefer 64GB if budget). ClickHouse uses memory for merges and queries.
- CPU: 8–16 cores (more cores for parallel merges/queries).
- IOPS: NVMe high IOPS important.

**CH settings (examples)**

- `max_memory_usage` per query: set cautiously (e.g., 8GB).
- `max_threads` = number of CPU cores.
- `merge_tree_max_rows_to_use_cache` tuning.
- `index_granularity` default 8192 OK; tune for SELECT patterns.
- Compression: `codec(ZSTD(3))` for strings, `LZ4` for others if lower CPU.

**Merge tuning**

- Monitor background merges (merges can spike IO); set `background_pool_size`.
- For single node, set `max_bytes_to_merge_at_min_space_in_pool` smaller to avoid disk pressure.

# 6) OpenAI bulk sentiment pipeline

- **Batching**: aggregate N messages (e.g., per symbol per minute up to 500–1000 items) → send as single bulk request (reduces overhead & cost).
- **What to send**: pre-cleaned text, no PII. Use short context; consider using `requests` for embeddings and a separate sentiment classifier if cost-sensitive.
- **What to store**: sentiment score, sentiment label, tokens_count, and optionally embedding id or vector. For embeddings, consider storing in a vector DB (Milvus/Pinecone) and storing vector-id in ClickHouse.
- **Rate limits & cost**: watch throughput; if huge social volume, sample or prioritize by engagement (retweet count) and token length.
- **Avoid storing raw PII**: hash or redact.

# 7) Real-time alerting → webhook

Options:

1. **Materialized View → Kafka alerts topic → consumer job sends webhook**

   - Build MVs that detect anomalies (e.g., sudden liquidity drop > X% in 1min, or per-user order velocity > threshold).
   - MVs write to Kafka (via Kafka table engine) or to `alerts_merge` table polled by alerter.
   - Alert sender service consumes Kafka and posts webhook + pushes to HyperDX/Grafana.

2. **Grafana/HyperDX alerting**

   - Create dashboards/queries that evaluate thresholds; use Grafana alerting (pull) or HyperDX alerting (if it supports CH datasource).
   - Pros: built-in suppression, escalation. Cons: poll interval may be coarser.

3. **Push-based in stream processors**

   - Run streaming job (Flink/ksql/consumer) that continuously computes anomaly detection and emits alerts as events → ClickHouse + webhook.

Recommendation: use hybrid: critical, low-latency alerts via stream processor + Kafka→webhook; non-critical via dashboards alerting.

# 8) Example alert flow (practical)

- Materialized View computes `liquidity_drop_events` whenever `spread` or `topN_volume` falls > X.
- MV writes to Kafka topic `alerts`.
- Alert Worker consumes `alerts`, enriches with user data from MongoDB, sends webhook to ops Slack/PagerDuty/HTTP endpoint and writes into `alerts_history` CH table.

# 9) Security, privacy, compliance

- Encrypt in-transit (TLS) and at-rest (OS-level disk encryption). Use CH auth + network ACL.
- Sanitize inputs to OpenAI (remove user identifiers).
- Control access to ClickHouse (RBAC).
- Audit logs for who triggered queries / exported data.

# 10) Operational considerations & SLOs

- **SLA** for alerting: how fast must alerts be delivered? (< 1s realistic for in-memory stream alerts; for CH MVs, near-real-time depends on ingest frequency).
- **Backfill & replays**: keep Kafka retention to allow replays; have idempotent ingest.
- **Monitoring**: ClickHouse metrics (memory, merges, replication lag if used); Kafka lag; consumer errors; OpenAI latency/error.

# 11) Cost & sizing quick guide (single node, for 30d)

- Disk: NVMe 1–2 TB (allow 2–3x raw data for indexes/replicas) → choose 2TB.
- RAM: 32–64GB (64GB preferred).
- CPU: 8–16 cores.
- Network: 1Gbps or better (if many sources).
- If budget tighter: 16–32GB RAM + 8 cores still workable but watch query concurrency.

# 12) Quick checklist

1. Define data contract (schema + event ids) per source.
2. Setup Kafka topics + retention + partitions.
3. Implement consumers:

   - Social consumer → batch → OpenAI → write `social_buzz`.
   - Market consumer → compact diffs/snapshots → write `book_topn` & `trades`.
   - User actions consumer → write `user_orders`, `frontend_actions`.

4. Provision ClickHouse instance with NVMe + RAM + CH config.
5. Create tables + Materialized Views + TTL.
6. Implement alert worker (consumer) + webhook sender.
7. Dashboards & alerting in HyperDX/Grafana.
8. Load test ingest & queries with realistic traffic; tune `index_granularity`, merges, background_pool_size.

# 13) Short examples: ingestion recommandations (practical)

- Use `Kafka Engine` in CH + `Materialized View`:

```sql
CREATE TABLE kafka_trades_engine (...) ENGINE = Kafka('kafka:9092', 'trades', 'group1', 'JSONEachRow');

CREATE MATERIALIZED VIEW mv_trades_to_mt TO trades AS
SELECT ... FROM kafka_trades_engine;
```

- Or use `Buffer`:

```sql
CREATE TABLE trades_buffer AS trades ENGINE = Buffer(default, trades, 16, 10, 60, 10000, 100000);
```

# 14) Pitfalls & tradeoffs

- Writing huge vectors (embeddings) into CH can bloat storage — prefer external vectordb.
- CH is OLAP, not OLTP; avoid using it as source-of-truth for transactional operations.
- For extreme high-frequency orderbook (sub-ms), CH may not be the right target for raw; instead persist aggregated data and raw to cold storage (S3) for forensics.
- Joins large-fact × large-fact are expensive — pre-aggregate or denormalize.
