// Тесты alert-sink: контракт приёма уведомлений (валидация, лимит тела), форма
// /timeline и метрики доставки. Сервер поднимается на свободном порту и гасится
// в after-хуке: проверяется поведение по HTTP, а не внутренности функций.
import assert from 'node:assert/strict';
import { once } from 'node:events';
import net from 'node:net';
import { test } from 'node:test';

import {
  createApp,
  MAX_ALERTS,
  MAX_ALERTNAME_LENGTH,
  MAX_DISTINCT_ALERTNAMES,
  MAX_BODY_BYTES,
  TIMELINE_MAX_BYTES,
  TIMELINE_SIZE,
} from '../src/sink.js';

const FIRING_PAYLOAD = {
  version: '4',
  groupKey: '{}:{alertname="SloDemoAvailabilityBurnFast"}',
  truncatedAlerts: 0,
  status: 'firing',
  receiver: 'alert-sink',
  groupLabels: { alertname: 'SloDemoAvailabilityBurnFast' },
  commonLabels: { severity: 'page', service: 'demo-api' },
  commonAnnotations: {},
  externalURL: 'http://prometheus.invalid',
  alerts: [
    {
      status: 'firing',
      labels: {
        alertname: 'SloDemoAvailabilityBurnFast',
        severity: 'page',
        service: 'demo-api',
        namespace: 'demo',
      },
      annotations: { summary: 'бюджет доступности сгорает' },
      startsAt: '2026-11-04T15:00:00Z',
      endsAt: '0001-01-01T00:00:00Z',
      generatorURL: 'http://prometheus.invalid/graph',
      fingerprint: 'abc123',
    },
  ],
};

async function startApp(t, options = {}) {
  const logs = [];
  const app = createApp({ logStream: { write: (chunk) => logs.push(chunk) }, ...options });
  app.server.listen(0, '127.0.0.1');
  await once(app.server, 'listening');
  t.after(() => {
    app.stop();
    app.server.closeAllConnections();
  });
  return { app, logs, base: `http://127.0.0.1:${app.server.address().port}` };
}

function postWebhook(base, body) {
  return fetch(`${base}/webhook`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
}

// Сумма значений серий по имени и подстроке меток — как в тестах demo-load.
function metricValue(text, name, labels = {}) {
  let sum = 0;
  for (const line of text.split('\n')) {
    if (!line.startsWith(`${name}{`) && !line.startsWith(`${name} `)) continue;
    if (!Object.entries(labels).every(([key, value]) => line.includes(`${key}="${value}"`))) continue;
    const value = Number(line.slice(line.lastIndexOf(' ') + 1).trim());
    if (Number.isFinite(value)) sum += value;
  }
  return sum;
}


// Сырой HTTP-запрос: fetch не даёт отправить непарсящийся request-target,
// а именно он ронял процесс (new URL() вне try, правка 2026-11-04).
function rawRequest(port, payload) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(port, '127.0.0.1', () => socket.write(payload));
    let data = '';
    socket.setEncoding('utf8');
    socket.on('data', (chunk) => {
      data += chunk;
    });
    socket.on('error', reject);
    socket.on('close', () => resolve(data));
    setTimeout(() => socket.destroy(), 300);
  });
}

test('валидное уведомление: 200 и запись в /timeline по контракту', async (t) => {
  const { base } = await startApp(t);
  const response = await postWebhook(base, FIRING_PAYLOAD);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { status: 'ok', received_alerts: 1 });

  const timeline = await (await fetch(`${base}/timeline`)).json();
  assert.equal(timeline.length, 1);
  const [entry] = timeline;
  assert.equal(entry.status, 'firing');
  assert.equal(entry.group_key, FIRING_PAYLOAD.groupKey);
  assert.match(entry.received_at, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);
  assert.deepEqual(entry.alerts, [
    {
      name: 'SloDemoAvailabilityBurnFast',
      status: 'firing',
      labels: FIRING_PAYLOAD.alerts[0].labels,
      starts_at: '2026-11-04T15:00:00Z',
      ends_at: '0001-01-01T00:00:00Z',
    },
  ]);
});

test('resolved-уведомление без startsAt/endsAt даёт null, а не падение', async (t) => {
  const { base } = await startApp(t);
  const response = await postWebhook(base, {
    status: 'resolved',
    alerts: [{ status: 'resolved', labels: { alertname: 'Watchdog', severity: 'info' } }],
  });
  assert.equal(response.status, 200);
  const [entry] = await (await fetch(`${base}/timeline`)).json();
  assert.equal(entry.group_key, '');
  assert.equal(entry.alerts[0].starts_at, null);
  assert.equal(entry.alerts[0].ends_at, null);
});

test('битый JSON — 400 и пустой таймлайн', async (t) => {
  const { base } = await startApp(t);
  const response = await postWebhook(base, '{"status": "firing",');
  assert.equal(response.status, 400);
  assert.equal((await (await fetch(`${base}/timeline`)).json()).length, 0);
});

test('невалидный payload — 400 с причиной, запись не создаётся', async (t) => {
  const { base } = await startApp(t);
  const cases = [
    [{ status: 'firing' }, /alerts/],
    [{ status: 'unknown', alerts: FIRING_PAYLOAD.alerts }, /status/],
    [{ status: 'firing', alerts: [] }, /alerts/],
    [{ status: 'firing', alerts: [{ status: 'firing', labels: {} }] }, /alertname/],
    [{ status: 'firing', alerts: [{ status: 'firing' }] }, /labels/],
    [{ status: 'firing', alerts: [{ status: 'bogus', labels: { alertname: 'X' } }] }, /alerts\[0\]\.status/],
    [{ status: 'firing', alerts: ['не объект'] }, /должен быть объектом/],
    [
      { status: 'firing', alerts: Array.from({ length: MAX_ALERTS + 1 }, () => ({ status: 'firing', labels: { alertname: 'X' } })) },
      /больше 200/,
    ],
    [
      { status: 'firing', alerts: [{ status: 'firing', labels: { alertname: 'X'.repeat(MAX_ALERTNAME_LENGTH + 1) } }] },
      /длиннее 128/,
    ],
    [[FIRING_PAYLOAD], /JSON-объектом/],
  ];
  for (const [payload, pattern] of cases) {
    const response = await postWebhook(base, payload);
    assert.equal(response.status, 400, `ожидался 400 для ${JSON.stringify(payload)}`);
    assert.match((await response.json()).error, pattern);
  }
  assert.equal((await (await fetch(`${base}/timeline`)).json()).length, 0);
});

test('тело больше 1 MiB — 413', async (t) => {
  const { base } = await startApp(t);
  const oversized = `{"status":"firing","padding":"${'x'.repeat(MAX_BODY_BYTES)}","alerts":[]}`;
  const response = await postWebhook(base, oversized);
  assert.equal(response.status, 413);
  assert.equal((await (await fetch(`${base}/timeline`)).json()).length, 0);
});

test('метрики: уведомления по статусу и severity, события алертов, время последнего', async (t) => {
  const { base } = await startApp(t, { clock: () => new Date('2026-11-04T15:30:00Z') });
  await postWebhook(base, FIRING_PAYLOAD);
  await postWebhook(base, {
    status: 'resolved',
    alerts: [
      // Уведомление без severity: в метрику идёт "none", иначе серия была бы пустой.
      { status: 'resolved', labels: { alertname: 'Watchdog' } },
    ],
  });
  const body = await (await fetch(`${base}/metrics`)).text();
  assert.equal(metricValue(body, 'alertsink_notifications_total', { status: 'firing', severity: 'page' }), 1);
  assert.equal(metricValue(body, 'alertsink_notifications_total', { status: 'resolved', severity: 'none' }), 1);
  assert.equal(
    metricValue(body, 'alertsink_alert_events_total', { alertname: 'SloDemoAvailabilityBurnFast', status: 'firing' }),
    1,
  );
  assert.equal(metricValue(body, 'alertsink_alert_events_total', { alertname: 'Watchdog', status: 'resolved' }), 1);
  assert.equal(
    metricValue(body, 'alertsink_last_notification_timestamp_seconds'),
    Date.parse('2026-11-04T15:30:00Z') / 1000,
  );
});

test(`кольцо /timeline хранит последние ${TIMELINE_SIZE} уведомлений`, async (t) => {
  const { base } = await startApp(t);
  const total = TIMELINE_SIZE + 5;
  for (let i = 0; i < total; i += 1) {
    const response = await postWebhook(base, { ...FIRING_PAYLOAD, groupKey: `group-${i}` });
    assert.equal(response.status, 200);
  }
  const timeline = await (await fetch(`${base}/timeline`)).json();
  assert.equal(timeline.length, TIMELINE_SIZE);
  assert.equal(timeline[0].group_key, `group-${total - TIMELINE_SIZE}`);
  assert.equal(timeline.at(-1).group_key, `group-${total - 1}`);
});

test(`кольцо /timeline ограничено и по байтам (${TIMELINE_MAX_BYTES} B), не только по записям`, async (t) => {
  const { base } = await startApp(t);
  // Одна метка на ~300 КБ: тело каждого запроса меньше MAX_BODY_BYTES, но 20 таких
  // записей — ~6 МБ, то есть заведомо больше бюджета кольца.
  const blob = 'x'.repeat(300 * 1024);
  const posts = 20;
  for (let i = 0; i < posts; i += 1) {
    const response = await postWebhook(base, {
      ...FIRING_PAYLOAD,
      groupKey: `big-${i}`,
      alerts: [{ status: 'firing', labels: { alertname: 'BigPayload', blob } }],
    });
    assert.equal(response.status, 200);
  }
  const timeline = await (await fetch(`${base}/timeline`)).json();
  assert.ok(timeline.length < posts, `старые записи должны вытесняться, а их ${timeline.length}`);
  // Последняя запись остаётся всегда: даже один payload больше бюджета не стирает себя.
  assert.equal(timeline.at(-1).group_key, `big-${posts - 1}`);
  const bytes = timeline.reduce((sum, entry) => sum + Buffer.byteLength(JSON.stringify(entry), 'utf8'), 0);
  assert.ok(bytes <= TIMELINE_MAX_BYTES, `кольцо занимает ${bytes} B при бюджете ${TIMELINE_MAX_BYTES} B`);
  // Нижние границы: иначе тест проходил бы и на кольце из одной записи.
  assert.ok(timeline.length >= 5, `кольцо заполнено всего на ${timeline.length} записей`);
  assert.ok(
    bytes > TIMELINE_MAX_BYTES - 400 * 1024,
    `кольцо недозаполнено: ${bytes} B при бюджете ${TIMELINE_MAX_BYTES} B`,
  );
});

test('truncated_alerts из payload виден в записи /timeline (по умолчанию 0)', async (t) => {
  const { base } = await startApp(t);
  await postWebhook(base, { ...FIRING_PAYLOAD, truncatedAlerts: 7 });
  await postWebhook(base, { ...FIRING_PAYLOAD, groupKey: 'group-without-truncation' });
  const timeline = await (await fetch(`${base}/timeline`)).json();
  assert.equal(timeline[0].truncated_alerts, 7);
  assert.equal(timeline[1].truncated_alerts, 0);
});

test('обрыв клиента посреди тела: лог request_aborted, метрика aborted, процесса жив', async (t) => {
  const { base, app, logs } = await startApp(t);
  const socket = net.connect(app.server.address().port, '127.0.0.1', () => {
    socket.write(
      'POST /webhook HTTP/1.1\r\nHost: test\r\nContent-Type: application/json\r\nContent-Length: 1000\r\n\r\n{"status":',
    );
    setTimeout(() => socket.destroy(), 30);
  });
  socket.on('error', () => {});

  // Ждём, пока сервер обработает обрыв (опрос вместо фиксированной паузы).
  let metric = '';
  for (let attempt = 0; attempt < 20; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 50));
    metric = await (await fetch(`${base}/metrics`)).text();
    if (metricValue(metric, 'alertsink_requests_total', { route: '/webhook', outcome: 'aborted' }) > 0) break;
  }
  assert.equal(metricValue(metric, 'alertsink_requests_total', { route: '/webhook', outcome: 'aborted' }), 1);
  assert.equal((await fetch(`${base}/healthz`)).status, 200);

  const entries = logs
    .map((chunk) => chunk.trim())
    .filter(Boolean)
    .map((chunk) => JSON.parse(chunk));
  assert.equal(entries.filter((entry) => entry.msg === 'request_aborted').length, 1);
  // Обрыв клиента — не отказ сервера: 500 в логе сбивал бы разбор недоставки.
  assert.equal(entries.filter((entry) => entry.msg === 'request_failed').length, 0);
  const webhookLogs = entries.filter((entry) => entry.msg === 'http_request' && entry.route === '/webhook');
  assert.equal(webhookLogs.at(-1).status, 499);
});

test('молчащий клиент с Content-Length: 408 за конечное время и метрика client_error', async (t) => {
  const { base, app, logs } = await startApp(t, { bodyReadTimeoutMs: 200 });
  const socket = net.connect(app.server.address().port, '127.0.0.1', () => {
    socket.write(
      'POST /webhook HTTP/1.1\r\nHost: test\r\nContent-Type: application/json\r\nContent-Length: 1000\r\n\r\n{"status":',
    );
  });
  socket.on('error', () => {});
  socket.setEncoding('utf8');
  let response = '';
  const closed = new Promise((resolve) => {
    socket.on('data', (chunk) => {
      response += chunk;
    });
    socket.on('close', resolve);
    setTimeout(resolve, 3000);
  });
  await closed;
  // 408, а не бесконечное ожидание: клиент прислал заголовки и замолчал.
  assert.match(response, /^HTTP\/1\.1 408/);

  const body = await (await fetch(`${base}/metrics`)).text();
  assert.equal(metricValue(body, 'alertsink_requests_total', { route: '/webhook', outcome: 'client_error' }), 1);
  const entries = logs
    .map((chunk) => chunk.trim())
    .filter(Boolean)
    .map((chunk) => JSON.parse(chunk));
  assert.equal(entries.filter((entry) => entry.msg === 'webhook_body_timeout').length, 1);
  assert.equal(
    entries.filter((entry) => entry.msg === 'http_request' && entry.route === '/webhook').at(-1).status,
    408,
  );
});

test('после таймаута чтения тела сервер закрывается штатно', async () => {
  const app = createApp({ logStream: { write: () => {} }, bodyReadTimeoutMs: 100 });
  app.server.listen(0, '127.0.0.1');
  await once(app.server, 'listening');
  const socket = net.connect(app.server.address().port, '127.0.0.1', () => {
    socket.write(
      'POST /webhook HTTP/1.1\r\nHost: test\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n{"status":',
    );
  });
  socket.on('error', () => {});
  // Читаем ответ, иначе приостановленный сокет не отдаёт 'close' — тест ждал бы
  // таймаута, ничего не проверяя.
  socket.setEncoding('utf8');
  socket.on('data', () => {});
  await new Promise((resolve) => {
    socket.on('close', resolve);
    setTimeout(resolve, 3000);
  });
  // Незавершённое чтение не должно держать сокет: иначе close() висит, а под
  // не проходит graceful shutdown.
  await new Promise((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error('server.close() не завершился: сокет остался открыт')),
      2000,
    );
    app.server.close(() => {
      clearTimeout(timer);
      resolve();
    });
  });
});

test('метрика запросов: маршруты нормализованы, произвольный путь не создаёт серий', async (t) => {
  const { base, logs } = await startApp(t);
  const token = `nope-${Math.random().toString(16).slice(2, 10)}`;
  assert.equal((await fetch(`${base}/${token}`)).status, 404);
  assert.equal((await fetch(`${base}/healthz`)).status, 200);
  const body = await (await fetch(`${base}/metrics`)).text();
  assert.equal(metricValue(body, 'alertsink_requests_total', { route: 'other', outcome: 'client_error' }), 1);
  assert.equal(metricValue(body, 'alertsink_requests_total', { route: '/healthz', outcome: 'ok' }), 1);
  assert.ok(!body.includes(token), 'сырой путь не должен попадать в метки Prometheus');
  // Лог — второй канал, и сырой путь в нём тоже не нужен: разбор в Loki не должен
  // зависеть от того, что написал клиент.
  const request = logs
    .map((chunk) => chunk.trim())
    .filter(Boolean)
    .map((chunk) => JSON.parse(chunk))
    .find((entry) => entry.msg === 'http_request' && entry.status === 404);
  assert.equal(request.route, 'other');
});

test('служебные маршруты: /healthz, 404, 405 и JSON-логи', async (t) => {
  const { base, logs } = await startApp(t);
  assert.equal((await fetch(`${base}/healthz`)).status, 200);
  assert.equal((await fetch(`${base}/nope`)).status, 404);
  assert.equal((await fetch(`${base}/webhook`)).status, 405);
  await postWebhook(base, FIRING_PAYLOAD);

  const entries = logs
    .map((chunk) => chunk.trim())
    .filter(Boolean)
    .map((chunk) => JSON.parse(chunk));
  const received = entries.find((entry) => entry.msg === 'notification_received');
  assert.deepEqual(received.alerts, ['SloDemoAvailabilityBurnFast:firing']);
  assert.equal(received.severity, 'page');
  // Событий /webhook два (405 на GET и 200 на POST) — проверяем последнее.
  const request = entries.filter((entry) => entry.msg === 'http_request' && entry.route === '/webhook').at(-1);
  assert.equal(request.status, 200);
  assert.equal(typeof request.duration_ms, 'number');
});

test('мусорный request-target: 400 и процесс жив', async (t) => {
  const { base, app } = await startApp(t);
  const response = await rawRequest(
    app.server.address().port,
    'GET http://[::1 HTTP/1.1\r\nHost: test\r\n\r\n',
  );
  assert.match(response, /^HTTP\/1\.1 400/);
  // Кольцо /timeline живёт в памяти: падение процесса стёрло бы evidence дрилла.
  assert.equal((await fetch(`${base}/healthz`)).status, 200);
  // У мусорного target своя серия: он не «другой маршрут», а невалидный запрос.
  const body = await (await fetch(`${base}/metrics`)).text();
  assert.equal(metricValue(body, 'alertsink_requests_total', { route: 'invalid', outcome: 'client_error' }), 1);
});

test('смешанные severity: метка — старшая (page > ticket > info), без severity — none', async (t) => {
  const { base } = await startApp(t);
  const alert = (name, severity) => ({
    status: 'firing',
    labels: severity === undefined ? { alertname: name } : { alertname: name, severity },
  });
  await postWebhook(base, {
    status: 'firing',
    alerts: [alert('a-info', 'info'), alert('a-page', 'page'), alert('a-ticket', 'ticket'), alert('a-none')],
  });
  const body = await (await fetch(`${base}/metrics`)).text();
  assert.equal(metricValue(body, 'alertsink_notifications_total', { status: 'firing', severity: 'page' }), 1);
  assert.equal(metricValue(body, 'alertsink_notifications_total', { status: 'firing', severity: 'ticket' }), 0);
  assert.equal(metricValue(body, 'alertsink_notifications_total', { status: 'firing', severity: 'info' }), 0);
  assert.equal(metricValue(body, 'alertsink_notifications_total', { status: 'firing', severity: 'none' }), 0);
});

test(`различных alertname не больше ${MAX_DISTINCT_ALERTNAMES}: сверх лимита — other`, async (t) => {
  const { base } = await startApp(t);
  for (let i = 0; i <= MAX_DISTINCT_ALERTNAMES; i += 1) {
    const response = await postWebhook(base, {
      status: 'firing',
      alerts: [{ status: 'firing', labels: { alertname: `Unique${i}` } }],
    });
    assert.equal(response.status, 200);
  }
  const overflowName = `Unique${MAX_DISTINCT_ALERTNAMES}`;
  const body = await (await fetch(`${base}/metrics`)).text();
  assert.equal(metricValue(body, 'alertsink_alert_events_total', { alertname: 'other' }), 1);
  assert.ok(!body.includes(overflowName), 'имя сверх лимита не должно попадать в метрики');
  // Кольцо доказательств не страдает: в /timeline имя алерта настоящее.
  const timeline = await (await fetch(`${base}/timeline`)).json();
  assert.equal(timeline.at(-1).alerts[0].name, overflowName);
});

test('служебные метрики процесса отдаются с префиксом alertsink_', async (t) => {
  const { base } = await startApp(t);
  const body = await (await fetch(`${base}/metrics`)).text();
  assert.match(body, /^alertsink_process_resident_memory_bytes /m);
});

test('отклонённое уведомление (400/413) не трогает метрики и кольцо', async (t) => {
  const { base } = await startApp(t);
  await postWebhook(base, { status: 'firing', alerts: [] });
  await postWebhook(base, `{"status":"firing","padding":"${'x'.repeat(MAX_BODY_BYTES)}"}`);
  const body = await (await fetch(`${base}/metrics`)).text();
  assert.equal(metricValue(body, 'alertsink_notifications_total'), 0);
  assert.equal(metricValue(body, 'alertsink_alert_events_total'), 0);
  assert.equal(metricValue(body, 'alertsink_last_notification_timestamp_seconds'), 0);
  assert.equal((await (await fetch(`${base}/timeline`)).json()).length, 0);
});
