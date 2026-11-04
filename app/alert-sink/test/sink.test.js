// Тесты alert-sink: контракт приёма уведомлений (валидация, лимит тела), форма
// /timeline и метрики доставки. Сервер поднимается на свободном порту и гасится
// в after-хуке: проверяется поведение по HTTP, а не внутренности функций.
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { test } from 'node:test';

import { createApp, MAX_BODY_BYTES, TIMELINE_SIZE } from '../src/sink.js';

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
