// alert-sink — приёмник уведомлений Alertmanager.
//
// Зачем отдельный сервис: Alertmanager принадлежит чарту, и «алерт сработал» ещё не
// значит «уведомление дошло». Sink принимает webhook Alertmanager v2, хранит кольцо
// последних уведомлений в памяти (/timeline читают дриллы и живая проверка)
// и считает метрики доставки. Внешних зависимостей нет, только prom-client.
import http from 'node:http';
import { pathToFileURL } from 'node:url';

import { Counter, Gauge, Registry, collectDefaultMetrics } from 'prom-client';

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
// а число алертов — числом серий и записей кольца. MAX_ALERTS ограничивает один запрос,
// MAX_DISTINCT_ALERTNAMES — число разных имён за всё время жизни процесса: имена сверх
// лимита учитываются как alertname="other", само имя остаётся в /timeline. Без этих
// границ любой под в кластере POST'ом создавал бы произвольную кардинальность
// (нашло ревью 2026-11-04).
export const MAX_ALERTS = 200;
export const MAX_ALERTNAME_LENGTH = 128;
export const MAX_DISTINCT_ALERTNAMES = 200;

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
  // Процессные метрики (cpu, память, event loop, gc) с префиксом alertsink_:
  // без них не отличить «sink медленный» от «sink задыхается по памяти».
  collectDefaultMetrics({ register: registry, prefix: 'alertsink_' });

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

  // Время начала алерта (startsAt из payload). Счётчик его не несёт: в Grafana таблица
  // instant-запроса показывает в колонке Time момент самого запроса, то есть «сейчас», и
  // по таблице нельзя было понять, когда алерт начался. Метки те же, что у счётчика,
  // поэтому кардинальность ограничена тем же лимитом имён.
  const alertStarted = new Gauge({
    name: 'alertsink_alert_start_timestamp_seconds',
    help: 'Unix-время начала алерта (startsAt), последнее по паре alertname/status',
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

  return { registry, notifications, alertEvents, alertStarted, lastNotification, requests };
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

// Время начала алерта: startsAt Alertmanager (RFC3339). Поле не входит в обязательные
// (payload приходит и от чужих клиентов), поэтому отсутствие или мусор — не 400, а
// время приёма: пара обязана получить значение, иначе таблица покажет «нет данных» и
// отличить «алертов не было» от «время потеряли» будет нельзя.
function alertStartSeconds(alert, receivedAt) {
  const parsed = typeof alert.startsAt === 'string' ? Date.parse(alert.startsAt) : Number.NaN;
  return Number.isFinite(parsed) ? parsed / 1000 : receivedAt.getTime() / 1000;
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

// Форма записи /timeline зафиксирована контрактом: поля snake_case, starts_at/
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
// Обрыв клиента посреди тела: отвечать некому, но запрос надо учесть (499).
class BodyAbortedError extends Error {}
// Клиент прислал заголовки и молчит: без таймаута сокет и промис живут бесконечно.
class BodyTimeoutError extends Error {}

export const BODY_READ_TIMEOUT_MS = 30_000;

// Чтение тела с лимитом. Сверх лимита тело дочитывается вхолостую (chunks не растут),
// поэтому клиент получает 413, а не обрыв соединения до ответа.
// Чтение всегда завершается: либо данными, либо обрывом клиента (BodyAbortedError),
// либо таймаутом (BodyTimeoutError) — иначе запрос висит, пока клиент не уйдёт.
function readBody(req, limit = MAX_BODY_BYTES, timeoutMs = BODY_READ_TIMEOUT_MS) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    let tooLarge = false;
    let settled = false;
    let timer;

    const onData = (chunk) => {
      size += chunk.length;
      if (size > limit) {
        tooLarge = true;
        chunks.length = 0;
        return;
      }
      chunks.push(chunk);
    };
    const cleanup = () => {
      clearTimeout(timer);
      req.off('data', onData);
      req.off('end', onEnd);
      req.off('error', onError);
      req.off('close', onClose);
    };
    const fail = (err) => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(err);
    };
    const onEnd = () => {
      if (settled) return;
      settled = true;
      cleanup();
      if (tooLarge) {
        reject(new BodyTooLargeError(`тело больше ${limit} байт`));
        return;
      }
      resolve(Buffer.concat(chunks).toString('utf8'));
    };
    const onError = (err) => fail(err);
    // 'close' без 'end' — соединение оборвалось. req.complete снимает ложное
    // срабатывание при нормальном завершении, когда close приходит после end.
    const onClose = () => {
      if (!req.complete) fail(new BodyAbortedError('клиент закрыл соединение до конца тела'));
    };

    timer = setTimeout(() => fail(new BodyTimeoutError(`тело не дочитано за ${timeoutMs} мс`)), timeoutMs);
    timer.unref();
    req.on('data', onData);
    req.on('end', onEnd);
    req.on('error', onError);
    req.on('close', onClose);
  });
}

export function createApp({
  logStream = process.stdout,
  clock = () => new Date(),
  bodyReadTimeoutMs = BODY_READ_TIMEOUT_MS,
} = {}) {
  const metrics = createMetrics();
  const log = createLogger(logStream);
  const timeline = [];
  // Размеры записей в байтах — параллельный массив: кольцо держим по двум пределам
  // (число записей и байты), не меняя публичную форму записи /timeline.
  const timelineSizes = [];
  let timelineBytes = 0;
  // Различные alertname, уже создавшие серию в метрике. Ограничение действует на
  // весь процесс: Set растёт до MAX_DISTINCT_ALERTNAMES и дальше не пополняется.
  const seenAlertnames = new Set();
  // Начало алерта по паре alertname/status — та же граница кардинальности, что у
  // счётчика: Map растёт вместе с seenAlertnames (≤ MAX_DISTINCT_ALERTNAMES × 2).
  const alertStarts = new Map();

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
      const alertname = alert.labels.alertname;
      // Имя сверх лимита не создаёт новую серию: кардинальность метрики ограничена
      // даже если клиент присылает уникальные имена. В /timeline имя настоящее.
      let seriesName = alertname;
      if (!seenAlertnames.has(alertname)) {
        if (seenAlertnames.size >= MAX_DISTINCT_ALERTNAMES) {
          seriesName = 'other';
        } else {
          seenAlertnames.add(alertname);
        }
      }
      metrics.alertEvents.inc({ alertname: seriesName, status: alert.status });

      // Начало алерта — максимум по паре: повторное уведомление о том же горящем
      // алерте несёт тот же startsAt, а новый экземпляр — более поздний; доставка
      // вне порядка не должна откатывать время назад.
      const started = alertStartSeconds(alert, receivedAt);
      const key = `${seriesName}\u0000${alert.status}`;
      const previous = alertStarts.get(key);
      if (previous === undefined || started > previous) {
        alertStarts.set(key, started);
        metrics.alertStarted.set({ alertname: seriesName, status: alert.status }, started);
      }
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
      route = routeKind(pathname);

      if (pathname === '/webhook') {
        if (req.method !== 'POST') {
          respond(405, 'method not allowed\n', { allow: 'POST' });
        } else {
          let raw;
          try {
            raw = await readBody(req, MAX_BODY_BYTES, bodyReadTimeoutMs);
          } catch (err) {
            if (err instanceof BodyTooLargeError) {
              log('warn', 'webhook_body_too_large', { limit: MAX_BODY_BYTES, error: err.message });
              respond(413, 'payload too large\n');
              return;
            }
            // Клиент ушёл посреди тела (req/res destroyed, ECONNRESET). Это не отказ
            // sink, и 500 в логе сбивал бы разбор недоставки; отвечать некому,
            // поэтому только отметка 499 — соглашение nginx «client closed».
            if (err instanceof BodyAbortedError) {
              log('warn', 'request_aborted', { route });
              status = 499;
              return;
            }
            // Тело не дочитано за отведённое время: отвечаем 408 и рвём соединение,
            // иначе сокет и промис останутся в памяти навсегда.
            if (err instanceof BodyTimeoutError) {
              log('warn', 'webhook_body_timeout', {
                route,
                timeout_ms: bodyReadTimeoutMs,
                error: err.message,
              });
              respond(408, 'request timeout\n');
              // Сокет закрываем после того, как ответ ушёл: destroy() сразу после
              // end() может оборвать буфер и клиент не увидит 408.
              res.once('finish', () => req.destroy());
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
      // Поля как в http_request: статус и длительность считаем до лога.
      const durationSeconds = Number(process.hrtime.bigint() - startedAt) / 1e9;
      log('error', 'request_failed', {
        route,
        status,
        duration_ms: Math.round(durationSeconds * 1000),
        error: err?.message ?? String(err),
      });
      if (!res.headersSent) respond(500, 'internal error\n');
    } finally {
      const durationSeconds = Number(process.hrtime.bigint() - startedAt) / 1e9;
      log('info', 'http_request', {
        method: req.method,
        route,
        status,
        duration_ms: Math.round(durationSeconds * 1000),
      });
      // route уже нормализован (routeKind) или 'invalid' для мусорного
      // request-target: сырой путь не должен попадать в метку.
      metrics.requests.inc({ route, outcome: outcomeOf(status) });
    }
  });

  return {
    server,
    metrics,
    timeline,
    log,
    // stop() возвращает промис close: SIGTERM ждёт завершения, а не обрывает
    // соединения мгновенным process.exit.
    stop: () => new Promise((resolve) => server.close(resolve)),
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
    app.stop().then(() => process.exit(0));
    // Если соединения не закрылись за 5 с — выходим принудительно.
    setTimeout(() => process.exit(1), 5000).unref();
  });
}

const invokedDirectly =
  process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href;
if (invokedDirectly) start();
