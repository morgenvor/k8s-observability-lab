// Метрики demo-api: только то, что описано в контракте проекта.
// route здесь — шаблон маршрута (`/work`, `other`), а не сырой URL: иначе
// кардинальность меток растёт от каждого запроса.
import { Counter, Gauge, Histogram, Registry, collectDefaultMetrics } from 'prom-client';

// Обязательный бакет 0.3: дефолтные бакеты prom-client его не содержат,
// а латентный SLI считается как доля запросов <= 300 мс.
export const DURATION_BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.1, 0.2, 0.3, 0.5, 1, 2, 5];

export function createMetrics() {
  const registry = new Registry();

  // Процессные метрики (cpu, memory, event loop, gc) с префиксом demo_,
  // чтобы не смешиваться с метриками соседей на том же Prometheus.
  collectDefaultMetrics({ register: registry, prefix: 'demo_' });

  const requestsTotal = new Counter({
    name: 'http_requests_total',
    help: 'Всего HTTP-запросов по методу, шаблону маршрута и классу кода ответа',
    labelNames: ['method', 'route', 'status_class'],
    registers: [registry],
  });

  const requestDuration = new Histogram({
    name: 'http_request_duration_seconds',
    help: 'Длительность HTTP-запросов в секундах',
    labelNames: ['method', 'route'],
    buckets: DURATION_BUCKETS,
    registers: [registry],
  });

  const inflight = new Gauge({
    name: 'http_inflight_requests',
    help: 'Запросы, обрабатываемые в данный момент',
    registers: [registry],
  });

  return { registry, requestsTotal, requestDuration, inflight };
}

// 200 -> "2xx", 404 -> "4xx". Неизвестный код сводим к "unknown", а не к пустой метке.
export function statusClass(status) {
  const n = Number(status);
  if (!Number.isInteger(n) || n < 100 || n > 599) return 'unknown';
  return `${Math.floor(n / 100)}xx`;
}