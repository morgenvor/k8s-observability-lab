# Что проверено и чем

Документ отвечает на вопрос «откуда известно, что это работает». Два класса проверок:

- **офлайн-ворота** — `./scripts/check.sh` (он же джоб `ci` в GitHub Actions): линтеры,
  тесты приложений, рендер чартов с ассертами, `promtool check/test rules`, скан секретов.
  Кластер не нужен, результат воспроизводится одной командой;
- **живые проверки** — прогоны на стенде (k3s, две ноды): дриллы, доставка уведомлений,
  API Prometheus/Alertmanager, UI. Каждая запись ниже — это дата, что именно смотрели и
  какой получили результат.

Адреса стенда, имена нод и почтовых ящиков здесь не приводятся намеренно: доказательство
остаётся проверяемым по числам и утверждениям, а не по доступу к чужой лабе.

## Офлайн-ворота

**2026-11-06, `./scripts/check.sh --images` на HEAD `c28879d`: `OK`, код возврата 0,
пропусков нет.**

| Шаг | Результат |
|---|---|
| yamllint | 24 файла |
| `npm ci` + тесты приложений | 35 тестов: 15 (`alert-sink`) + 14 (`demo-api`) + 6 (`demo-load`) |
| `helmfile template` всех релизов → `kubeconform` | 128 объектов: `Valid: 85`, `Invalid: 0`, `Skipped: 43` (CRD без схемы в офлайне) |
| ассерты семантики Loki/Alloy в рендере | ok (retention 72h, push-URL, фильтр по ноде, `ServiceMonitor` и relabeling `job`) |
| `kustomize` → `kubeconform` | 20 объектов: `Valid: 12`, `Invalid: 0`, `Skipped: 8` |
| JSON дашбордов, рендер оверлея с тегами | ok (3 образа подставлены) |
| `promtool check rules` | 31 правило в 4 файлах |
| `promtool test rules` | 3 файла, `SUCCESS` |
| `shellcheck -S warning` | чисто по `scripts/*.sh` и `drills/*.sh` |
| `docker build` | три образа (`alert-sink:check`, `demo-api:check`, `demo-load:check`) |
| скан секретов и адресов | совпадений нет |

В песочнице, где шли прогоны, шагам `npm ci` и `docker build` нужны кеши внутри проекта
(`npm_config_cache`, `DOCKER_CONFIG`) — это ограничение среды, а не проекта.

## Дриллы (2026-11-05, стенд v1.37.1+k3s1)

Все четыре прогона — `result: "passed"`, файлы `evidence/2026-11-05-*.json`, 31 утверждение
(8 + 6 + 5 + 12), у каждого `passed: true`. Проверено `jq`, а не глазами.

| Дрилл | Что инъецировали | Время реакции | Восстановление | Уведомление в приёмнике |
|---|---|---|---|---|
| `errors` | сброс всех соединений на прокси | 693 с (порог 900) | 269 с | `SloDemoAvailabilityBurnFast` (page) |
| `latency` | задержка 400 ± 50 мс | 1562 с (порог 1800) | 148 с | `SloDemoLatencyBurnFast` (page) |
| `oomkill` | запись 200 MiB при лимите 128Mi | 102 с (порог 300) | рестарт 1, спека не менялась | `KubePodOOMKilled` (ticket) |
| `readiness` | сломанная readiness-проба | 1160 с (порог 1500) | 239 с | `SloDemoAvailabilityBurnFast` (page) |

Для каждого прогона в evidence записаны: `firing` и `resolved` с таймстампами из
`/timeline` приёмника (то есть доказана именно доставка, а не «в Prometheus горело»),
состояние SLI до/во время/после (`availability_ratio_5m_*`, `latency_ratio_5m_*`) и теги
образов, на которых шёл дрилл.

## Живые проверки стенда

| Дата | Что проверяли | Чем | Результат |
|---|---|---|---|
| 2026-11-06 | цели и трафик | `up{job=~"demo-.*"}`, `up{job="alert-sink"}` в Prometheus | 2 реплики `demo-api`, `demo-load`, `alert-sink` — `up == 1`; ok-трафик 4,77 rps |
| 2026-11-06 | правила | `/api/v1/rules` | группы `demo-*` без `lastError`, `health: ok`; серий `slo:*` — 20 |
| 2026-11-06 | логи | запрос `{namespace="demo", app="demo-api"}` в Loki | поток есть, `\| json` разбирает `status`, `duration_ms`, `request_id` |
| 2026-11-06 | Grafana | `/api/health`, `POST /api/ds/query` | 13.2.4, дашборды `demo-red`/`slo-demo` на месте, фреймы приходят и из Prometheus, и из Loki |
| 2026-11-06 | маршрут | сгенерированный конфиг Alertmanager, `/timeline` | webhook на `alert-sink`, `max_alerts: 50`; пробный алерт `severity=info` дошёл за ~10 с |
| 2026-11-06 | `Watchdog` | `/timeline`, `alertsink_alert_events_total` | доставлен, счётчик 1 — путь уведомлений жив end-to-end |
| 2026-11-07 | алерты пайплайна логов | удаление цели Loki (`scale sts --replicas=0`), затем возврат | `LokiTargetMissing` `pending` → `firing` (10 мин) → доставка в `/timeline` → `resolved` после возврата; `LokiDown` при этом молчит — как и задумано |
| 2026-11-07 | метрики Loki/Alloy | `/api/v1/targets` | `up{job="monitoring/loki"} == 1`, `up{job="alloy"}` — по серии на ноду |
| 2026-11-07 | хранилище Grafana | `PUT /api/user/preferences`, рестарт пода | часовой пояс и starred-дашборды пережили пересоздание пода; `grafana.db` на PVC |
| 2026-11-07 | доступ к UI | `curl -H 'Host: <host>' http://<нода>/` | Prometheus 302 → `/query`, Alertmanager 200, Grafana `/login` 200 |
| 2026-11-07 | группы правил | `count by (rule_group) (prometheus_rule_group_rules{...})` | 9 групп проекта, без `lastError` |

## Ещё не подтверждено живьём

Список ведётся явно, чтобы «написано в коде» не путалось с «проверено на стенде»:

- доставка `page` в почтовый ящик и `ticket` в `/timeline` по новому маршруту (e-mail-ветка);
- heartbeat пути уведомлений (правила `AlertSinkHeartbeatMissing`, `AlertSinkNeverReceived`);
- правило Loki ruler `DemoApi5xxFromLogs`: `firing` в дрилле `errors` и молчание в `latency`;
- `stage.drop` Alloy: отсутствие `entry too far behind` после рестарта и рост счётчика
  отброшенных строк;
- замер `retentionSize` TSDB (оставить 5 GB или понизить);
- прогон workflow `ci` на GitHub (подтверждает владелец, ссылка на run — в CHANGELOG).

Дополнительно известно и не проверяется: slow-burn алерт (1x / 3d) требует трёх суток
непрерывных данных — его логика покрыта `promtool test rules`, живой прогон не планируется.