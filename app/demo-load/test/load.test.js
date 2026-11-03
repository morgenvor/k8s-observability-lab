// Тесты demo-load: классификация исходов по клиентской стороне и экспозиция метрик.
// Upstream — настоящий локальный http-сервер, чтобы сценарии ошибок были реальными.
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import { test } from 'node:test';

import { createApp, probe } from '../src/load.js';

async function startUpstream(handler) {
  const server = http.createServer(handler);
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  return { url: `http://127.0.0.1:${server.address().port}/work`, server };
}

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

test('ответ 2xx классифицируется как ok', async () => {
  const { url, server } = await startUpstream((req, res) => res.end('ok'));
  try {
    const result = await probe(url);
    assert.equal(result.outcome, 'ok');
    assert.equal(result.status, 200);
    assert.ok(result.durationSeconds >= 0);
  } finally {
    server.close();
  }
});

test('ответ не 2xx классифицируется как error', async () => {
  const { url, server } = await startUpstream((req, res) => {
    res.statusCode = 503;
    res.end('nope');
  });
  try {
    const result = await probe(url);
    assert.equal(result.outcome, 'error');
    assert.equal(result.status, 503);
  } finally {
    server.close();
  }
});

test('недоступный upstream даёт outcome="error", а не падение', async () => {
  const { url, server } = await startUpstream((req, res) => res.end('ok'));
  server.close(); // порт закрыт: соединение будет отвергнуто
  const result = await probe(url, { timeoutMs: 500 });
  assert.equal(result.outcome, 'error');
  assert.equal(result.status, null);
});

test('превышение таймаута классифицируется как timeout', async () => {
  const { url, server } = await startUpstream((req, res) => {
    setTimeout(() => res.end('late'), 500);
  });
  try {
    const result = await probe(url, { timeoutMs: 50 });
    assert.equal(result.outcome, 'timeout');
  } finally {
    server.close();
  }
});

test('/metrics отдаёт load_requests_total и бакет le="0.3"', async () => {
  const lines = [];
  const app = createApp({
    logStream: { write: (chunk) => lines.push(chunk) },
    targetUrl: 'http://upstream.invalid/work',
    fetchImpl: async () => ({ ok: true, status: 200, arrayBuffer: async () => new ArrayBuffer(0) }),
  });
  app.server.listen(0, '127.0.0.1');
  await once(app.server, 'listening');
  const base = `http://127.0.0.1:${app.server.address().port}`;
  try {
    assert.equal((await fetch(`${base}/healthz`)).status, 200);
    await new Promise((resolve) => setTimeout(resolve, 600)); // хотя бы один тик нагрузки
    const body = await (await fetch(`${base}/metrics`)).text();
    assert.match(body, /^load_requests_total\{outcome="ok"\} [1-9]/m);
    assert.match(body, /^load_request_duration_seconds_bucket\{[^}]*le="0\.3"[^}]*\}/m);
    const entry = lines
      .map((chunk) => chunk.trim())
      .filter(Boolean)
      .map((chunk) => JSON.parse(chunk))
      .find((line) => line.msg === 'load_request');
    assert.equal(entry.outcome, 'ok');
    assert.equal(typeof entry.duration_ms, 'number');
  } finally {
    app.stop();
  }
});

test('stop() останавливает цикл: новых прогонов нагрузки нет', async () => {
  const calls = [];
  const app = createApp({
    logStream: { write: () => {} },
    targetUrl: 'http://upstream.invalid/work',
    fetchImpl: async () => {
      calls.push(Date.now());
      return { ok: true, status: 200, arrayBuffer: async () => new ArrayBuffer(0) };
    },
  });
  app.server.listen(0, '127.0.0.1');
  await once(app.server, 'listening');
  await new Promise((resolve) => setTimeout(resolve, 500)); // хотя бы один тик
  const before = calls.length;
  assert.ok(before > 0, 'цикл не запустился');
  app.stop();
  await new Promise((resolve) => setTimeout(resolve, 500));
  assert.equal(calls.length, before, 'после stop() цикл продолжает работу');
});
