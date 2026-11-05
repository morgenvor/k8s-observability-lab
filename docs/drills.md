# Дриллы: как проверяем, что мониторинг видит реальный сбой

Дрилл — это управляемая инъекция сбоя с заранее известным ответом: что должен увидеть
пользователь, какой алерт должен прийти и за какое время. Доказательство дрилла —
файл `evidence/<YYYY-MM-DD>-<дрилл>.json` (схема `drill-evidence/v1`) плюс транскрипт
`evidence/<дрилл>.console.log`. Слова «алерт настроен» без такой записи ничего не
доказывают: проверить можно только факт доставки уведомления в `alert-sink`.

## Состав

| Файл | Назначение |
|---|---|
| `drills/lib.sh` | общие функции: `preflight`, `evidence_init`, `event`, `wait_alert`, `wait_resolved`, `assert_eq`/`assert_num`, `cleanup` через `trap EXIT` |
| `drills/latency.sh` | задержка сети на toxiproxy → деградация latency SLI |
| `drills/errors.sh` | сброс всех соединений на toxiproxy → полный отказ доступности |
| `drills/oomkill.sh` | контейнер demo-api убит OOM внутри лимита памяти |
| `drills/readiness.sh` | сломанная readiness-проба → поды вне endpoints |
| `drills/run.sh` | последовательный запуск, единый лог `evidence/<дата>-drills-run.console.log`, ненулевой код при провале |
| `evidence/` | JSON-доказательства и транскрипты прогонов |

## Запуск

```bash
export KUBECONFIG=../proxmox-lab/.secrets/kubeconfig-phase5b   # кластер лабы
./scripts/bootstrap-tools.sh        # один раз: kubectl в .tools/bin
./drills/run.sh errors             # один дрилл
./drills/run.sh all                # все четыре подряд (около часа)
```

Дрилл меняет живой стенд: трафик `demo` деградирует, под `demo-api` перезапускается.
Поэтому это действие с согласия владельца лабы (правило проекта: живые операции — с
согласия и записью в `../proxmox-lab/CHANGELOG.md`). Дриллы работают только в
namespace `demo`; `monitoring` и системные объекты не трогаются.

Скрипты можно запускать по отдельности — каждый самодостаточен: `preflight` не даст
начать, если стенд не в норме, `cleanup` снимет инъекцию при любом выходе, включая
`Ctrl-C` и провал утверждения.

## Схема evidence v1

```json
{
  "schema": "drill-evidence/v1",
  "drill": "errors",
  "cluster_version": "v1.37.1+k3s1",
  "started_at": "2026-11-05T14:05:11Z",
  "finished_at": "2026-11-05T14:21:40Z",
  "assertions": [{ "name": "reaction_seconds", "expected": "<= 900", "actual": "641", "passed": true }],
  "timeline": [{ "t": "2026-11-05T14:05:12Z", "step": "inject", "detail": "toxiproxy: reset_peer …" }],
  "alerts": [{ "name": "SloDemoAvailabilityBurnFast", "fired_at": "2026-11-05T14:15:52.317Z", "resolved_at": "2026-11-05T14:19:20.518Z", "source": "alert-sink" }],
  "images": { "demo_api": "ef1152f" }
}
```

- Все даты — UTC ISO-8601.
- `alerts` берутся из `/timeline` alert-sink: это доказательство **доставки**, а не
  только факта «в Prometheus алерт горел». Учитываются записи не раньше старта дрилла.
- `assertions` — проверки с ожидаемым и фактическим значением; `failed` любой из них
  делает дрилл провальным и оставляет evidence с `passed: false`.
- `images.demo_api` — тег образа (= короткий git SHA), на котором шёл дрилл: без него
  доказательство нельзя привязать к версии кода.

## Предусловия (проверяет `drill_preflight`)

1. `kubectl` отвечает, кластер лабы доступен (иначе `scripts/lib.sh` падает с подсказкой).
2. `deploy/demo-api`, `demo-load`, `alert-sink`, `toxiproxy` перешли в Ready.
3. В Prometheus `up == 1` у двух целей `demo-api`, цели `demo-load` и `alert-sink`.
4. Прокси `demo-api` в toxiproxy существует и включён.
5. `/timeline` alert-sink отвечает JSON-массивом.

Если любое условие не выполнено — дрилл падает **до** инъекции и ничего не деградирует.

## Дрилл `latency`

**Цель:** показать, что сетевая задержка снаружи приложения доходит до page-алерта по
латентности, а не только видна на графике.

- **Инъекция:** `POST /proxies/demo-api/toxics` — токсин `latency` 400 мс ± 50 мс,
  держится до фактического прихода уведомления.
- **Что видит пользователь:** p95 клиентской латентности > 300 мс; запросы при этом
  успешны (клиентский timeout 1 с), поэтому доступность остаётся ≥ 99 %.
- **Ожидаемый алерт:** `SloDemoLatencyBurnFast` (`severity: page`).
- **Почему не 5 минут:** длинное окно fast-алерта по латентности — 30 минут, а порог
  14,4x при бюджете 5 % означает «72 % запросов медленнее 300 мс за всё окно». Полное
  замедление даёт page примерно на 21–22-й минуте, плюс `for: 2m` и доставка. Измерено
  2026-11-05: **1562 с (26 мин)**. Дрилл ждёт срабатывания и пишет фактическое время
  реакции в evidence; `EXPECT_REACTION` (по умолчанию 1800 с) — верхняя граница, а не
  цель.
- **Критерии:** `client_p95_seconds_during_drill > 0.3`, `latency_ratio_5m_during_drill
  < 0.5`, `availability_ratio_5m_during_drill ≥ 0.99`, алерт `firing`, затем
  `resolved` ≤ 600 с после снятия токсина и `latency_ratio_5m_after ≥ 0.95`.
- **Откат:** `DELETE /proxies/demo-api/toxics/latency_drill` (делается и в cleanup).

## Дрилл `errors`

**Цель:** полный отказ доступности, видимый клиентом, и page по доступности.

- **Инъекция:** токсин `reset_peer` (`timeout: 0`, toxicity 1.0) на прокси `demo-api`:
  каждое соединение сбрасывается, приложение при этом живое и здоровое.
- **Что видит пользователь:** доля успешных запросов → 0 (все исходы `error`).
- **Ожидаемый алерт:** `SloDemoAvailabilityBurnFast` (`page`), ~10–11-я минута: окно
  `1h` переваливает 14,4x на 8,6-й минуте полного отказа, плюс `for: 2m` и доставка
  Alertmanager. Измерено 2026-11-05: **693 с (11,5 мин)**.
- **Критерии:** `availability_ratio_5m_early ≤ 0.5` (отказ дошёл до клиента),
  `availability_ratio_5m_during_drill ≤ 0.01` (≥ 99 % ошибок), `firing`, затем
  `resolved` ≤ 600 с и `availability_ratio_5m_after ≥ 0.99`. Долю ошибок проверяем
  отдельным ожиданием, а не в момент прихода алерта: page может сработать раньше, если
  часовое окно ещё помнит предыдущий отказ (проверено 2026-11-05, когда дриллы шли
  подряд).
- **Откат:** `DELETE /proxies/demo-api/toxics/errors_drill`.

## Дрилл `oomkill`

**Цель:** сигнал о нехватке памяти внутри лимита — без правки манифестов.

- **Инъекция:** `kubectl exec` в под `demo-api` и **запись** 200 MiB при лимите 128Mi
  (`const b = Buffer.alloc(...); b.fill(1)`): cgroup-лимит достигается на записи в
  страницы, `memory.oom.group=1` убивает весь cgroup, kubelet перезапускает контейнер.
  Спека не меняется — после дрилла `.spec` деплоймента совпадает с исходным.
- **Почему нужен `.fill(1)`:** одного `Buffer.alloc(200 MiB)` недостаточно — выделение
  идёт через `calloc`/`mmap`, страницы не трогаются, RSS не растёт, cgroup-OOM не
  наступает (проверено 2026-11-05: `exec` вернул 0, рестарта не было).
- **Шаг `reset`:** перед инъекцией поды demo-api с прошлым `OOMKilled` удаляются.
  Иначе алерт `KubePodOOMKilled` уже `firing`, нового уведомления в `/timeline` не
  будет (у Alertmanager `repeat_interval` — часы), и дриллу нечего доказывать.
- **Ожидаемый алерт:** `KubePodOOMKilled` (`ticket`, `for: 1m`). Измерено 2026-11-05:
  **102 с** от инъекции до записи в `/timeline`.
- **Критерии:** `last_terminated_reason = OOMKilled`, алерт `firing`, под снова Ready,
  `restart_count_delta ≥ 1`, `deployment_spec_unchanged`.
- **Ограничение:** `resolved` у этого алерта не ждём. KSM отдаёт **последнее**
  завершение контейнера, и правило остаётся `firing`, пока контейнер не завершится по
  другой причине (shortcut зафиксирован в `rules/infra.yaml`). Это свойство метрики,
  а не дефект дрилла; в evidence `resolved_at` будет `null`.
- **Откат:** не требуется, `kubectl exec` спеку не меняет.

## Дрилл `readiness`

**Цель:** показать, что сломанная проба выводит поды из endpoints и это видно клиенту
и SLO-алерту.

- **Инъекция:** `readinessProbe.demo-api.httpGet.path = /nope`, затем поды
  пересоздаются (масштабирование 0 → 2). Иначе инъекция не действует: стратегия
  `RollingUpdate` с `maxUnavailable: 0` создаёт новый под с плохой пробой, но старые
  поды с исправной пробой продолжают обслуживать трафик — endpoints не пустеют.
  Это находка дрилла, а не повод менять спеку.
- **Что видит пользователь:** поды `Running`, но `Ready=False`; у Service `demo-api`
  ноль ready-адресов; `demo-load` получает отказы.
- **Ожидаемый алерт:** `SloDemoAvailabilityBurnFast` (`page`). Время реакции здесь
  больше, чем у дрилла `errors`: пустые endpoints не отвергают соединения, а дропают
  пакеты, поэтому клиент уходит в свой timeout 1 с, общий rps падает с 4,7 до 1,9, и
  `ratio_1h` опускается вдвое медленнее. Измерено 2026-11-05: **1099 с (18,3 мин)**;
  `EXPECT_REACTION` по умолчанию 1500 с.
- **Критерии:** `pods_not_ready_during_drill ≥ 2`, `endpoints_ready_during_drill = 0`,
  `availability_ratio_5m_early ≤ 0.5`, алерт `firing`, затем `resolved` ≤ 600 с,
  `endpoints_ready_after ≥ 2`, `availability_ratio_5m_after ≥ 0.99`, а спека после
  отката совпадает с исходной (`readiness_probe_path_after`, `replicas_after`).
- **Откат:** `cleanup` возвращает `readinessProbe` и число реплик; вызывается и при
  провале, и при `Ctrl-C`.

## Типовые сбои

| Симптом | Причина | Что делать |
|---|---|---|
| `toxiproxy API не отвечает` в preflight | под `toxiproxy` не Ready или порт-форвард не поднялся | `kubectl -n demo get pods,svc`, `kubectl -n demo logs deploy/toxiproxy` |
| `кластер не отвечает` | VM лабы остановлены | запуск VM — действие владельца (`../proxmox-lab/`), дрилл повторить |
| алерт не пришёл за отведённое время | `AlertmanagerConfig` не подхвачен, `alertmanagerConfigMatcherStrategy` не `None`, sink в `CrashLoop` | сгенерированный конфиг Alertmanager, `kubectl -n demo logs deploy/alert-sink`, `/timeline` |
| алерт в Prometheus `firing`, в `/timeline` нет | маршрут или доставка | `alertsink_notifications_total`, лог Alertmanager, `kubectl -n monitoring get alertmanagerconfig` |
| `порт-форвард … не поднялся` | занят локальный порт или обрыв соединения | освободить порт (`DRILL_PROM_PORT`, `DRILL_SINK_PORT`, `DRILL_TOXI_PORT`) |
| `resolved` не пришёл | инъекция не снята | проверить `kubectl exec`/`kubectl get` из транскрипта; правило `cleanup` в `drills/lib.sh` |
| `endpoints_ready_during_drill` не 0 | поды не пересоздались после правки пробы | `kubectl -n demo get pods -l app=demo-api`, повторить дрилл |
| `alert_... FAIL: не пришёл` при уже `firing` алерте | состояние алерта не сброшено с прошлого прогона, нового уведомления не будет | для `KubePodOOMKilled` — шаг `reset` дрилла или ручное удаление пода с `lastState.terminated.reason=OOMKilled` |

## Ограничения

- Slow-burn алерты (`1x` по окну `3d`, `for: 1h`) живьём не проверяются: для них нужны
  три суток данных. Их логика покрыта `promtool test rules`.
- `KubePodOOMKilled` не закрывается сам (см. выше) — в `/timeline` он остаётся
  последним `firing` до следующего завершения контейнера по другой причине.
- `/timeline` — кольцо на 200 записей в памяти пода `alert-sink`: после рестарта sink
  история пуста, поэтому evidence собирается сразу после дрилла, а не «потом».
- Дриллы проверяют доставку в `alert-sink`, а не в Telegram: второго получателя в v1.0
  нет, маршрут один.
- Время реакции зависит от окон правил и от характера отказа, а не от скорости дрилла:
  ~11 минут для быстрого отказа (`errors`: reset_peer), ~18 минут для отказа через
  пустые endpoints (`readiness`: клиентские таймауты 1 с снижают общий rps) и ~26 минут
  для латентности (окно 30m при бюджете 5 %). Это свойство мультиоконной схемы при
  трёхдневном окне SLO, а не медлительность скриптов.