// Тесты demo-api: поднимают сервер на свободном порту и проверяют контракт
// (коды, метрики, форму логов) без кластера и без реального SIGTERM.
import assert from 'node:assert/strict';
import { once } from 'node:events';
import net from 'node:net';
import { test } from 'node:test';

import { createApp, routeTemplate } from '../src/server.js';

// Возвращает строку метрики по имени и подмножеству меток; 0, если серии нет.
// Поддерживает и метрики с метками, и «голые» (`http_inflight_requests 1`).
function metricValue(text, name, labels = {}) {
  let sum = 0;
  for (const line of text.split('\n')) {
    if (!line.startsWith(name)) continue;
    const rest = line.slice(name.length);
    let valueText;
    if (rest.startsWith('{')) {
      const close = rest.indexOf('}');
      if (close < 0) continue;
      const labelPart = rest.slice(1, close);
      const matches = Object.entries(labels).every(([k, v]) => labelPart.includes(`${k}="${v}"`));
      if (!matches) continue;
      valueText = rest.slice(close + 1);
    } else if (rest.startsWith(' ')) {
      if (Object.keys(labels).length > 0) continue;
      valueText = rest;
    } else {
      continue; // например, http_request_duration_seconds_bucket
    }
    const value = Number(valueText.trim());
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
    // Ответ приходит с keep-alive, сам сокет не закроется — закрываем после ответа.
    setTimeout(() => socket.destroy(), 300);
  });
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
    // Отсутствие серии проверяем по тексту: metricValue вернёт 0 и для неё.
    assert.doesNotMatch(body, /http_requests_total\{[^}]*status_class="2xx"/);
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

test('не-GET запрос получает 405 и учитывается как 4xx по шаблону маршрута', async () => {
  await withApp(async ({ base }) => {
    const res = await fetch(`${base}/healthz`, { method: 'POST' });
    assert.equal(res.status, 405);
    assert.equal(res.headers.get('allow'), 'GET');
    await res.text();
    const body = await (await fetch(`${base}/metrics`)).text();
    assert.equal(
      metricValue(body, 'http_requests_total', { route: '/healthz', status_class: '4xx' }),
      1,
    );
  });
});

test('http_inflight_requests возвращается к базе после запросов', async () => {
  await withApp(async ({ base }) => {
    await Promise.all(Array.from({ length: 5 }, () => fetch(`${base}/work`)));
    const body = await (await fetch(`${base}/metrics`)).text();
    // В момент скрейпа в полёте только он сам, поэтому база = 1, а не 0.
    assert.equal(metricValue(body, 'http_inflight_requests'), 1);
  });
});

test('оборванный клиентом запрос учитывается как 499, не как 2xx', async () => {
  await withApp(
    async ({ base, app, lines }) => {
      const socket = net.connect(app.server.address().port, '127.0.0.1', () => {
        socket.write('GET /work HTTP/1.1\r\nHost: test\r\n\r\n');
        setTimeout(() => socket.destroy(), 20);
      });
      socket.on('error', () => {});
      await new Promise((resolve) => socket.on('close', resolve));
      // work() блокирует event loop 200 мс — даём обработчику закончить и учесть запрос.
      await new Promise((resolve) => setTimeout(resolve, 400));
      const body = await (await fetch(`${base}/metrics`)).text();
      assert.equal(metricValue(body, 'http_requests_total', { route: '/work', status_class: '2xx' }), 0);
      assert.equal(metricValue(body, 'http_requests_total', { route: '/work', status_class: '4xx' }), 1);
      const entries = lines
        .map((chunk) => chunk.trim())
        .filter(Boolean)
        .map((chunk) => JSON.parse(chunk));
      assert.equal(entries.filter((entry) => entry.msg === 'request_aborted').length, 1);
      const request = entries.filter((entry) => entry.msg === 'http_request' && entry.route === '/work').at(-1);
      assert.equal(request.status, 499);
    },
    {
      // Асинхронная работа: пока идёт ожидание, сервер успевает заметить обрыв
      // клиента (res.destroyed) — синхронный busy-loop блокирует event loop и
      // обрыв обнаруживается уже после записи ответа.
      work: () => new Promise((resolve) => setTimeout(() => resolve(0), 200)),
    },
  );
});

test('ошибка обработчика — 500, класс 5xx и лог request_failed', async () => {
  await withApp(
    async ({ base, lines }) => {
      const res = await fetch(`${base}/work`);
      assert.equal(res.status, 500);
      const body = await (await fetch(`${base}/metrics`)).text();
      assert.equal(metricValue(body, 'http_requests_total', { route: '/work', status_class: '5xx' }), 1);
      const entries = lines
        .map((chunk) => chunk.trim())
        .filter(Boolean)
        .map((chunk) => JSON.parse(chunk));
      const failed = entries.filter((entry) => entry.msg === 'request_failed');
      assert.equal(failed.length, 1);
      assert.equal(failed[0].status, 500);
      assert.match(failed[0].error, /boom/);
    },
    {
      work: () => {
        throw new Error('boom');
      },
    },
  );
});

test('неизвестный путь маршрутизируется в шаблон other', () => {
  assert.equal(routeTemplate('/work'), '/work');
  assert.equal(routeTemplate('/work/123'), 'other');
});

test('мусорный request-target: 400 и процесс жив', async () => {
  await withApp(async ({ base, app, lines }) => {
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
  });
});
