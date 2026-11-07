// Тесты реального процесса demo-load: SIGTERM-путь.
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

const SERVICE = fileURLToPath(new URL('../src/load.js', import.meta.url));

async function startService(env = {}) {
  const child = spawn(process.execPath, [SERVICE], {
    env: { ...process.env, ...env },
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

test('SIGTERM: лог shutdown_started и выход с кодом 0', async () => {
  const port = await freePort();
  const { child, state } = await startService({
    PORT: String(port),
    TARGET_URL: 'http://upstream.invalid/work',
  });
  try {
    await waitForLog(state, (entry) => entry.msg === 'load_started');
    child.kill('SIGTERM');
    const [code] = await once(child, 'exit');
    assert.equal(code, 0);
    assert.ok(state.logs.some((entry) => entry.msg === 'shutdown_started'));
  } finally {
    if (child.exitCode === null) child.kill('SIGKILL');
  }
});