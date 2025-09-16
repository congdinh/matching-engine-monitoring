// clickhouse-binance-ticker.ts
// Node.js + TypeScript example: ingest Binance miniTicker stream (!miniTicker@arr)
// into ClickHouse using HTTP interface (JSONEachRow).

// Install:
// npm i axios ws
// npm i -D typescript ts-node @types/ws

import WebSocket from 'ws';
import axios from 'axios';

// ---------- CONFIG ----------
const CLICKHOUSE_HOST = process.env.CLICKHOUSE_HOST || 'http://localhost:8123';
const CLICKHOUSE_USER = process.env.CLICKHOUSE_USER || 'default';
const CLICKHOUSE_PASS = process.env.CLICKHOUSE_PASS || '';
const CLICKHOUSE_DB = process.env.CLICKHOUSE_DB || 'default';

// Binance public websocket for all mini-tickers (lightweight per-symbol ticks)
// See: https://binance-docs.github.io/apidocs/spot/en/#individual-symbol-mini-ticker-streams
const BINANCE_WS_URL = 'wss://stream.binance.com:9443/ws/!miniTicker@arr';

// Batch config
const BATCH_MAX = 1000; // flush when this many rows collected
const FLUSH_INTERVAL_MS = 2000; // flush at least every 2s

// ---------- ClickHouse table DDL (create if not exists) ----------
const CREATE_TABLE_SQL = `
CREATE TABLE IF NOT EXISTS ${CLICKHOUSE_DB}.market_ticks (
  symbol String,
  event_time DateTime,
  close_price Float64,
  open_price Float64,
  high_price Float64,
  low_price Float64,
  base_volume Float64,
  quote_volume Float64,
  trade_count UInt32,
  // keep raw payload for debugging/extra fields
  payload String
)
ENGINE = MergeTree()
ORDER BY (symbol, event_time)
TTL event_time + INTERVAL 30 DAY
`;

// ---------- Helper: run SQL via ClickHouse HTTP API ----------
async function runClickHouseSql(sql: string) {
  const url = `${CLICKHOUSE_HOST}/?query=${encodeURIComponent(sql)}`;
  const auth = {username: CLICKHOUSE_USER, password: CLICKHOUSE_PASS};
  return axios.post(url, null, {auth});
}

// ---------- Prepare table ----------
async function ensureTable() {
  console.log('Creating table (if not exists) ...');
  await runClickHouseSql(CREATE_TABLE_SQL);
  console.log('Table ready.');
}

// ---------- Batch buffer and flush logic ----------
let buffer: any[] = [];
let flushing = false;

async function flushBuffer() {
  if (buffer.length === 0) return;
  if (flushing) return; // avoid concurrent flushes
  flushing = true;
  const rows = buffer;
  buffer = [];

  try {
    // ClickHouse HTTP insert using JSONEachRow format
    const insertSql = `INSERT INTO ${CLICKHOUSE_DB}.market_ticks FORMAT JSONEachRow`;
    const url = `${CLICKHOUSE_HOST}/?query=${encodeURIComponent(insertSql)}`;
    const auth = {username: CLICKHOUSE_USER, password: CLICKHOUSE_PASS};

    // body must be newline-delimited JSON rows
    const body = rows.map(r => JSON.stringify(r)).join('\n');

    const res = await axios.post(url, body, {
      auth,
      headers: {'Content-Type': 'application/x-ndjson'},
      timeout: 20000,
    });

    console.log(
      `Flushed ${rows.length} rows -> ClickHouse (status ${res.status})`
    );
  } catch (err: any) {
    console.error(
      'Error flushing to ClickHouse:',
      err?.response?.data || err.message || err
    );
    // on error, requeue rows (simple strategy)
    buffer = rows.concat(buffer);
    // if buffer grows too big, drop oldest (or implement persistent queue)
    if (buffer.length > 100_000) {
      console.warn('Buffer too large, trimming to 100k (dropping oldest)');
      buffer = buffer.slice(-100_000);
    }
  } finally {
    flushing = false;
  }
}

setInterval(() => void flushBuffer(), FLUSH_INTERVAL_MS);

// ---------- WebSocket handling ----------
async function start() {
  await ensureTable();

  console.log('Connecting to Binance WS:', BINANCE_WS_URL);
  const ws = new WebSocket(BINANCE_WS_URL);

  ws.on('open', () => {
    console.log('Binance WS open');
  });

  ws.on('message', data => {
    try {
      // Binance sends array of miniTicker objects
      // Each item example (miniTicker):
      // {
      //  "e": "24hrMiniTicker",  // event type
      //  "E": 123456789,          // event time
      //  "s": "BTCUSDT",         // symbol
      //  "c": "0.0025",         // close price
      //  "o": "0.0010",         // open price
      //  "h": "0.0025",         // high price
      //  "l": "0.0010",         // low price
      //  "v": "10000",          // base asset volume
      //  "q": "18",             // quote asset volume
      // }

      const payload = JSON.parse(data.toString());
      // payload is typically an array
      const arr = Array.isArray(payload) ? payload : payload.data || [];

      arr.forEach((item: any) => {
        const row = {
          symbol: item.s,
          event_time: Math.floor(item.E / 1000), // Convert milliseconds to seconds for DateTime
          close_price: parseFloat(item.c),
          open_price: parseFloat(item.o),
          high_price: parseFloat(item.h),
          low_price: parseFloat(item.l),
          base_volume: parseFloat(item.v || 0),
          quote_volume: parseFloat(item.q || 0),
          trade_count: 0, // miniTicker doesn't include trade count; set 0 or use full ticker stream
          payload: JSON.stringify(item),
        };

        buffer.push(row);

        if (buffer.length >= BATCH_MAX) {
          void flushBuffer();
        }
      });
    } catch (err) {
      console.error('Error parsing WS message', err);
    }
  });

  ws.on('close', (code, reason) => {
    console.warn('Binance WS closed', code, reason.toString());
    // try reconnect after delay
    setTimeout(start, 2000);
  });

  ws.on('error', err => {
    console.error('WS error', err);
    ws.terminate();
  });

  // graceful shutdown
  process.on('SIGINT', async () => {
    console.log('SIGINT received, flushing and exiting...');
    ws.close();
    await flushBuffer();
    process.exit(0);
  });
}

start().catch(err => {
  console.error('Fatal error', err);
  process.exit(1);
});
