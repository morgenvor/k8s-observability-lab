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
// Готовность цикла: если тик не случался дольше, нагрузка стоит, и SLI «нет данных»
// вместо «всё хорошо». 10 с — два интервала по 5 rps и с запасом на лимит CPU.
export const DEFAULT_READY_STALE_MS = 10_000;
// Предел тела ответа upstream: оно дочитывается ради честной длительности, но
// без предела чужой сервис мог бы заставить демон памяти съесть гигабайты.
export const MAX_UPSTREAM_BODY_BYTES = 1024 * 1024;

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

  const loadTicksSkipped = new Counter({
    name: 'load_ticks_skipped_total',
    help: 'Тики нагрузки, пропущенные из-за занятости concurrency',
    registers: [registry],
  });

  return { registry, loadRequestsTotal, loadRequestDuration, loadTicksSkipped };
}

// Тело ответа дочитываем, чтобы duration отражал полный обмен, но с пределом:
// при превышении чтение отменяется, и это не считается успехом.
async function readBoundedBody(res, limit = MAX_UPSTREAM_BODY_BYTES) {
  const reader = res.body.getReader();
  let bytes = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) return { tooLarge: false };
      bytes += value.byteLength;
      if (bytes > limit) {
        await reader.cancel();
        return { tooLarge: true };
      }
    }
  } finally {
    reader.releaseLock();
  }
}

// Границы параметров: конечные и положительные (concurrency — целое).
function assertPositive(name, value, { integer = false } = {}) {
  if (!Number.isFinite(value) || value <= 0 || (integer && !Number.isInteger(value))) {
    throw new Error(
      `${name} должен быть положительным ${integer ? 'целым ' : ''}числом, получено: ${value}`,
    );
  }
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
    const body = await readBoundedBody(res);
    return {
      outcome: res.ok && !body.tooLarge ? 'ok' : 'error',
      status: res.status,
      bodyTooLarge: body.tooLarge,
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
  readyStaleMs = DEFAULT_READY_STALE_MS,
  metrics,
  log,
  fetchImpl = fetch,
  now = () => Date.now(),
} = {}) {
  // Валидация до создания таймера: rps: 0 давал Infinity в setInterval, а
  // отрицательный concurrency — цикл, который никогда не грузит.
  assertPositive('rps', rps);
  assertPositive('concurrency', concurrency, { integer: true });
  assertPositive('timeoutMs', timeoutMs);
  let inflight = 0;
  let stopped = false;
  // Момент последнего тика: готовность — это «цикл жив и тикал недавно», а не
  // «процесс отвечает на HTTP». Пропущенные из-за concurrency тики тоже считаются.
  let lastTickAt = now();
  const timer = setInterval(() => {
    lastTickAt = now();
    if (inflight >= concurrency) {
      // Не warn: при сетевой задержке это ~3 события в секунду, то есть мусор
      // в Loki. Счётчик показывает то же самое и виден в метриках.
      metrics.loadTicksSkipped.inc();
      log('debug', 'load_tick_skipped', { inflight, concurrency });
      return;
    }
    inflight += 1;
    probe(targetUrl, { timeoutMs, fetchImpl })
      .then((result) => {
        if (result.bodyTooLarge) {
          log('warn', 'upstream_body_too_large', {
            limit: MAX_UPSTREAM_BODY_BYTES,
            target_url: targetUrl,
          });
        }
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
  }, Math.max(1, Math.round(1000 / rps)));
  timer.unref();
  return {
    stop: () => {
      stopped = true;
      clearInterval(timer);
    },
    isReady: () => !stopped && now() - lastTickAt <= readyStaleMs,
  };
}

export function createApp({
  logStream = process.stdout,
  targetUrl = DEFAULT_TARGET_URL,
  rps = DEFAULT_RPS,
  concurrency = DEFAULT_CONCURRENCY,
  timeoutMs = DEFAULT_TIMEOUT_MS,
  readyStaleMs = DEFAULT_READY_STALE_MS,
  fetchImpl = fetch,
  now = () => Date.now(),
} = {}) {
  const metrics = createMetrics();
  const log = createLogger(logStream);

  const server = http.createServer(async (req, res) => {
    // pathname объявлен до try: new URL() бросает TypeError на мусорном request-target,
    // а необработанный reject в async-обработчике роняет процесс (проверено 2026-11-04
    // на demo-api и alert-sink).
    let pathname;
    try {
      pathname = new URL(req.url ?? '/', 'http://demo-load').pathname;
    } catch (err) {
      // Мусорный request-target — ошибка клиента, а не сервера.
      log('warn', 'request_bad_target', {
        target: String(req.url ?? '').slice(0, 128),
        error: err?.message ?? String(err),
      });
      res.writeHead(400, { 'content-type': 'text/plain; charset=utf-8' });
      res.end('bad request\n');
      return;
    }
    if (req.method !== 'GET') {
      res.writeHead(405, { allow: 'GET', 'content-type': 'text/plain; charset=utf-8' });
      res.end('method not allowed\n');
      return;
    }
    if (pathname === '/healthz') {
      // Живость процесса: цикл может стоять, но под убивать не за что.
      res.writeHead(200, { 'content-type': 'text/plain; charset=utf-8' });
      res.end('ok\n');
      return;
    }
    if (pathname === '/ready') {
      // Готовность нагрузки: цикл жив и тикал недавно. Стоящий цикл — это не «всё
      // хорошо», а отсутствие SLI, поэтому 503, а не 200.
      const ready = loop.isReady();
      res.writeHead(ready ? 200 : 503, { 'content-type': 'text/plain; charset=utf-8' });
      res.end(ready ? 'ready\n' : 'not ready\n');
      return;
    }
    if (pathname === '/metrics') {
      try {
        const body = await metrics.registry.metrics();
        res.writeHead(200, { 'content-type': metrics.registry.contentType });
        res.end(body);
      } catch (err) {
        log('error', 'metrics_failed', { error: err?.message ?? String(err) });
        if (!res.headersSent) {
          res.writeHead(500, { 'content-type': 'text/plain; charset=utf-8' });
        }
        res.end('metrics failed\n');
      }
      return;
    }
    res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' });
    res.end('not found\n');
  });

  const loop = startLoadLoop({
    targetUrl,
    rps,
    concurrency,
    timeoutMs,
    readyStaleMs,
    metrics,
    log,
    fetchImpl,
    now,
  });

  return {
    server,
    metrics,
    log,
    // Готовность цикла доступна и без HTTP: тестам и shutdown-пути не нужен запрос.
    isReady: () => loop.isReady(),
    // stop() возвращает промис close: вызывающий (SIGTERM) ждёт завершения,
    // а не выходит сразу, обрывая открытые соединения.
    stop: () => {
      loop.stop();
      return new Promise((resolve) => server.close(resolve));
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
    // Фактические значения: порт берём у сервера (при PORT=0 env врёт), остальное —
    // дефолты, потому что start() не переопределяет rps/concurrency.
    app.log('info', 'load_started', {
      port: app.server.address().port,
      rps: DEFAULT_RPS,
      concurrency: DEFAULT_CONCURRENCY,
      target_url: process.env.TARGET_URL ?? DEFAULT_TARGET_URL,
    });
  });
  process.on('SIGTERM', () => {
    app.log('info', 'shutdown_started', {});
    app.stop().then(() => process.exit(0));
    // Если соединения не закрылись за 5 с — выходим принудительно, иначе под
    // висит до SIGKILL и теряет окно graceful shutdown.
    setTimeout(() => process.exit(1), 5000).unref();
  });
}

const invokedDirectly =
  process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href;
if (invokedDirectly) start();