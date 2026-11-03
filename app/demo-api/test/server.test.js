// Тесты demo-api: поднимают сервер на свободном порту и проверяют контракт
// (коды, метрики, форму логов) без кластера и без реального SIGTERM.
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { test } from 'node:test';

import { createApp, routeTemplate } from '../src/server.js';

// Возвращает строку метрики по имени и подмножеству меток; 0, если серии нет.
function metricValue(text, name, labels = {}) {
  let sum = 0;
  for (const line of text.split('\n')) {
    if (!line.startsWith(`${name}{`)) continue;
    const labelPart = line.slice(name.length + 1, line.lastIndexOf('}'));
    const matches = Object.entries(labels).every(([k, v]) => labelPart.includes(`${k}="${v}"`));
    if (!matches) continue;
    const value = Number(line.slice(line.lastIndexOf('}') + 1).trim());
    if (Number.isFinite(value)) sum += value;
  }
  return sum;
}

async function withApp(fn, options = {}) {
  const lines = [];
  const logStream = { write: (chunk) => lines.push(chunk) };
  const app = createApp({ logStream, ...options });
  app.server.listen(0, '127.0.0.1');
  await once(app.server, 'listening');
  const base = `http://127.0.0.1:${app.server.address().port}`;
  try {
    await fn({ base, app, lines });
  } finally {
    await new Promise((resolve) => app.server.close(resolve));
  }
}

test('GET /healthz отвечает 200 без зависимостей', async () => {
  await withApp(async ({ base }) => {
    const res = await fetch(`${base}/healthz`);
    assert.equal(res.status, 200);
    assert.equal(await res.text(), 'ok\n');
  });
});

test('GET /ready отвечает 200, пока не идёт shutdown', async () => {
  await withApp(async ({ base }) => {
    const res = await fetch(`${base}/ready`);
    assert.equal(res.status, 200);
  });
});

test('GET /ready отдаёт 503 после начала shutdown', async () => {
  await withApp(async ({ base, app }) => {
    app.beginShutdown();
    const res = await fetch(`${base}/ready`);
    assert.equal(res.status, 503);
    // Живость при этом остаётся 200: под не убивают раньше времени.
    assert.equal((await fetch(`${base}/healthz`)).status, 200);
  });
});

test('GET /metrics содержит http_requests_total, гистограмму и бакет le="0.3"', async () => {
  await withApp(async ({ base }) => {
    await fetch(`${base}/work`);
    const res = await fetch(`${base}/metrics`);
    assert.equal(res.status, 200);
    const body = await res.text();
    assert.match(body, /^http_requests_total\{/m);
    assert.match(body, /^http_request_duration_seconds_bucket\{/m);
    assert.match(body, /http_request_duration_seconds_bucket\{[^}]*le="0\.3"[^}]*\}/);
    assert.match(body, /^http_inflight_requests\{?/m);
    assert.match(body, /^demo_process_cpu_seconds_total/m);
  });
});

test('404 не увеличивает счётчик успешных ответов и не плодит маршруты', async () => {
  await withApp(async ({ base }) => {
    await fetch(`${base}/nope`);
    const body = await (await fetch(`${base}/metrics`)).text();
    assert.equal(metricValue(body, 'http_requests_total', { route: 'other', status_class: '2xx' }), 0);
    assert.equal(metricValue(body, 'http_requests_total', { route: 'other', status_class: '4xx' }), 1);
    // Сырой URL в метку не попадает: иначе кардинальность растёт на каждом запросе.
    assert.doesNotMatch(body, /route="\/nope"/);
  });
});

test('status_class соответствует коду ответа', async () => {
  await withApp(async ({ base }) => {
    await fetch(`${base}/healthz`);
    await fetch(`${base}/nope`);
    const body = await (await fetch(`${base}/metrics`)).text();
    assert.equal(metricValue(body, 'http_requests_total', { route: '/healthz', status_class: '2xx' }), 1);
    assert.equal(metricValue(body, 'http_requests_total', { route: 'other', status_class: '4xx' }), 1);
  });
});

test('лог запроса — одна валидная JSON-строка с полями контракта', async () => {
  await withApp(async ({ base, lines }) => {
    await fetch(`${base}/work`, { headers: { 'x-request-id': 'test-request-id' } });
    const entry = lines
      .map((chunk) => chunk.trim())
      .filter(Boolean)
      .map((chunk) => JSON.parse(chunk))
      .find((line) => line.msg === 'http_request');
    assert.ok(entry, 'в логе нет события http_request');
    assert.equal(entry.level, 'info');
    assert.equal(entry.request_id, 'test-request-id');
    assert.equal(entry.method, 'GET');
    assert.equal(entry.route, '/work');
    assert.equal(entry.status, 200);
    assert.equal(typeof entry.duration_ms, 'number');
    assert.match(entry.ts, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/);
  });
});

test('без X-Request-Id идентификатор запроса генерируется', async () => {
  await withApp(async ({ base, lines }) => {
    await fetch(`${base}/healthz`);
    const entry = lines
      .map((chunk) => chunk.trim())
      .filter(Boolean)
      .map((chunk) => JSON.parse(chunk))
      .find((line) => line.msg === 'http_request');
    assert.match(entry.request_id, /^[0-9a-f-]{36}$/);
  });
});

test('неизвестный путь маршрутизируется в шаблон other', () => {
  assert.equal(routeTemplate('/work'), '/work');
  assert.equal(routeTemplate('/work/123'), 'other');
});