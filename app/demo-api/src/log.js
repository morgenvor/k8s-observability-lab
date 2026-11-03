// Структурированные логи: одна JSON-строка на событие в stdout.
// Отдельный модуль, чтобы тесты ловили лог в подставленный поток, а в коде
// не было console.log в обход формата.
import { randomUUID } from 'node:crypto';

export function newRequestId(headerValue) {
  const value = Array.isArray(headerValue) ? headerValue[0] : headerValue;
  // X-Request-Id приходит от клиента; пустое/слишком длинное значение не пропускаем,
  // чтобы не тащить в логи произвольный мусор и не раздувать строку.
  if (typeof value === 'string' && value.trim() !== '' && value.length <= 128) {
    return value.trim();
  }
  return randomUUID();
}

// stream — любой объект с write(string); по умолчанию process.stdout.
export function createLogger(stream = process.stdout) {
  return function log(level, msg, fields = {}) {
    const entry = { ts: new Date().toISOString(), level, msg, ...fields };
    stream.write(`${JSON.stringify(entry)}\n`);
  };
}