// demo-load — генератор нагрузки для demo-api. SLI считаются по клиентским метрикам:
// серверный self-report не видит сетевую задержку, добавленную toxiproxy.
import http from 'node:http';
import { pathToFileURL } from 'node:url';

import { Histogram, Counter, Registry, collectDefaultMetrics } from 'prom-client';

// Одна JSON-строка на событие в stdout — тот же формат, что у demo-api,
// чтобы логи обоих сервисов разбирались в Loki одинаково.
function createLogger(stream = process.stdout) {
  return function log(level, msg, fields = {}) {
    stream.write(`${JSON.stringify({ ts: new Date().toISOString(), level, msg, ...fields })}\n`);
  };
}

export const DEFAULT_PORT = 8080;
export const DEFAULT_TARGET_URL = 'http://toxiproxy.demo:12001/work';
export const DEFAULT_RPS = 5;
export const DEFAULT_CONCURRENCY = 2;
export const DEFAULT_TIMEOUT_MS = 1000;

// Те же бакеты, что у demo-api; 0.3 обязателен для latency-SLO (доля <= 300 мс).
export const DURATION_BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.1, 0.2, 0.3, 0.5, 1, 2, 5];

export function createMetrics() {
  const registry = new Registry();
  collectDefaultMetrics({ register: registry, prefix: 'demo_' });

  const loadRequestsTotal = new Counter({
    name: 'load_requests_total',
    help: 'Запросы нагрузки по итогу: ok, error (ответ не 2xx или сеть), timeout',
    labelNames: ['outcome'],
    registers: [registry],
  });

  const loadRequestDuration = new Histogram({
    name: 'load_request_duration_seconds',
    help: 'Длительность запросов нагрузки с точки зрения клиента',
    buckets: DURATION_BUCKETS,
    registers: [registry],
  });

  return { registry, loadRequestsTotal, loadRequestDuration };
}

// Один запрос: исход классифицируется по клиентской стороне.
//   ok       — ответ 2xx;
//   error    — ответ не 2xx, сеть, DNS или соединение сброшено;
//   timeout  — не уложились в timeoutMs (сюда же попадает toxiproxy latency).
export async function probe(url, { timeoutMs = DEFAULT_TIMEOUT_MS, fetchImpl = fetch } = {}) {
  const startedAt = process.hrtime.bigint();
  const elapsed = () => Number(process.hrtime.bigint() - startedAt) / 1e9;

  try {
    const res = await fetchImpl(url, { signal: AbortSignal.timeout(timeoutMs) });
    await res.arrayBuffer(); // дочитываем тело, иначе duration не отражает полный обмен
    return {
      outcome: res.ok ? 'ok' : 'error',
      status: res.status,
      durationSeconds: elapsed(),
    };
  } catch (err) {
    const timedOut =
      err?.name === 'TimeoutError' ||
      err?.name === 'AbortError' ||
      err?.cause?.name === 'TimeoutError';
    return {
      outcome: timedOut ? 'timeout' : 'error',
      status: null,
      error: err?.message ?? String(err),
      durationSeconds: elapsed(),
    };
  }
}

// Цикл нагрузки: тик раз в 1000/rps мс, одновременно не больше `concurrency` запросов.
// Если предыдущие ещё в полёте, тик пропускается — лучше недогрузить, чем копить очередь.
export function startLoadLoop({
  targetUrl = DEFAULT_TARGET_URL,
  rps = DEFAULT_RPS,
  concurrency = DEFAULT_CONCURRENCY,
  timeoutMs = DEFAULT_TIMEOUT_MS,
  metrics,
  log,
  fetchImpl = fetch,
} = {}) {
  let inflight = 0;
  const timer = setInterval(() => {
    if (inflight >= concurrency) {
      log('warn', 'load_tick_skipped', { inflight, concurrency });
      return;
    }
    inflight += 1;
    probe(targetUrl, { timeoutMs, fetchImpl })
      .then((result) => {
        metrics.loadRequestsTotal.inc({ outcome: result.outcome });
        metrics.loadRequestDuration.observe(result.durationSeconds);
        log('info', 'load_request', {
          outcome: result.outcome,
          status: result.status,
          duration_ms: Math.round(result.durationSeconds * 1000),
          target_url: targetUrl,
        });
      })
      .finally(() => {
        inflight -= 1;
      });
  }, Math.round(1000 / rps));
  timer.unref();
  return { stop: () => clearInterval(timer) };
}

export function createApp({
  logStream = process.stdout,
  targetUrl = DEFAULT_TARGET_URL,
  rps = DEFAULT_RPS,
  concurrency = DEFAULT_CONCURRENCY,
  timeoutMs = DEFAULT_TIMEOUT_MS,
  fetchImpl = fetch,
} = {}) {
  const metrics = createMetrics();
  const log = createLogger(logStream);

  const server = http.createServer(async (req, res) => {
    const { pathname } = new URL(req.url ?? '/', 'http://demo-load');
    if (req.method !== 'GET') {
      res.writeHead(405, { allow: 'GET', 'content-type': 'text/plain; charset=utf-8' });
      res.end('method not allowed\n');
      return;
    }
    if (pathname === '/healthz') {
      res.writeHead(200, { 'content-type': 'text/plain; charset=utf-8' });
      res.end('ok\n');
      return;
    }
    if (pathname === '/metrics') {
      const body = await metrics.registry.metrics();
      res.writeHead(200, { 'content-type': metrics.registry.contentType });
      res.end(body);
      return;
    }
    res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' });
    res.end('not found\n');
  });

  const loop = startLoadLoop({ targetUrl, rps, concurrency, timeoutMs, metrics, log, fetchImpl });

  return {
    server,
    metrics,
    log,
    stop: () => {
      loop.stop();
      server.close();
    },
  };
}

function start() {
  const port = Number(process.env.PORT ?? DEFAULT_PORT);
  if (!Number.isInteger(port) || port <= 0 || port > 65_535) {
    process.stderr.write(`ERROR: PORT='${process.env.PORT}' не является номером порта\n`);
    process.exit(1);
  }
  const app = createApp({ targetUrl: process.env.TARGET_URL ?? DEFAULT_TARGET_URL });
  app.server.listen(port, () => {
    app.log('info', 'load_started', { port, rps: DEFAULT_RPS, concurrency: DEFAULT_CONCURRENCY });
  });
  process.on('SIGTERM', () => {
    app.log('info', 'shutdown_started', {});
    app.stop();
    process.exit(0);
  });
}

const invokedDirectly =
  process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href;
if (invokedDirectly) start();