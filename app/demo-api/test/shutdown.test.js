// Тесты реального процесса demo-api: SIGTERM-путь и валидация PORT.
// Отдельный файл, потому что здесь проверяется поведение процесса, а не обработчика.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import net from 'node:net';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

// Свободный порт: сервер не принимает PORT=0 (0 не номер порта), поэтому
// занимаем эфемерный порт и сразу отдаём его обратно ОС.
async function freePort() {
  const server = net.createServer();
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const { port } = server.address();
  await new Promise((resolve) => server.close(resolve));
  return port;
}

const SERVER = fileURLToPath(new URL('../src/server.js', import.meta.url));

// Запускает сервер и собирает его JSON-логи: порт при PORT=0 берём из события
// server_started, а не угадываем.
async function startServer(env = {}) {
  const child = spawn(process.execPath, [SERVER], {
    env: { ...process.env, PORT: '0', ...env },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const state = { logs: [], raw: '', stderr: '' };
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', (chunk) => {
    state.raw += chunk;
    for (const line of chunk.split('\n')) {
      if (line.trim() === '') continue;
      state.logs.push(JSON.parse(line)); // непарсимая строка = сломанный контракт логов
    }
  });
  child.stderr.on('data', (chunk) => {
    state.stderr += chunk;
  });
  return { child, state };
}

async function waitForLog(state, predicate, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const found = state.logs.find(predicate);
    if (found) return found;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(`не дождались события в логе за ${timeoutMs} мс: ${state.raw}`);
}

test('SIGTERM: /ready отдаёт 503 в окне дренажа, затем выход с кодом 0', async () => {
  const port = await freePort();
  const { child, state } = await startServer({ PORT: String(port) });
  try {
    const started = await waitForLog(state, (entry) => entry.msg === 'server_started');
    const base = `http://127.0.0.1:${started.port}`;
    assert.equal((await fetch(`${base}/ready`)).status, 200);

    child.kill('SIGTERM');
    const shutdownStarted = await waitForLog(state, (entry) => entry.msg === 'shutdown_started');
    assert.equal(typeof shutdownStarted.drain_ms, 'number');

    // Именно 503 (pod убирают по readiness), а не отказ соединения.
    const deadline = Date.now() + 1500;
    let status = 0;
    while (Date.now() < deadline && status !== 503) {
      try {
        status = (await fetch(`${base}/ready`)).status;
      } catch {
        status = 0;
      }
      if (status !== 503) await new Promise((resolve) => setTimeout(resolve, 50));
    }
    assert.equal(status, 503, 'в окне дренажа /ready должен отвечать 503');

    const [code] = await once(child, 'exit');
    assert.equal(code, 0);
    assert.ok(state.logs.some((entry) => entry.msg === 'shutdown_finished'));
  } finally {
    if (child.exitCode === null) child.kill('SIGKILL');
  }
});

test('некорректный PORT: выход с кодом 1 и понятным сообщением', async () => {
  const { child, state } = await startServer({ PORT: 'не-порт' });
  const [code] = await once(child, 'exit');
  assert.equal(code, 1);
  assert.match(state.stderr, /PORT/);
});