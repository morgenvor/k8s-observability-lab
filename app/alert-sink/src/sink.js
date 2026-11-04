// alert-sink — приёмник уведомлений Alertmanager (фаза 4 плана v1.0).
//
// Зачем отдельный сервис: Alertmanager принадлежит чарту, и «алерт сработал» ещё не
// значит «уведомление дошло». Sink принимает webhook Alertmanager v2, хранит кольцо
// последних уведомлений в памяти (/timeline читают дриллы фазы 6 и живая проверка)
// и считает метрики доставки. Внешних зависимостей нет, только prom-client.
import http from 'node:http';
import { pathToFileURL } from 'node:url';

import { Counter, Gauge, Registry } from 'prom-client';

export const DEFAULT_PORT = 8080;
// 1 MiB: группа алертов Alertmanager весит десятки килобайт, предел — защита от
// чужого тела. Лимит проверяется по ходу чтения: сверх лимита тело не копится.
export const MAX_BODY_BYTES = 1024 * 1024;
// Кольцо уведомлений. 200 последних хватает на таймлайн дрилла (4 алерта × несколько
// минут), а память остаётся ограниченной (уведомление — единицы килобайт).
export const TIMELINE_SIZE = 200;
// Второй предел кольца — байты. Запись хранит labels целиком, поэтому её размер
// сравним с размером payload (до MAX_BODY_BYTES = 1 MiB): 200 × 1 MiB = 200 MiB в
// памяти при лимите пода 64Mi — путь к OOMKill, а кольцо и есть хранилище
// доказательств дриллов. 4 MiB на порядок больше реального объёма (200 уведомлений
// по ~2 КБ ≈ 400 КБ) и переживает один крупный payload.
export const TIMELINE_MAX_BYTES = 4 * 1024 * 1024;
// Границы payload: alertname становится меткой Prometheus (alertsink_alert_events_total),
// а число алертов — числом серий и записей кольца. Без лимитов любой под в кластере
// POST'ом создаёт произвольную кардинальность (нашло ревью 2026-11-04).
export const MAX_ALERTS = 200;
export const MAX_ALERTNAME_LENGTH = 128;

const ALERT_STATUSES = new Set(['firing', 'resolved']);
// Метка severity в метрике — старшая серьёзность уведомления. critical/warning здесь
// не для красоты: правила чарта kube-prometheus-stack приходят именно с ними, и без
// этого маппинга они попали бы в «none» и слились бы с шумом.
const SEVERITY_RANK = new Map([
  ['page', 0],
  ['critical', 0],
  ['ticket', 1],
  ['warning', 1],
  ['info', 2],
]);

// Маршрут для метрики — только из фиксированного набора: путь в запросе задаёт
// клиент, и как метка Prometheus он дал бы неограниченную кардинальность.
const KNOWN_ROUTES = new Set(['/webhook', '/timeline', '/metrics', '/healthz']);

function routeKind(pathname) {
  return KNOWN_ROUTES.has(pathname) ? pathname : 'other';
}

// Исход запроса по коду ответа; 499 — обрыв клиента (соглашение nginx), в логах
// он отмечается отдельно, потому что ответа клиенту в этом случае нет.
function outcomeOf(status) {
  if (status === 499) return 'aborted';
  if (status < 400) return 'ok';
  if (status < 500) return 'client_error';
  return 'server_error';
}

// Одна JSON-строка на событие в stdout — тот же формат, что у demo-api/demo-load,
// чтобы логи трёх сервисов разбирались в Loki одинаково.
function createLogger(stream = process.stdout) {
  return function log(level, msg, fields = {}) {
    stream.write(`${JSON.stringify({ ts: new Date().toISOString(), level, msg, ...fields })}\n`);
  };
}

export function createMetrics() {
  const registry = new Registry();

  const notifications = new Counter({
    name: 'alertsink_notifications_total',
    help: 'Принятые уведомления Alertmanager: по статусу и старшей серьёзности',
    labelNames: ['status', 'severity'],
    registers: [registry],
  });

  const alertEvents = new Counter({
    name: 'alertsink_alert_events_total',
    help: 'Отдельные алерты внутри принятых уведомлений',
    labelNames: ['alertname', 'status'],
    registers: [registry],
  });

  const lastNotification = new Gauge({
    name: 'alertsink_last_notification_timestamp_seconds',
    help: 'Unix-время последнего принятого уведомления',
    registers: [registry],
  });

  // Исходы запросов: без них не отличить «sink отказал» от «Alertmanager не отправил».
  // Метка route нормализована (см. routeKind): сырой pathname давал бы произвольную
  // кардинальность — тот же класс дефекта, что чинили в ревью 2026-11-04.
  const requests = new Counter({
    name: 'alertsink_requests_total',
    help: 'HTTP-запросы sink по нормализованному маршруту и исходу',
    labelNames: ['route', 'outcome'],
    registers: [registry],
  });

  return { registry, notifications, alertEvents, lastNotification, requests };
}

// Валидация обязательных полей Alertmanager v2. Возвращает текст ошибки или null:
// битое уведомление должно получить 400, а не отработать частично и оставить
// в /timeline запись, на которую потом сошлётся evidence дрилла.
export function validatePayload(payload) {
  if (payload === null || typeof payload !== 'object' || Array.isArray(payload)) {
    return 'тело должно быть JSON-объектом';
  }
  if (!ALERT_STATUSES.has(payload.status)) {
    return 'status должен быть "firing" или "resolved"';
  }
  if (!Array.isArray(payload.alerts) || payload.alerts.length === 0) {
    return 'alerts должен быть непустым массивом';
  }
  if (payload.alerts.length > MAX_ALERTS) {
    return `alerts содержит больше ${MAX_ALERTS} элементов`;
  }
  for (const [index, alert] of payload.alerts.entries()) {
    if (alert === null || typeof alert !== 'object' || Array.isArray(alert)) {
      return `alerts[${index}] должен быть объектом`;
    }
    if (!ALERT_STATUSES.has(alert.status)) {
      return `alerts[${index}].status должен быть "firing" или "resolved"`;
    }
    if (alert.labels === null || typeof alert.labels !== 'object' || Array.isArray(alert.labels)) {
      return `alerts[${index}].labels должен быть объектом`;
    }
    if (typeof alert.labels.alertname !== 'string' || alert.labels.alertname === '') {
      return `alerts[${index}].labels.alertname обязателен`;
    }
    if (alert.labels.alertname.length > MAX_ALERTNAME_LENGTH) {
      return `alerts[${index}].labels.alertname длиннее ${MAX_ALERTNAME_LENGTH} символов`;
    }
  }
  return null;
}

function topSeverity(alerts) {
  let best = 'none';
  for (const alert of alerts) {
    const severity = alert.labels.severity;
    const rank = SEVERITY_RANK.get(severity);
    if (rank === undefined) continue;
    if (best === 'none' || rank < SEVERITY_RANK.get(best)) best = severity;
  }
  return best;
}

// Форма записи /timeline зафиксирована контрактом плана: поля snake_case, starts_at/
// ends_at — из startsAt/endsAt Alertmanager (null, если поля нет в payload).
function buildEntry(payload, receivedAt) {
  return {
    received_at: receivedAt.toISOString(),
    status: payload.status,
    group_key: typeof payload.groupKey === 'string' ? payload.groupKey : '',
    // Alertmanager усекает группу по maxAlerts: 50 и присылает, сколько алертов
    // отброшено. Без поля /timeline выглядит полным, и evidence дрилла мог бы
    // сослаться на неполный набор. 0 — поля нет или оно не положительное число.
    truncated_alerts:
      Number.isInteger(payload.truncatedAlerts) && payload.truncatedAlerts > 0
        ? payload.truncatedAlerts
        : 0,
    alerts: payload.alerts.map((alert) => ({
      name: alert.labels.alertname,
      status: alert.status,
      labels: alert.labels,
      starts_at: typeof alert.startsAt === 'string' ? alert.startsAt : null,
      ends_at: typeof alert.endsAt === 'string' ? alert.endsAt : null,
    })),
  };
}

class BodyTooLargeError extends Error {}

// Чтение тела с лимитом. Сверх лимита тело дочитывается вхолостую (chunks не растут),
// поэтому клиент получает 413, а не обрыв соединения до ответа.
// shortcut: для бесконечного тела нужен жёсткий таймаут чтения — когда у sink появится
// внешний трафик, а не только Alertmanager в кластере.
function readBody(req, limit = MAX_BODY_BYTES) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    let tooLarge = false;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > limit) {
        tooLarge = true;
        chunks.length = 0;
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (tooLarge) {
        reject(new BodyTooLargeError(`тело больше ${limit} байт`));
        return;
      }
      resolve(Buffer.concat(chunks).toString('utf8'));
    });
    req.on('error', reject);
  });
}

export function createApp({ logStream = process.stdout, clock = () => new Date() } = {}) {
  const metrics = createMetrics();
  const log = createLogger(logStream);
  const timeline = [];
  // Размеры записей в байтах — параллельный массив: кольцо держим по двум пределам
  // (число записей и байты), не меняя публичную форму записи /timeline.
  const timelineSizes = [];
  let timelineBytes = 0;

  const record = (payload) => {
    const receivedAt = clock();
    const entry = buildEntry(payload, receivedAt);
    const entryBytes = Buffer.byteLength(JSON.stringify(entry), 'utf8');
    timeline.push(entry);
    timelineSizes.push(entryBytes);
    timelineBytes += entryBytes;
    // Вытесняем по любому из пределов; последнюю запись держим всегда, иначе
    // одиночное уведомление больше бюджета стёрло бы само себя.
    while (timeline.length > TIMELINE_SIZE || (timelineBytes > TIMELINE_MAX_BYTES && timeline.length > 1)) {
      timelineBytes -= timelineSizes.shift();
      timeline.shift();
    }

    const severity = topSeverity(payload.alerts);
    metrics.notifications.inc({ status: payload.status, severity });
    for (const alert of payload.alerts) {
      metrics.alertEvents.inc({ alertname: alert.labels.alertname, status: alert.status });
    }
    metrics.lastNotification.set(receivedAt.getTime() / 1000);

    log('info', 'notification_received', {
      status: payload.status,
      severity,
      group_key: entry.group_key,
      alerts: entry.alerts.map((alert) => `${alert.name}:${alert.status}`),
    });
    return entry;
  };

  const server = http.createServer(async (req, res) => {
    const startedAt = process.hrtime.bigint();
    // pathname объявлен до try: new URL() бросает TypeError на мусорном request-target,
    // а необработанный reject в async-обработчике роняет процесс вместе с кольцом
    // /timeline (проверено 2026-11-04).
    let pathname = '/';
    let route = 'invalid';
    let status = 500;

    const respond = (code, body, headers = {}) => {
      status = code;
      // Обрыв клиента: сокет уже уничтожен, писать в него нечего и некому.
      if (res.destroyed) return;
      res.writeHead(code, { 'content-type': 'text/plain; charset=utf-8', ...headers });
      res.end(body);
    };
    const respondJson = (code, value) =>
      respond(code, `${JSON.stringify(value)}\n`, { 'content-type': 'application/json; charset=utf-8' });

    try {
      try {
        pathname = new URL(req.url ?? '/', 'http://alert-sink').pathname;
      } catch (err) {
        // Мусорный request-target — ошибка клиента, а не сервера.
        log('warn', 'request_bad_target', {
          target: String(req.url ?? '').slice(0, 128),
          error: err?.message ?? String(err),
        });
        respond(400, 'bad request\n');
        return;
      }
      route = pathname;

      if (pathname === '/webhook') {
        if (req.method !== 'POST') {
          respond(405, 'method not allowed\n', { allow: 'POST' });
        } else {
          let raw;
          try {
            raw = await readBody(req);
          } catch (err) {
            if (err instanceof BodyTooLargeError) {
              log('warn', 'webhook_body_too_large', { limit: MAX_BODY_BYTES, error: err.message });
              respond(413, 'payload too large\n');
              return;
            }
            // Клиент ушёл посреди тела (проверено: req/res destroyed, ECONNRESET).
            // Это не отказ sink, и 500 в логе сбивал бы разбор недоставки; отвечать
            // некому, поэтому только отметка 499 — соглашение nginx «client closed».
            if (res.destroyed) {
              log('warn', 'request_aborted', { route: pathname });
              status = 499;
              return;
            }
            throw err;
          }
          let payload;
          try {
            payload = JSON.parse(raw);
          } catch (err) {
            log('warn', 'webhook_bad_json', { error: err.message, bytes: raw.length });
            respond(400, 'invalid json\n');
            return;
          }
          const problem = validatePayload(payload);
          if (problem !== null) {
            log('warn', 'webhook_invalid_payload', { error: problem });
            respondJson(400, { error: problem });
            return;
          }
          const entry = record(payload);
          respondJson(200, { status: 'ok', received_alerts: entry.alerts.length });
        }
      } else if (req.method !== 'GET') {
        respond(405, 'method not allowed\n', { allow: 'GET' });
      } else if (pathname === '/healthz') {
        // Живость без зависимостей: sink ни от чего не зависит, кроме своего процесса.
        respond(200, 'ok\n');
      } else if (pathname === '/timeline') {
        respondJson(200, timeline);
      } else if (pathname === '/metrics') {
        const body = await metrics.registry.metrics();
        respond(200, body, { 'content-type': metrics.registry.contentType });
      } else {
        respond(404, 'not found\n');
      }
    } catch (err) {
      if (res.destroyed) {
        log('warn', 'request_aborted', { route });
        status = 499;
        return;
      }
      log('error', 'request_failed', { error: err?.message ?? String(err), route });
      if (!res.headersSent) respond(500, 'internal error\n');
    } finally {
      const durationSeconds = Number(process.hrtime.bigint() - startedAt) / 1e9;
      log('info', 'http_request', {
        method: req.method,
        route,
        status,
        duration_ms: Math.round(durationSeconds * 1000),
      });
      // route здесь — уже нормализованный набор (или 'invalid' для мусорного
      // request-target): сырой путь не должен попадать в метку.
      metrics.requests.inc({ route: route === 'invalid' ? 'invalid' : routeKind(route), outcome: outcomeOf(status) });
    }
  });

  return { server, metrics, timeline, log, stop: () => server.close() };
}

function start() {
  const port = Number(process.env.PORT ?? DEFAULT_PORT);
  if (!Number.isInteger(port) || port <= 0 || port > 65_535) {
    process.stderr.write(`ERROR: PORT='${process.env.PORT}' не является номером порта\n`);
    process.exit(1);
  }
  const app = createApp();
  app.server.listen(port, () => {
    // Порт берём у сервера: при PORT=0 env врёт, а фактический порт — правда.
    app.log('info', 'sink_started', {
      port: app.server.address().port,
      timeline_size: TIMELINE_SIZE,
      timeline_max_bytes: TIMELINE_MAX_BYTES,
      max_body_bytes: MAX_BODY_BYTES,
    });
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
