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

**2026-11-10, после правок по ревью: `./scripts/check.sh --strict --images` — `OK`,
exit 0, пропусков нет.** 28 шагов (`--images` добавляет `docker build`), собраны
`alert-sink:check`, `demo-api:check`, `demo-load:check` — это и есть доказательство прогона
`--images`: лог предыдущей попытки был позже перезаписан прогоном без флага (найдено
ревью). Лог — `.tmp/check-images-2026-11-10.log` (вне git).
Числа: 47 правил / 27 алертов / 11 групп, `runbook_url 28, dashboard_url 6, logs_url 2`,
анкоров 35, `kustomize` 24 объекта (`Valid: 14`), `helmfile template` 134 (`Valid: 89`),
дашборды 3 файла / 19 панелей / 8 самопроверок, скан адресов 10 — все
`example.invalid`/`example.com`. Шаблон письма: `text` 821 символ, `html` **1347** (было 1284:
добавился отдельный абзац со ссылкой на стенд вне цикла по алертам и унифицированная подпись),
шаг проверяет четыре фикстуры, включая письмо из двух алертов.

**2026-11-10, финальный прогон на дереве с правками документов (HEAD `8acbdb3` +
README и этот файл): `./scripts/check.sh --strict` — `OK`, exit 0,
пропусков нет.** 27 шагов верхнего уровня, ни один не ушёл в «пропущено»; логи — в `.tmp/`
(вне git). Прогон повторён после последней правки документов, числа совпали. *Этот
прогон — до правок по ревью (шаблон письма тогда давал `html` 1284 символа);
актуальный — выше.* Числа: 6 `PrometheusRule`, 47 правил (27 алертов:
23 `ticket` + 4 `page`), 11 групп; `runbook_url 28, dashboard_url 6, logs_url 2`, анкоров в
runbook 35, `page`-анкоров 4; `kustomize` 24 объекта (`Valid: 14`, `Skipped: 10`);
`helmfile template` 134 объекта (`Valid: 89`, `Skipped: 45`); дашборды — 3 файла, 19 панелей,
8 самопроверок; шаблон письма — `text` 821 и `html` 1284 символа; пять наборов
`promtool test rules` — `SUCCESS`, покрытие «27 из 27» (со срабатывающим кейсом 24); тесты
приложений 20 + 16 + 12; `yamllint --strict` — 30 файлов; скан адресов — 10 совпадений, все
`example.invalid`/`example.com`. Кластер не использовался. Живые проверки после этого прогона
не повторялись и не нужны: правки касались только документов, поведение правил, маршрута, письма
и логов не тронуто.

**2026-11-10, финальная проверка `v1.1` на HEAD `bdd4613` (тот же день, коммиты после записи ниже:
шаг «шаблон письма», правки ассертов по ревью): `./scripts/check.sh --strict` — `OK`,
пропусков нет; `CHECK_STRICT=1 ./scripts/check.sh --smoke` — `OK` + `SMOKE OK`;
`./scripts/check.sh --images` — `OK`.** Шагов верхнего уровня теперь 27 без `--smoke` и 28
с ним (24 явных `step` и три итерации `npm test`; добавился шаг «шаблон письма»), строк
`==>` — 27 и 39. Числа, с которыми сверялись: 6 `PrometheusRule`, 47 правил (27 алертов:
23 `ticket` + 4 `page`), 11 групп; `runbook_url 28, dashboard_url 6, logs_url 2`, анкоров
в runbook 35, `page`-анкоров 4; `kustomize` 24 объекта; `helmfile template` 134 объекта
(`Valid: 89`, `Skipped: 45`); дашборды — 3 файла, 19 панелей, 8 самопроверок; пять
наборов `promtool test rules` — `SUCCESS`, покрытие «27 из 27» (со срабатывающим кейсом
24); тесты приложений 20 + 16 + 12; `yamllint --strict` — 30 файлов; скан адресов —
10 совпадений, все `example.invalid`/`example.com`. В smoke — ok-запросов
`load_requests_total{outcome="ok"}` 2 → 52; три образа собраны и `--images` собрал те же
(`alert-sink:check`, `demo-api:check`, `demo-load:check`). Кластер не использовался.
Проверять наличие и вид скриншотов ворота не умеют: на момент этого прогона
`docs/images/demo-red.png` и `slo-demo.png` отсутствовали, а `alert-email.png` был снят с
упрощённым письмом — тогда это был открытый шаг проверки, а не «зелёное». В тот же день кадры
добавлены в репозиторий (`docs(images)`, `70e3c4f`); содержимое кадров проверено
глазами, а не воротами — строка таблицы «Живые проверки» ниже.

**2026-11-10, `./scripts/check.sh` на дереве с шагом «покрытие правил тестами и enum
severity»: `OK`, пропусков нет.** Шагов верхнего уровня 26 без `--smoke` и 27 с ним
(23 явных `step`, три итерации `npm test` и шаг smoke); строка `==>` на подшаг smoke не
считается — их 38, потому что `smoke-local.sh` печатает свои 11 подшагов. `yamllint` запущен с
`--strict` (было три предупреждения `line too long` в `rules/tests/pipeline.test.yaml` —
строки завёрнуты, значения серий совпадают побайтно). Новый шаг: 27 алертов в 6 файлах,
все 27 покрыты `rules/tests/*.test.yaml`, `severity ∈ {page, ticket}`. Пины в CI:
`yamllint==1.38.0`, `pyyaml==6.0.2`, `actions/checkout`/`setup-node` — по commit SHA.
Негативные прогоны нового ассерта: новый алерт без теста, `severity: info`, алерт без
`for`, тест на несуществующий алерт, пустой каталог тестов — все падают с ожидаемым
сообщением.

**2026-11-09, `./scripts/check.sh --strict --smoke` на дереве с правками по ревью
поверх `b6e589b`: `OK`, код возврата 0, пропусков нет.** Прогон после выноса ассертов в
`scripts/checks/`: на верхнем уровне шагов стало на четыре больше — 26 (три новых ассерта
и smoke; 23 явных `step` + три итерации `npm test`; без smoke — 25); строк `==>` в выводе
37, потому что `smoke-local.sh` печатает свои 11 подшагов. Ни один шаг не ушёл в «пропущено».

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
объекта) — все пять падают с ожидаемым сообщением.

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

Прогон 2026-11-08 (HEAD `5e7634f`): `OK`, пропусков нет; 28 файлов yamllint,
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

Прогон 2026-11-08 (Loki ruler): `OK`, пропусков нет; 30 файлов yamllint, 42
правила в 6 файлах (6 + 20 + 3 + 3 + 3 + 7) плюс правило Loki ruler (его promtool не
разбирает: `| json` — не PromQL, структуру проверяет шаг «Loki ruler в рендере»), ссылок
`runbook_url 23, dashboard_url 6` (новый алерт проверяется тем же шагом анкоров), анкоров
25, `kustomize` 23 объекта, `helmfile template` 134 объекта, пять наборов `promtool test
rules` — `SUCCESS`. Чарты снова из локальных копий (`.tmp/chart-mirror/`, `sha256` сверены
с `digest` индексов): GitHub отдавал `503` на `releases/download`.

**2026-11-10, дашборды в воротах (v1.1, дашборд «Уведомления»; ассерт усилен по ревью).**
Шаг «дашборды: валидность JSON» дополнен `scripts/checks/dashboards.py`: уникальность `uid`,
существование `uid` datasource (панель и цель), каждое имя метрики в выражении Prometheus
разрешается в `app/*/src/*.js`, в `record` из `rules/*.yaml` либо в явный список встроенных
(`up`, `ALERTS`, process-метрики prom-client); `namespace` в селекторах Loki сверяется с
ОТРЕНДЕРЕННЫМ конфигом Alloy (тот же файл, который разбирает `alloy_config.py`), `app` —
с метками подов `deploy/`. Вывод шага: `дашборды: файлов 3, панелей 19, datasource
['loki', 'prometheus'], метрик приложений 11 (alert-sink 4), записей правил 20, метрик в
выражениях 22, самопроверок 8`.

**Самопроверка ассерта** (чтобы он не «ослеп» от правки регулярки) встроена в тот же шаг:
каждый прогон мутирует копии проверенных дашбордов и требует ошибку с ожидаемым текстом —
опечатка в префиксе метрики (`alertsnk_…`), несуществующая метрика prom-client, чужое имя
метрики (`foo_bar_total`), `namespace=~"prod|demo"`, `app="alert_sink"`, дубль `uid`,
несуществующий `uid` datasource, цель без `expr`. Проверено саботажем: если в ассерте
заменить проверку метрики или селектора на `True`, шаг падает с `самопроверка «…»: мутация
прошла молча` — то есть молчание самого ассерта тоже ловится. Проходят осознанно:
`namespace!="monitoring"` (отрицательный матчер не сужает поток — он влияет на объём
чтения, а не на пустоту панели) и `app=~"alert-.+"` (совпадает с метками подов).

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

**Повтор `errors` 2026-11-10 (финальная проверка v1.1): `passed`**, `evidence/2026-11-10-errors.json`,
8 утверждений, реакция 519 с, восстановление 268 с. Отличие от прогона 2026-11-05 —
предмет проверки: в этот раз смотрели `starts_at` уведомления (`14:35:22Z` при инъекции в
`14:26:53Z`, то есть FiredAt, а не начало отказа) и оба письма — `firing` и `resolved`.
Правило `DemoApi5xxFromLogs` при этом молчало, как и ожидалось: `reset_peer` рвёт
соединение до приложения, 5xx в логах не появляется.

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
| 2026-11-08 | вручение письма | скриншот из ящика (`docs/images/alert-email.png`) | письмо получено: в кадре тело уведомления по `page`-пробе, личных адресов нет; кадр снят вручную. Файл **заменён 2026-11-10** кадром нового шаблона (строка ниже) — здесь описан кадр от 08.11 |
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
| 2026-11-10 | дашборд «Уведомления» в Grafana | `kubectl diff/apply -k deploy/dashboards`, лог sidecar `grafana-sc-dashboard`, запросы Loki и Prometheus напрямую | `ConfigMap/notifications` создан (метка `grafana_dashboard=1`, папка `demo`), `demo-red` и `slo-demo` без диффа; sidecar записал файл и получил `Dashboards config reloaded` (200), `provisioning.dashboard` без ошибок; селектор лог-панели за 6 ч вернул 1 строку `notification_received` (`Watchdog`, `severity: none`), `up{job="alert-sink"} = 1`, `time() - max(alertsink_last_notification_timestamp_seconds)` ≈ 7 082 с; `increase()` по счётчикам = 0 — под рестартовал (`exitCode 255`) за секунды до единственного уведомления, поэтому панели, обещавшие окно, после ревью переведены на счётчики «с запуска пода» и ConfigMap применён повторно (sidecar снова ответил `Dashboards config reloaded`); проверено живьём: `sum(alertsink_notifications_total) = 1`, `sort_desc(sum by (alertname, status) (alertsink_alert_events_total))` = `Watchdog/firing = 1`, `sum(increase(alertsink_requests_total{outcome!="ok"}[15m]))` — пусто (отказов не было), панель показывает 0 |
| 2026-11-10 | версия и tzdata Alertmanager (нужны для шаблона письма) | `kubectl -n monitoring get pod … -o jsonpath`, `kubectl exec … ls /usr/share/zoneinfo/Europe/Moscow` | образ `v0.34.1` (тот, чьи исходники читались), зона `Europe/Moscow` в контейнере есть — `tz "Europe/Moscow"` не уронит рендер |
| 2026-11-10 | арифметика в шаблонах Alertmanager | локальный рендер шаблона пакетом `alertmanager/template` версии `v0.34.1` (`go run`) | text и html собираются, `.StartsAt.UnixMilli` = `1794309993000`, `tz` даёт `10.11.2026 14:26:33 MSK`; `{{ toDuration "-15m" }}` → `function "toDuration" not defined` — «startsAt минус for» вычислить нечем |
| 2026-11-10 | параметры URL Grafana 13.2.4 | бандлы из `/public/build/*.js` (`grep`) | `viewPanel` (8 вхождений) и `time.window` присутствуют в отданных чанках — ссылка «окно инцидента» опирается на документированный формат `time`+`time.window` |
| 2026-11-10 | deep link из письма и аутентификация UI | `curl -o /dev/null -w '%{redirect_url}'` | `302 → /login?redirectTo=%2Fd%2Fdemo-red%3FviewPanel%3D5%26time%3D…` — после входа человек попадает на нужный вид; Grafana требует логин (`/api/dashboards/uid/demo-red` → 401), Prometheus и Alertmanager — без аутентификации |
| 2026-11-10 | шаблон письма в живом контуре | `kubectl apply -f rules/demo-slo-alerts.yaml -f rules/meta.yaml`; JSON6902-патч `emailConfigs[0].{text,html}` на живом `AlertmanagerConfig` (адреса и Secret не тронуты); `POST /api/v2/alerts`; `/metrics` Alertmanager, `/timeline` sink | после apply правила отдают новые анкоры и `logs_url` (`/api/v1/rules`: `slodemoavailabilityburnfast`, `logs_url: да`), у meta-сторожей `logs_url` нет; `alertmanager_config_last_reload_successful = 1`, в сгенерированном конфиге шаблон есть (`grep` «Ранбук: пошаговая диагностика» = 1, `time.window=1800000` = 2); проба `EmailProbePage` (`page`) → `alertmanager_notifications_total{integration="email"} = 1`, `increase(failed_total{integration="email"}[10m]) = 0`, запись в `/timeline` `12:55:14Z` со `starts_at 12:55:02Z` (письмо ушло и в sink по `continue`); вид и вручение письма проверяются вручную |
| 2026-11-10 | свои info-алерты → `ticket` в живом кластере | `kubectl apply -f rules/pipeline.yaml -f rules/meta.yaml` (+ `rules/notifications.yaml`), `/api/v1/rules`, `prometheus_rule_group_rules` | `LokiNotIngesting` и `SloDemoNoTraffic` — `severity=ticket`, `health=ok`, `lastError` нет; `ALERTS` по ним пусто; своих `info` не осталось (23 `ticket`, 4 `page`, 27 алертов). Побочно: `PrometheusRule demo-alerting-path` в кластере **отсутствовал** (три heartbeat-правила были только в git) — применён, групп проекта стало 11 вместо 10 |
| 2026-11-10 | ротация пароля SMTP | `kubectl -n monitoring get secret alertmanager-smtp -o jsonpath='{.metadata.managedFields}'`, `alertmanager_config_last_reload_success_timestamp_seconds` | до ротации в Secret была одна запись `kubectl-create` (2026-11-08) и конфиг перезагружался 12:54Z — то есть в кластере лежал **старый** пароль, хотя у провайдера он уже был сменён; после `create … --dry-run=client \| kubectl apply -f -` (вручную) появилась запись `kubectl-client-side-apply` 14:11:59Z, перезагрузка конфига 14:13:16Z, `last_reload_successful = 1` |
| 2026-11-10 | маршрут и письмо (финальная проверка v1.1) | `POST /api/v2/alerts` через port-forward Alertmanager, `/metrics` Alertmanager, `/timeline` sink, `curl …/api/v2/status` | дерево в живом конфиге: `alertname=~"AlertSink.*"` → `email` (`continue`), `severity=~"page\|critical"` → `email` (`continue`), `severity=~"ticket\|info\|warning\|none"` → `alert-sink`, catch-all → `alert-sink`. Проба `page` (`AcceptanceProbePage`): `email` 2 → 3, `failed_total{integration="email"}` = 0 и `increase(…[15m])` = 0, `AlertmanagerFailedReload` не горит, запись в `/timeline` 14:26:22.979Z; проба `ticket` (`AcceptanceProbeTicket`) — запись в `/timeline` есть, счётчик `email` не изменился. **Найдено расхождение**: в живом `AlertmanagerConfig` отсутствовала ветка `AlertSink*` → `email` (3 маршрута вместо 4 в git) — применён JSON6902-патч, перезагрузка 14:42:13Z; проба с `severity=ticket` и именем под шаблон `AlertSink.*` дала `email` 6 → 7 **и** запись в `/timeline` — сигнал о поломке пути доходит до человека |
| 2026-11-10 | дрилл `errors` (финальная проверка v1.1) | `./drills/errors.sh` (toxiproxy `reset_peer`), `/timeline` sink, `evidence/2026-11-10-errors.json` | `result: passed`, 8 утверждений; доля ok упала до 0 (`ratio_5m` 1 → 0,43 → 0), `SloDemoAvailabilityBurnFast` (`page`) доставлен в 14:35:32Z при инъекции в 14:26:53Z — **`starts_at` = 14:35:22,127Z, то есть FiredAt, а не начало инъекции** (закрывает «подтверждено только кодом»); реакция 519 с (порог 900), после снятия токсина `resolved` в 14:40:02Z, восстановление 268 с (порог 600), `ratio_5m` вернулась к 1. Письма (счётчик `alertmanager_notifications_total{integration="email"}` по шагам): 4 → 5 на `firing` в 14:36Z и 5 → 6 на `resolved` в 14:40Z при `failed_total = 0` — ветка `sendResolved` у e-mail проверена живым алертом, а не пробой |
| 2026-11-10 | сторож правила Loki ruler: `LokiRulerRulesMissing` | удалён ключ `demo-api-5xx.yaml` из ConfigMap `loki-rules` (JSON-patch), `/api/v1/rules`, `/timeline`, возврат `kubectl apply -k deploy/loki-rules` | серия `loki_prometheus_rule_evaluations_total{rule_group="…;demo-api-logs"}` пропала → `pending` → `firing` в 14:20:28Z (инъекция 14:07:30Z: сначала ~5 мин до исчезновения серии, затем `for: 10m`), запись в `/timeline` 14:20:38Z (`severity=ticket`), возврат ConfigMap — `resolved` в 14:22:28Z, доставка 14:22:38Z; серия вычислений вернулась (`count = 1`), `health: ok`. Второй сторож `LokiRulerEvaluationFailing` живьём **не проверялся** — только `promtool`-тест |
| 2026-11-10 | `ticket` на новом severity: `SloDemoNoTraffic` | `kubectl -n demo scale deploy/demo-load --replicas=0`, `/api/v1/rules`, `/timeline`, возврат реплик | `pending` с 14:08:52Z, `firing` в 14:23:52Z (инъекция 14:07:37Z, `for: 15m` — сходится), доставка в `/timeline` 14:24:02Z, `resolved` после возврата реплик в 14:25:22Z, доставка 14:25:32Z; `email` 2 → 2 — в почту **не** ушло, как и должно для `ticket`; ни один `page` за окно не загорелся (`ALERTS{alertstate="firing",severity="page"}` за час — пусто), трафик после возврата 1,43 rps |
| 2026-11-10 | heartbeat пути: опорные серии | `/api/v1/rules`, `up{job="alert-sink"}`, `alertsink_last_notification_timestamp_seconds` | три правила группы `demo-alerting-path.heartbeat` — `health: ok`; `up{job="alert-sink"} = 1`; `alertsink_last_notification_timestamp_seconds` = 14:42:57Z (> 0, обновился после доставок). **`firing` самих heartbeat-правил не проверялся**: нужна 5,5-часовая тишина маршрута — логика покрыта `promtool`, живьём проверены только опорные серии |
| 2026-11-10 | доступ к UI и ссылки | `curl -H 'Host: …'`, `curl -o /dev/null -w '%{redirect_url}'`, `api.github.com/repos/…` | Prometheus 302 → `/query`, Alertmanager 200, Grafana `/login` 200; deep link `/d/notifications` → 302 на `/login?redirectTo=%2Fd%2Fnotifications…`; `HEAD` на Prometheus/Alertmanager даёт 405 — проверять надо `GET`. **Репозиторий на GitHub отдаёт 404 без авторизации** — на момент проверки репозиторий был приватным, поэтому ссылки `runbook_url` из писем у постороннего не открывались |
| 2026-11-10 | реальная поломка пути уведомлений: `AlertSinkTargetMissing` | `kubectl -n demo scale deploy/alert-sink --replicas=0`, `/api/v1/rules` (pending/firing), `/api/v2/alerts` Alertmanager (состояние и получатели), `/metrics` Alertmanager, `/timeline` после возврата | реплика 0 в 15:37:52Z, `up{job="alert-sink"}` исчез; `pending` с 15:39:08Z → `firing` 15:49:08Z — ровно 10 минут, как `for: 10m`. В Alertmanager алерт был `active` с получателями **`email` и `alert-sink`**: сигнал о поломке пути ушёл в почту веткой `alertname=~"AlertSink.*"`, а не умер вместе с путём (это тот самый маршрут, который отсутствовал в кластере до сегодняшнего патча). `alertmanager_notifications_total{integration="email"}` 10 → 11 (firing) → 12 (resolved), `failed_total{integration="email"} = 0`. Возврат реплики — под поднялся в 15:49:17Z, `resolved` доставлен в 15:50:18Z, в `/timeline` обе записи на месте. Честная оговорка: `webhook_failed_total` остался 0 — первая попытка Alertmanager после `group_wait` пришлась уже на живой sink, так что очередь ретраев к лежащему приёмнику этой пробой **не проверена** |
| 2026-11-10 | время алерта в дашборде «Уведомления» | `npm test` (alert-sink), `./scripts/check.sh`, `docker build` + `./scripts/import-image.sh` (`alert-sink:47e0e13`), `./scripts/deploy.sh` (адреса маршрута прочитаны из живого `AlertmanagerConfig`), `POST /api/v2/alerts`, `/metrics` и `/timeline` sink, Prometheus `/api/v1/query`, лог sidecar Grafana | дефект, найденный при просмотре UI: `alertsink_alert_events_total` не несёт времени события, и табличный instant-запрос показывал в `Time` момент запроса. Добавлена гейдж `alertsink_alert_start_timestamp_seconds{alertname,status}` = `startsAt` из payload (максимум по паре; без `startsAt` — время приёма), скрыта колонка `Time`, рядом панель «Начало алерта по паре» (секунды ×1000 под `dateTimeAsIso`). Живая проба `VerifyAlertStartMetric` (`severity=none`, `startsAt` 16:53:08Z, `endsAt` 17:04:39Z): `firing` в `/timeline` 17:03:10.985Z, `resolved` 17:05:11.034Z, обе записи дошли по маршруту Alertmanager → sink; в Prometheus `alertsink_alert_start_timestamp_seconds{alertname="VerifyAlertStartMetric",status="firing"} = 1794329588` при `time() - метрика` ≈ 677 с — колонка показывает начало алерта, а не «сейчас». Провижининг: `Writing /tmp/dashboards/notifications.json (ascii)` и `Dashboards config reloaded` (200), `provisioning.dashboard` без ошибок, в живом ConfigMap 8 панелей. Через три минуты пришло настоящее уведомление: `Watchdog` (`firing`) в `/timeline` 17:06:09.394Z, `startsAt` 15:05:40Z → `alertsink_alert_start_timestamp_seconds{alertname="Watchdog",status="firing"} = 1794301540.484`, то есть панель живая на реальном трафике, а не только на пробе. Вид панели глазами не проверен — Grafana требует логин |
| 2026-11-10 | скриншоты для README | просмотр трёх файлов из `docs/images/`, скан ворот по трекаемому тексту | `demo-red.png` (1057×622, окно 1 час: всплеск доли ошибок от дрилла `errors` и восстановление, лог-панель непустая), `slo-demo.png` (1013×628, окно 6 часов: четыре `stat`, оба burn rate, таблица разбивки), `alert-email.png` (833×248, тело письма после правки шаблона: одна ссылка на Alertmanager, MSK и UTC, дубля нет). В кадрах нет IP, адресов почты и имён нод — только имена сервисов кластера; скан ворот зелёный. Кадры добавлены в репозиторий коммитом `docs(images)` (`70e3c4f`) |
| 2026-11-10 | почему на кадре `slo-demo` бюджет 3 % и латентность 97,57 % | `slo:demo_*:ratio_3d`, `histogram_quantile` клиента (`load_request_duration_seconds`) и сервера (`http_request_duration_seconds`), `container_cpu_cfs_throttled_periods_total`, `node_load1` | за 3 суток: доступность 99,05 %, латентность 97,61 % (цель 99 %). Просадки локализованы по 15-минутным окнам: 07.11 15:17–19:03 (97,7 % → 72 %), 09.11 15:33–18:33 (98,8 % → 91 %), 10.11 09:33 (77 %, сразу после старта нод). В эпизоде 09.11 17:48Z клиентская p95 **930 мс** против серверной **6,4 мс**, троттлинг cgroup `demo-load` **23 %** периодов CFS, исходы `timeout` 0,14/с, `node_load1` 0,5 — узел не перегружен, ограничен сам генератор; значит SLI считает задержку, которую произвёл клиент, а не сервис (это и есть причина, по которой в проекте появилось правило `LoadGeneratorThrottled`). Оно добавлено 2026-11-09 21:55 MSK, то есть **позже** эпизодов 07.11 и 09.11 — сработать там оно не могло; сегодняшний провал 09:33 (клиент p95 456 мс при троттлинге 0 %) к троттлингу не относится, причина не установлена (холодный старт после загрузки нод). Бюджет доступности: один дрилл `errors` (16 минут почти 100 % ошибок) съедает ≈37 % трёхдневного бюджета, остальное — другие дриллы и окна с `timeout` |
| 2026-11-10 | полный `deploy.sh` после правки шаблона письма | `IMAGE_TAG=de1d9ba ./scripts/deploy.sh` с e-mail env, прочитанными из живого `AlertmanagerConfig` (значения не печатались); лог `.tmp/deploy-full-2026-11-10.log` | exit 0. Apply без пересоздания подов: `restarts` у `alert-sink`/`demo-api`/`demo-load`/`toxiproxy` не изменились. Цели `demo-api 2`, `demo-load 1`, `alert-sink 1`, ok-трафик 4,99 rps; гейт «маршрут активен» и `last_reload_successful` — успешны; групп правил проекта 11 (ожидалось 11); серии `slo:*` пишутся; `SloAlertRulesAbsent` ложных `ALERTS` не даёт. В активном конфиге Alertmanager дерево из четырёх child-route (включая `alertname=~"AlertSink.*"` → `email`) — расхождение закрыто, git и кластер сходятся. Шаблон письма в живом объекте: подпись «Alertmanager (силенсы, статус)» — 1, `href="{{ .ExternalURL }}"` — 1, ссылка **после** `range .Alerts`; Alertmanager перезагрузил конфиг `16:44:39Z`. В `firing` только `Watchdog` (`severity: none`). Свои объекты: 6 `PrometheusRule`, 3 дашборда |
| 2026-11-10 | дашборд «Уведомления»: одна таблица вместо двух | `kubectl apply -k deploy/dashboards`, лог sidecar `grafana-sc-dashboard`, живой ConfigMap `notifications`, `./scripts/check.sh` | по итогам просмотра в UI таблица «Алерты с запуска пода» удалена, «Начало алерта по паре» растянута на её место (`x 16→8`, `w 8→16`); панелей стало 7 (`stat` ×4, `bargauge`, таблица времени, журнал Loki). Sidecar записал файл и получил `Dashboards config reloaded` (200), `provisioning.dashboard` без ошибок; счётчик `alertsink_alert_events_total` в дашборде больше не выводится — он остался в `/metrics` и `/timeline`, о чём сказано в описании панели и в runbook. Зелёные ворота: `дашборды: файлов 3, панелей 19`. Вид панели глазами не проверен — Grafana требует логин |
| 2026-11-10 | покой контура после финальной проверки | `ALERTS`, `sum(increase(alertmanager_notifications_failed_total[1h]))`, `loki_prometheus_rule_evaluations_total` | в `firing` только `Watchdog` (`severity: none`), отказов отправки — 0, серии сторожей вернулись; шум стенда отдельно: в 13:43:37–13:43:42 kubelet перезапустил контейнеры `alert-sink`/`demo-api`/`demo-load` на одной ноде по liveness-пробе (`context deadline exceeded`, `exitCode 137`), OOM нет (пик 34 МиБ из 64 МиБ), `node_load1` в те же минуты 1,27 — совпало с прогоном офлайн-ворот на той же физической машине |

Как проверить это повторно (временное правило по реальному трафику, без выдуманных строк
и без правки кода) — раздел «Правила Loki ruler» в `docs/runbook.md`.

## Ещё не подтверждено живьём

Состояние после финальной проверки v1.1 (2026-11-10). Закрыто в этот день: живой `page`-алерт от SLO,
`startsAt = FiredAt`, `resolved`-ветка e-mail, доставка `ticket` на новом severity, сторож
`LokiRulerRulesMissing`, маршрут `AlertSink.*` → `email`, вручение письма и скриншоты
(см. строки таблицы выше).

- **Вид письма и работа его ссылок** — единственное, что осталось от блока «вручение»:
  письмо дошло до ящика (кадр `docs/images/alert-email.png` снят 2026-11-10),
  вид тела проверен по кадру — ссылка на Alertmanager одна, время в MSK и UTC, дубля
  «Стенд: …» нет. По клику не проверены: переход на GitHub-анкор ранбука (репозиторий
  пока приватный, см. пункт «публикация»), deep link в Grafana за логином
  (`viewPanel`/`time.window`), папка «Спам»; вид дашборда «Уведомления» глазами тоже
  не проверен — для этого нужен вход в Grafana;
- **`heartbeat` пути уведомлений**: `AlertSinkTargetMissing` проверен живьём 2026-11-10
  (погашенный sink → `firing` через 10 минут → письмо в почту, см. строку таблицы выше).
  Оставшиеся два — `AlertSinkHeartbeatMissing` (тишина дольше 5,5 ч) и `AlertSinkNeverReceived`
  (uptime >5,5 ч при нулевом gauge) — живьём **не проверены**: в выражениях жёсткий порог
  `19800` секунд, для проверки нужна тишина маршрута на вечер, то есть порча контура.
  Их логика покрыта `promtool`, опорные серии (`up`, `alertsink_*`) подтверждены;
- **`LokiRulerEvaluationFailing`** (вычисление правила ruler падает): живьём не инъецировался —
  нужен файл, который разбирается, но падает при вычислении; надёжного способа на стенде не
  нашли (ошибку хранилища воспроизводить дороже, чем ценность проверки). Покрыт `promtool`
  и разбором конфига в воротах. Первый сторож (`LokiRulerRulesMissing`) проверен живьём;
- **срабатывание `DemoApi5xxFromLogs` именно на реальном 5xx.** Путь «правило →
  Alertmanager → sink» доказан 2026-11-09 пробным правилом на обычных логах, но ни одного
  настоящего 5xx от `demo-api` в лабе не возникает: единственный источник 5xx — `503`
  самопроверки `/ready` при дренаже, и он из выражения исключён (иначе правило горело бы
  на каждом рестарте пода). Дрилл `errors` этого не изменил: `reset_peer` на toxiproxy рвёт
  соединение **до** приложения, в логах остаются `status: 200` и `request_aborted` (499) —
  ни то, ни другое под условие `status >= 500` не попадает (проверено 2026-11-10 ещё раз:
  правило при живом дрилле молчало, как и предсказано). Чтобы правило горело на настоящем
  5xx, нужна инъекция 5xx в `demo-api` (отдельный маршрут) и свой дрилл; в текущую
  версию это не входит;
- **глазами**: вид дашборда «Уведомления», клик по `time`/`time.window` и по
  процент-кодированному кириллическому анкору — нужны вход в Grafana и клик по ссылке из
  письма; тело письма уже просмотрено по кадру (см. пункт выше);
- **публикация**: на момент проверки `api.github.com/repos/…` отвечал 404 без авторизации —
  репозиторий был приватным, поэтому абсолютные `runbook_url` из писем у постороннего
  не открывались. Прогон `ci.yml` на GitHub и тег `v1.1` на момент записи не
  подтверждены; после публикации пункт проверяется одним кликом по ссылке «Ранбук»
  в письме.

Дополнительно известно и не проверяется: slow-burn алерт (1x / 3d) требует трёх суток
непрерывных данных — его логика покрыта `promtool test rules`, живой прогон не планируется.