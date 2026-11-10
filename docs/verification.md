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

**2026-11-10, `./scripts/check.sh` на дереве с шагом «покрытие правил тестами и enum
severity»: `OK`, пропусков нет.** Шагов верхнего уровня 26; `yamllint` запущен с
`--strict` (было три предупреждения `line too long` в `rules/tests/pipeline.test.yaml` —
строки завёрнуты, значения серий совпадают побайтно). Новый шаг: 27 алертов в 6 файлах,
все 27 покрыты `rules/tests/*.test.yaml`, `severity ∈ {page, ticket}`. Пины в CI:
`yamllint==1.38.0`, `pyyaml==6.0.2`, `actions/checkout`/`setup-node` — по commit SHA.
Негативные прогоны нового ассерта: новый алерт без теста, `severity: info`, алерт без
`for`, тест на несуществующий алерт, пустой каталог тестов — все падают с ожидаемым
сообщением.

**2026-11-09, `./scripts/check.sh --strict --smoke` на дереве с правками по ревью
поверх `b6e589b`: `OK`, код возврата 0, пропусков нет.** Прогон после выноса ассертов в `scripts/checks/`: на верхнем уровне
шагов стало на четыре больше — 29 (три новых ассерта и smoke); строк `==>` в выводе 37,
потому что `smoke-local.sh` печатает свои подшаги. Ни один шаг не ушёл в «пропущено».

| Шаг | Результат |
|---|---|
| yamllint | 30 файлов |
| `npm ci` + тесты приложений | 48 тестов (те же наборы, что и раньше) |
| `helmfile template` всех релизов → `kubeconform` | 134 объекта: `Valid: 89`, `Invalid: 0`, `Skipped: 45` |
| `kustomize` → `kubeconform` | 23 объекта: `Valid: 13`, `Invalid: 0`, `Skipped: 10` |
| ассерты рендера (Loki/Alloy, Ingress, маршрут, ruler) | ok — те же проверки, что до выноса |
| **связка Alertmanager и AlertmanagerConfig** | ok (`matcherStrategy.type=None`, оба селектора пусты, конфиг в `monitoring` с `apiVersion` `v1alpha1`) |
| **размещение правил** | ok (6 `PrometheusRule`: метки под `ruleSelector`, namespace рядом с оператором, членство совпадает с `rules/kustomization.yaml`) |
| **паритет оверлея деплоя** | ok (23 объекта в `kustomize.yaml` = 23 в рендере `deploy.sh`) |
| `promtool check rules` | 6 файлов выгрузки: 2+2+2+1+1+2 группы |
| `promtool test rules` | 6 наборов, `SUCCESS` (6/20/3/3/3/10 правил) |
| ссылки в алертах | `runbook_url 26, dashboard_url 6`, анкоров в runbook 27 |
| **smoke фикстуры в docker** (`--smoke`) | три образа собраны, `/healthz`, `/ready`, `/metrics` (бакет `0.3`), рост `load_requests_total{outcome="ok"}` за 10 с, JSON-логи → `SMOKE OK` |
| скан секретов и адресов | совпадений нет, 10 адресов — все `example.invalid`/`example.com` |

Без флагов тот же HEAD даёт `OK` и не требует docker: `--smoke` — единственное, что
запускает контейнеры. Негативные прогоны новых ассертов (мутации рендера: `OnNamespace`,
непустой селектор, снятая метка `release`, `pipeline.yaml` вне `resources`, оверлей без
объекта) — все пять падают с ожидаемым сообщением; подробности в `CHANGELOG.md`.

**2026-11-07, `./scripts/check.sh --images` на HEAD `b8ef241`: `OK`, код возврата 0,
пропусков нет** (ни один шаг не ушёл в «пропущено»: `docker`, `shellcheck` и `yamllint`
были на месте).

| Шаг | Результат |
|---|---|
| yamllint | 26 файлов |
| `npm ci` + тесты приложений | 48 тестов: 20 (`alert-sink`) + 16 (`demo-api`) + 12 (`demo-load`) |
| `helmfile template` всех релизов → `kubeconform` | 134 объекта: `Valid: 89`, `Invalid: 0`, `Skipped: 45` (CRD без схемы в офлайне) |
| ассерты семантики Loki/Alloy в рендере | ok (retention 72h, push-URL, фильтр по ноде, `ServiceMonitor` и relabeling `job`) |
| `kustomize` → `kubeconform` | 21 объект: `Valid: 12`, `Invalid: 0`, `Skipped: 9` |
| JSON дашбордов, рендер оверлея с тегами | ok (2 файла `jq`, 3 образа подставлены) |
| `promtool check rules` | 39 правил в 5 файлах (6 + 20 + 3 + 3 + 7) |
| `promtool test rules` | 4 файла, `SUCCESS` |
| тесты дриллов (`signals.sh`) | 3 сценария: SIGTERM → `failed`, штатный прогон → `passed`, сбой cleanup не мешает остальным шагам |
| `shellcheck -S warning` | чисто по `scripts/*.sh` и `drills/*.sh` |
| `docker build` | три образа (`alert-sink:check`, `demo-api:check`, `demo-load:check`) |
| скан секретов и адресов | совпадений нет: приватные сети стенда, ключи и токены, имена нод, следы лабы в тексте; отдельно проверено, что `.secrets/` не в индексе |

Числа зависят от состава HEAD, поэтому их место — рядом с коммитом: в прогоне 2026-11-06
на `c28879d` было 24 файла yamllint, 35 тестов, 31 правило в 4 файлах и `kustomize` 20
объектов — добавились `rules/pipeline.yaml` и тесты, которых тогда не было.

Прогон 2026-11-08 (`--strict`, HEAD `de40d93` + правки документов): `OK`, пропусков нет;
26 файлов yamllint, 39 правил в 5 файлах, ссылок `runbook_url 19, dashboard_url 6`,
анкоров в runbook 23. Новые шаги этого прогона — «маршрут уведомлений в рендере»
(три child-route, `continue`, catch-all, подстановка адресов двумя рендерами) и «скан
личных адресов» (10 адресов, все в `example.invalid`).

Прогон 2026-11-08 (HEAD `5e7634f`, Phase 4): `OK`, пропусков нет; 28 файлов yamllint,
41 правило в 6 файлах (6 + 20 + 3 + 3 + 2 + 7), пять наборов `promtool test rules` —
`SUCCESS`, ссылок `runbook_url 21, dashboard_url 6`, анкоров 23, `kustomize` 22 объекта,
`helmfile template` 134 объекта. Проверка новых правил не сводится к «тесты зелёные»:
прогнаны мутации — порог `19800 -> 3600` и `-> 36000`, снятая ветка `up == 1` в каждом из
двух правил, `gauge > 0 -> >= 0`; каждая роняет свой тест, то есть набор различает
правило и его искажение. Оговорка: в этом прогоне пакеты чартов подавались из локальных
копий (`.tmp/chart-mirror/`, `sha256` совпали с digest индексов чартов) — GitHub в тот
день отдавал `504` на путь `releases/download/...`, поэтому рендер чартов проверен на тех
же версиях, но не через сеть. Повтор без подмены — когда сеть оживёт.

Прогон 2026-11-08 (HEAD после решений по ревью — ветка `AlertSink.*` → `email` и правило
`AlertSinkTargetMissing`): `OK`, пропусков нет; 43 правила в 6 файлах (6 + 20 + 3 + 3 + 3 +
8), ссылок `runbook_url 22, dashboard_url 6`, анкоров 23. Шаг «маршрут уведомлений в
рендере» проверяет теперь четыре child-route: первая ветка `alertname=~"AlertSink.*"` →
`email` с `continue: true`, затем `page|critical` → `email`, `severity`-ветка в sink и
catch-all. Те же мутации, что и в предыдущем прогоне, плюс две для нового правила
(`vector(1)` и `vector(0)` вместо `absent`) — каждая роняет свой кейс. Чарты снова из
локальных копий: GitHub отдавал `504` на `releases/download`.

Прогон 2026-11-08 (Phase 5 — Loki ruler): `OK`, пропусков нет; 30 файлов yamllint, 42
правила в 6 файлах (6 + 20 + 3 + 3 + 3 + 7) плюс правило Loki ruler (его promtool не
разбирает: `| json` — не PromQL, структуру проверяет шаг «Loki ruler в рендере»), ссылок
`runbook_url 23, dashboard_url 6` (новый алерт проверяется тем же шагом анкоров), анкоров
25, `kustomize` 23 объекта, `helmfile template` 134 объекта, пять наборов `promtool test
rules` — `SUCCESS`. Чарты снова из локальных копий (`.tmp/chart-mirror/`, `sha256` сверены
с `digest` индексов): GitHub отдавал `503` на `releases/download`.

В песочнице, где шли прогоны, шагам `npm ci` и `docker build` нужны кеши внутри проекта
(`npm_config_cache`, `DOCKER_CONFIG`) — это ограничение среды, а не проекта.

## Дриллы (2026-11-05, стенд v1.37.1+k3s1)

Все четыре прогона — `result: "passed"`, файлы `evidence/2026-11-05-*.json`, 31 утверждение
(6 + 8 + 5 + 12: `errors`, `latency`, `oomkill`, `readiness` в порядке таблицы), у каждого
`passed: true`. Проверено `jq`, а не глазами.

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
| 2026-11-08 | маршрут по `severity` | сгенерированный конфиг Alertmanager, `/api/v2/alerts`, `/timeline` | дерево доехало: `severity=~"page|critical"` → `email` (`continue: true`), `ticket|info|warning|none` → `alert-sink`, catch-all → `alert-sink`; проба `page` получила получателей `email` + `alert-sink`, проба `ticket` — только `alert-sink` |
| 2026-11-08 | доставка e-mail | `/metrics` Alertmanager (напрямую из пода), гейт `deploy.sh` | `alertmanager_notifications_total{integration="email"} = 1`, `failed_total{integration="email"}` (все причины) `= 0` — SMTP принял письмо; `alertmanager_config_last_reload_successful = 1` сразу после apply |
| 2026-11-08 | egress до SMTP | `nc -z <smtp-host> 587` с рабочей машины и из пода Alertmanager | порт открыт в обоих местах; проверено до apply — закрытый egress делает ветку e-mail нерабочей при любом конфиге |
| 2026-11-08 | вручение письма | скриншот из ящика (`docs/images/alert-email.png`) | письмо получено: в кадре тело уведомления по `page`-пробе, личных адресов нет; снял владелец |
| 2026-11-08 | доставка в приёмник | `/timeline`, `alertsink_*` | 4 уведомления: 2 × `Watchdog` (`none`), `EmailProbePage` (`page`, пришёл через catch-all), `EmailProbeTicket` (`ticket`) |
| 2026-11-08 | Loki ruler: загрузка правила | `helmfile apply -l name=loki` (ревизия 4), `/prometheus/api/v1/rules` Loki (порт 3100) | группа `demo-api-logs`, файл `demo-api-5xx.yaml`, `interval: 60`, правило `DemoApi5xxFromLogs` `health: ok`, метки `severity=ticket`, `service=demo-api`; рестарт пода Loki прошёл без ошибок старта |
| 2026-11-08 | Loki ruler: оценка и путь до Alertmanager | `/metrics` Loki, `/config` Loki | `loki_prometheus_rule_evaluations_total{rule_group="…;demo-api-logs"} = 2`, `…_failures_total = 0`; `ruler.alertmanager_url` = Service Alertmanager, `enable_api: true`, `storage.local.directory: /etc/loki/rules`, `rule_path: /tmp/loki-rules`; `loki_prometheus_notifications_alertmanagers_discovered{alertmanager="…/api/v2/alerts"} = 1`, `sent_total = 0` (гореть нечему) |
| 2026-11-09 | Loki ruler: фильтр `/ready` в живом правиле | `kubectl apply -k deploy/loki-rules` (ConfigMap правил), `/prometheus/api/v1/rules` Loki | правка доехала до пода **без рестарта** (контейнер поднят 08:55:31Z, правка применена 09:35Z, `restartCount` не изменился): `route!="/ready"` в выражении, `health: ok`; пересборка образов и `helmfile apply` не нужны — правило приезжает томом |
| 2026-11-09 | Loki ruler: срабатывание и доставка до sink | временное правило `LogPathProbe` в том же ConfigMap, `/prometheus/api/v1/rules`, `/timeline` приёмника | загружено 09:36:04Z, `firing` 09:36:14Z, запись в `/timeline` 09:36:22Z (`status=firing`, метки `severity=ticket`, `probe=loki-path`); пробное правило удалено 09:36:24Z и выгружено из ruler к 09:37:44Z — путь «ruler → Alertmanager → `alert-sink`» доказан на реальных логах |
| 2026-11-09 | Loki ruler: `resolved` до sink | `/timeline` приёмника | после удаления пробного правила пришла запись `2026-11-09T09:40:22.084Z` `status=resolved` для `LogPathProbe` — ветка `sendResolved: true` webhook-приёмника работает и для алертов ruler |
| 2026-11-09 | Alloy: правка конфига без рестарта | `helmfile apply -l name=alloy` (ревизии 5→6), лог контейнера `config-reloader` и лог `alloy` | поды **не пересозданы** (те же имена, `startTime` 10:15Z, `restartCount` 0): аннотации `checksum/config` в чарте 1.15.0 нет, пока включён `configReloader`; в его логе `Reload triggered` (10:58:00Z), в логе alloy `reload requested via /-/reload` и `config reloaded`. В живом ConfigMap — `older_than = "50m"` |
| 2026-11-09 | Alloy: старые строки не доезжают до Loki | `rollout restart ds/alloy` (10:58:51Z), затем `kubectl logs -l app.kubernetes.io/name=loki --since=…` и `loki_process_dropped_lines_total` через Prometheus | после пересоздания подов (emptyDir новый, логи перечитаны с начала) в Loki **0** строк `entry too far behind` и в Alloy **0** ответов 400 за 20+ минут; фильтр отбросил **14 293** строки (13 639 + 654 по нодам) при пороге 1h, после первичного перечитывания счётчик не растёт. Замер с порогом 50m — 2026-11-09 после правки по ревью (см. строку ниже) |
| 2026-11-09 | Alloy: повторный замер с порогом 50 минут | `helmfile apply -l name=alloy` (ревизия 6, hot-reload) + `rollout restart ds/alloy` в 10:58:51Z; через 10 минут — `kubectl logs` Loki и Alloy, `loki_process_dropped_lines_total{reason="too_old"}` в Prometheus | порог 50m даёт запас до окна приёма Loki (1 ч): за 10 минут и далее — **0** строк `entry too far behind`, **0** ответов 400; счётчик отброшенных строк вырос |
| 2026-11-09 | `retentionSize` Prometheus: замер и правка | `/api/v1/status/tsdb`, `prometheus_tsdb_*`, `/api/v1/status/flags` через port-forward, `kubectl get pvc` | замер: `storage.tsdb.retention.time=3d`, `size` было `5GiB` (`retention_limit_bytes = 5 368 709 120`) при PVC **5Gi** — то есть 100 % тома, при том что считаются только блоки, а WAL (`127 006 710 B`) и `head_chunks_storage` (`12 582 809 B`) лежат сверху; 10 блоков = **673 MiB**, head-серий 106 786 при 221 174 чанках, итого ≈**806 MiB** (~16 % лимита). Сэмплы есть на 24, 48 и 90 ч назад, на 60–80 ч — нет (стенд был выключен); `kubelet_volume_stats_*` для этого PVC показывает ФС ноды (20,9 GB), а не квоту. Решение: `retentionSize` → **4GB** (≈80 % от 5Gi, рекомендация Prometheus), `helmfile apply -l name=monitoring` — ревизия 11; в CR `spec.retentionSize = 4GB` |
| 2026-11-10 | свои info-алерты → `ticket` в живом кластере | `kubectl apply -f rules/pipeline.yaml -f rules/meta.yaml` (+ `rules/notifications.yaml`), `/api/v1/rules`, `prometheus_rule_group_rules` | `LokiNotIngesting` и `SloDemoNoTraffic` — `severity=ticket`, `health=ok`, `lastError` нет; `ALERTS` по ним пусто; своих `info` не осталось (23 `ticket`, 4 `page`, 27 алертов). Побочно: `PrometheusRule demo-alerting-path` в кластере **отсутствовал** (три heartbeat-правила были только в git) — применён, групп проекта стало 11 вместо 10 |

Как проверить это повторно (временное правило по реальному трафику, без выдуманных строк
и без правки кода) — раздел «Правила Loki ruler» в `docs/runbook.md`.

## Ещё не подтверждено живьём

Список ведётся явно, чтобы «написано в коде» не путалось с «проверено на стенде»:

- вручение письма подтверждено скриншотом владельца (`docs/images/alert-email.png`), но
  не метрикой: «письмо ушло» и «письмо прочитано» — разные события, и SMTP-сервер о втором
  не сообщает;
- `resolved`-ветка **e-mail**/`sendResolved`: проба через `/api/v2/alerts` без `endsAt`
  осталась `active` (снять её нельзя, `DELETE` отдаёт 405; статус пересчитывается только
  при обновлении алерта или сборке мусора), поэтому закрытие письмом этой пробой не
  проверено — его покажет ближайший дрилл. У webhook-приёмника `resolved` проверен
  2026-11-09 на пробном правиле ruler (см. таблицу выше); у e-mail — нет;
- сторожа правила ruler (`LokiRulerRulesMissing`, `LokiRulerEvaluationFailing`,
  `rules/pipeline.yaml`): логика покрыта `promtool test rules` 2026-11-09, но на стенде
  они не горели. Живая проверка — инъекция (убрать ключ `demo-api-5xx.yaml` из
  ConfigMap `loki-rules` → `LokiRulerRulesMissing`; испортить выражение →
  `LokiRulerEvaluationFailing`) с возвратом состояния по `kubectl apply -k
  deploy/loki-rules`. Подтверждено живьём только существование опорных метрик
  (`loki_prometheus_rule_evaluations_total`, `…_failures_total` — строка 2026-11-08);
- перевод `LokiNotIngesting` и `SloDemoNoTraffic` из `info` в `ticket` (2026-11-10):
  причина — проверенное глушение одиночного info ингибитором `InfoInhibitor`. В кластере
  правила уже с `severity=ticket` (`health=ok`, см. строку таблицы), но доставка
  `ticket` в `alert-sink` на новом severity не проверялась — нужна инъекция: остановить
  `demo-load` или прекратить запись логов;
- heartbeat пути уведомлений (правила `AlertSinkHeartbeatMissing`, `AlertSinkNeverReceived`);
- срабатывание `DemoApi5xxFromLogs` именно на **реальном 5xx**. Путь «правило →
  Alertmanager → sink» доказан 2026-11-09 пробным правилом на обычных логах, но ни одного
  настоящего 5xx от `demo-api` в лабе не возникает: единственный источник 5xx — `503`
  самопроверки `/ready` при дренаже, и он из выражения исключён (иначе правило горело бы
  на каждом рестарте пода). Дрилл `errors` для этой проверки не годится: `reset_peer` на
  toxiproxy рвёт соединение **до** приложения, и в логах остаются `status: 200` и
  `request_aborted` (499) — ни то, ни другое под условие `status >= 500` не попадает.
  Чтобы правило горело на настоящем 5xx, нужна инъекция 5xx в `demo-api` (отдельный
  маршрут) и свой дрилл — это записано в «Идеи после v1.1»;
- прогон workflow `ci` на GitHub (подтверждает владелец, ссылка на run — в CHANGELOG).

Дополнительно известно и не проверяется: slow-burn алерт (1x / 3d) требует трёх суток
непрерывных данных — его логика покрыта `promtool test rules`, живой прогон не планируется.