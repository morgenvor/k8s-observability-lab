// demo-api — фикстура лаборатории: HTTP-сервис с корректными RED-метриками,
// JSON-логами, /healthz и /ready. Внешних зависимостей нет, только prom-client.
import http from 'node:http';
import { pathToFileURL } from 'node:url';

import { createLogger, newRequestId } from './log.js';
import { createMetrics, statusClass } from './metrics.js';

export const DEFAULT_PORT = 8080;
export const SHUTDOWN_GRACE_MS = 10_000;
const WORK_ITERATIONS = 20_000;

// Шаблоны маршрутов: метка `route` в метриках берётся отсюда, а не из URL,
// поэтому произвольные пути не плодят серии.
const ROUTE_TEMPLATES = new Set(['/healthz', '/ready', '/metrics', '/work']);

export function routeTemplate(pathname) {
  return ROUTE_TEMPLATES.has(pathname) ? pathname : 'other';
}

// Немного CPU-работы, чтобы длительность запроса была настоящей: на этом строится
// latency-дрилл (toxiproxy добавляет сетевую задержку поверх реальной обработки).
function syntheticWork() {
  let acc = 0;
  for (let i = 0; i < WORK_ITERATIONS; i += 1) {
    acc = (acc + Math.sqrt(i)) % 1_000_000;
  }
  return acc;
}

// createApp отдаёт сервер и управление готовностью отдельно от процесса:
// тесты поднимают его на свободном порту и переводят в shutdown без SIGTERM.
export function createApp({ logStream = process.stdout, work = syntheticWork } = {}) {
  const metrics = createMetrics();
  const log = createLogger(logStream);
  let ready = true;

  const server = http.createServer(async (req, res) => {
    const startedAt = process.hrtime.bigint();
    const requestId = newRequestId(req.headers['x-request-id']);
    const { pathname } = new URL(req.url ?? '/', 'http://demo-api');
    const route = routeTemplate(pathname);
    let status = 500;

    metrics.inflight.inc();
    const finish = () => {
      const durationSeconds = Number(process.hrtime.bigint() - startedAt) / 1e9;
      metrics.inflight.dec();
      metrics.requestsTotal.inc({
        method: req.method,
        route,
        status_class: statusClass(status),
      });
      metrics.requestDuration.observe({ method: req.method, route }, durationSeconds);
      log('info', 'http_request', {
        request_id: requestId,
        method: req.method,
        route,
        status,
        duration_ms: Math.round(durationSeconds * 1000),
      });
    };

    const respond = (code, body, headers = {}) => {
      status = code;
      res.writeHead(code, { 'content-type': 'text/plain; charset=utf-8', ...headers });
      res.end(body);
    };

    try {
      if (req.method !== 'GET') {
        respond(405, 'method not allowed\n', { allow: 'GET' });
      } else if (pathname === '/healthz') {
        // Живость: без проверки зависимостей и состояния shutdown.
        respond(200, 'ok\n');
      } else if (pathname === '/ready') {
        // Готовность: сразу 503 после SIGTERM, чтобы под убрали из endpoints.
        respond(ready ? 200 : 503, ready ? 'ready\n' : 'shutting down\n');
      } else if (pathname === '/metrics') {
        const body = await metrics.registry.metrics();
        respond(200, body, { 'content-type': metrics.registry.contentType });
      } else if (pathname === '/work') {
        const result = work();
        respond(200, `${JSON.stringify({ ok: true, result })}\n`, {
          'content-type': 'application/json',
        });
      } else {
        respond(404, 'not found\n');
      }
    } catch (err) {
      log('error', 'request_failed', {
        request_id: requestId,
        method: req.method,
        route,
        error: err?.message ?? String(err),
      });
      if (!res.headersSent) respond(500, 'internal error\n');
    } finally {
      finish();
    }
  });

  return {
    server,
    metrics,
    log,
    isReady: () => ready,
    beginShutdown: () => {
      ready = false;
    },
  };
}

function start() {
  const port = Number(process.env.PORT ?? DEFAULT_PORT);
  if (!Number.isInteger(port) || port <= 0 || port > 65_535) {
    process.stderr.write(`ERROR: PORT='${process.env.PORT}' не является номером порта\n`);
    process.exit(1);
  }

  const app = createApp();
  app.server.listen(port, () => {
    app.log('info', 'server_started', { port, pid: process.pid });
  });

  // SIGTERM: сначала перестаём быть ready (probe вернёт 503), затем закрываем
  // соединения; если за 10 с не закрылись — выходим принудительно.
  process.on('SIGTERM', () => {
    app.log('info', 'shutdown_started', { grace_ms: SHUTDOWN_GRACE_MS });
    app.beginShutdown();
    app.server.close(() => {
      app.log('info', 'shutdown_finished', {});
      process.exit(0);
    });
    setTimeout(() => {
      app.log('error', 'shutdown_timeout', { grace_ms: SHUTDOWN_GRACE_MS });
      process.exit(1);
    }, SHUTDOWN_GRACE_MS).unref();
  });
}

const invokedDirectly =
  process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href;
if (invokedDirectly) start();