// Тесты demo-load: классификация исходов по клиентской стороне и экспозиция метрик.
// Upstream — настоящий локальный http-сервер, чтобы сценарии ошибок были реальными.
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import net from 'node:net';
import { test } from 'node:test';

import { createApp, MAX_UPSTREAM_BODY_BYTES, probe } from '../src/load.js';

async function startUpstream(handler) {
  const server = http.createServer(handler);
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  return { url: `http://127.0.0.1:${server.address().port}/work`, server };
}

// Ответ upstream для мока fetchImpl: пустое тело через штатный reader
// (probe дочитывает тело с пределом и без getReader не работает).
function okUpstream() {
  return {
    ok: true,
    status: 200,
    body: {
      getReader: () => ({
        read: async () => ({ done: true, value: undefined }),
        cancel: async () => {},
        releaseLock: () => {},
      }),
    },
  };
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
    fetchImpl: async () => okUpstream(),
  });
  app.server.listen(0, '127.0.0.1');
  await once(app.server, 'listening');
  const base = `http://127.0.0.1:${app.server.address().port}`;
  try {
    assert.equal((await fetch(`${base}/healthz`)).status, 200);
    await new Promise((resolve) => setTimeout(resolve, 600)); // хотя бы один тик нагрузки
    const body = await (await fetch(`${base}/metrics`)).text();
    assert.match(body, /^load_requests_total\{outcome="ok"\} [1-9]/m);
    // Именно значение, а не только наличие серии: бакет должен быть наполнен.
    assert.match(body, /^load_request_duration_seconds_bucket\{[^}]*le="0\.3"[^}]*\} [1-9]/m);
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

// Сырой HTTP-запрос: fetch не даёт отправить непарсящийся request-target,
// а именно он ронял процесс (new URL() вне try).
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
    // Ответ приходит с keep-alive, сам сокет не закроется — закрываем после ответа.
    setTimeout(() => socket.destroy(), 300);
  });
}

test('мусорный request-target: 400 и сервер жив', async () => {
  const lines = [];
  const app = createApp({
    logStream: { write: (chunk) => lines.push(chunk) },
    targetUrl: 'http://upstream.invalid/work',
    fetchImpl: async () => okUpstream(),
  });
  app.server.listen(0, '127.0.0.1');
  await once(app.server, 'listening');
  const base = `http://127.0.0.1:${app.server.address().port}`;
  try {
    const response = await rawRequest(
      app.server.address().port,
      'GET http://[::1 HTTP/1.1\r\nHost: test\r\n\r\n',
    );
    assert.match(response, /^HTTP\/1\.1 400/);
    // Сервер обязан продолжать обслуживать запросы: до правки здесь был
    // unhandled rejection и завершение процесса.
    assert.equal((await fetch(`${base}/healthz`)).status, 200);
    const entry = lines
      .map((chunk) => chunk.trim())
      .filter(Boolean)
      .map((chunk) => JSON.parse(chunk))
      .find((line) => line.msg === 'request_bad_target');
    assert.ok(entry, 'в логе нет request_bad_target');
    assert.match(entry.target, /\[::1/);
  } finally {
    await app.stop();
  }
});

test('некорректные параметры нагрузки отклоняются с понятной ошибкой', () => {
  const base = { logStream: { write: () => {} }, targetUrl: 'http://upstream.invalid/work' };
  assert.throws(() => createApp({ ...base, rps: 0 }), /rps должен быть положительным числом/);
  assert.throws(() => createApp({ ...base, rps: Number.NaN }), /rps/);
  assert.throws(() => createApp({ ...base, concurrency: 0 }), /concurrency должен быть положительным целым/);
  assert.throws(() => createApp({ ...base, timeoutMs: -1 }), /timeoutMs/);
});

test('ответ upstream больше лимита: outcome="error", процесс жив', async () => {
  const { url, server } = await startUpstream((req, res) => {
    res.end('x'.repeat(MAX_UPSTREAM_BODY_BYTES + 1));
  });
  try {
    const result = await probe(url);
    assert.equal(result.outcome, 'error');
    assert.equal(result.status, 200);
    assert.equal(result.bodyTooLarge, true);
  } finally {
    server.close();
  }
  // Следующий запрос работает: превышение лимита не ломает цикл.
  const { url: okUrl, server: okServer } = await startUpstream((req, res) => res.end('ok'));
  try {
    assert.equal((await probe(okUrl)).outcome, 'ok');
  } finally {
    okServer.close();
  }
});

test('/ready отвечает 200, пока цикл нагрузки тикает', async () => {
  const app = createApp({
    logStream: { write: () => {} },
    targetUrl: 'http://upstream.invalid/work',
    fetchImpl: async () => okUpstream(),
  });
  app.server.listen(0, '127.0.0.1');
  await once(app.server, 'listening');
  const base = `http://127.0.0.1:${app.server.address().port}`;
  try {
    const res = await fetch(`${base}/ready`);
    assert.equal(res.status, 200);
    assert.equal(await res.text(), 'ready\n');
    // Живость остаётся простой и без зависимостей от цикла.
    assert.equal((await fetch(`${base}/healthz`)).status, 200);
  } finally {
    await app.stop();
  }
});

test('/ready отдаёт 503, если цикл остановлен или давно не тикал', async () => {
  let clock = 1000;
  const app = createApp({
    logStream: { write: () => {} },
    targetUrl: 'http://upstream.invalid/work',
    fetchImpl: async () => okUpstream(),
    // rps: 1 — тик раз в секунду, чтобы сдвиг часов не перекрывался новым тиком.
    rps: 1,
    readyStaleMs: 50,
    now: () => clock,
  });
  app.server.listen(0, '127.0.0.1');
  await once(app.server, 'listening');
  const base = `http://127.0.0.1:${app.server.address().port}`;
  try {
    assert.equal((await fetch(`${base}/ready`)).status, 200);
    clock += 500; // тика не было дольше readyStaleMs
    const stale = await fetch(`${base}/ready`);
    assert.equal(stale.status, 503);
    assert.equal(await stale.text(), 'not ready\n');
  } finally {
    await app.stop();
  }
  // После stop() цикл остановлен, и готовность больше не восстанавливается.
  assert.equal(app.isReady(), false);
});

test('stop() останавливает цикл: новых прогонов нагрузки нет', async () => {
  const calls = [];
  const app = createApp({
    logStream: { write: () => {} },
    targetUrl: 'http://upstream.invalid/work',
    fetchImpl: async () => {
      calls.push(Date.now());
      return okUpstream();
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
