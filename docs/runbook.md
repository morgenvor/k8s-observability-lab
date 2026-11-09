# Runbook — k8s-observability-lab

Процедуры для лабы: как поставить инструменты, доставить демо-контур в k3s и что делать,
если что-то не отвечает. Правила и архитектура проекта и история решений ведутся в
рабочих документах (`AGENTS.md`, `CHANGELOG.md`) — они в публикуемый набор не входят;
здесь только процедуры и проверки.

Доступ к кластеру и к нодам — файлы в каталоге `.secrets/` рядом с проектом. Каталог
в `.gitignore`: ни kubeconfig, ни ssh-конфиг в git не попадают, и в публикуемом наборе
их нет. Скрипты берут пути из env, а при пустой переменной — из этого каталога:

| Переменная | Назначение | Значение по умолчанию |
|---|---|---|
| `KUBECONFIG` | доступ к кластеру k3s | `.secrets/kubeconfig` |
| `LAB_SSH_CONFIG` | SSH к нодам для импорта образов | `.secrets/ssh_config` |
| `IMAGE_TAG` | тег образов | короткий git SHA |
| `WAIT_TARGETS` | сколько секунд `deploy.sh` ждёт цели в Prometheus | `180` |

## Как адаптировать под свою лабу

Процедуры ниже написаны под конкретный стенд, но переносимы. Что придётся поменять:

- **Host'ы UI.** Домен `*.lab.internal` — намеренный плейсхолдер, а не адрес чужой лабы:
  реальных имён в репозитории нет. Свои имена задаются в `helm/values/kps.yaml`
  (`prometheus.ingress.hosts`, `alertmanager.ingress.hosts`, `grafana.ingress.hosts`);
  после `helmfile apply` их надо прописать в `/etc/hosts` машины, с которой открываешь UI,
  как `IP ноды  <host>`. Класс ingress — `traefik` (встроен в k3s); другой контроллер не
  нужен. Пока host не резолвится, Traefik отвечает 404 — это ожидаемо.
- **Имена.** Namespace `demo`/`monitoring`, метки `app`, `service`, имена дашбордов
  `demo-red`/`slo-demo` и datasource `uid: loki` продублированы в правилах, манифестах и запросах
  панелей. Переименование — это правка `rules/*.yaml`, `deploy/`, `deploy/dashboards/*.json`
  и `helm/values/kps.yaml` вместе; частично переименованный набор даёт молчащие алерты.
- **Registry.** Его нет: образы собираются локально и импортируются в containerd **каждой**
  ноды (`scripts/import-image.sh`), тег = короткий git SHA. Сторонние образы (Loki, Alloy,
  `busybox` для init-контейнера Grafana) — тем же путём через `IMPORT_IMAGES`. Если у тебя
  есть registry, `import-image.sh` можно не использовать, но теги в `helm/values/*.yaml`
  и `deploy/base/kustomization.yaml` тогда задаются иначе.
- **Число нод.** Правила и фильтр Alloy рассчитаны на «одна реплика Alloy на ноду»;
  одна нода тоже работает (тогда `up{job="alloy"}` — одна серия).
- **Доступ к кластеру.** Положи свой kubeconfig в `.secrets/kubeconfig`, а ssh-конфиг —
  в `.secrets/ssh_config` (каталог в `.gitignore`, режим `600`); либо задай `KUBECONFIG`
  и `LAB_SSH_CONFIG` на файлы в любом другом месте. Это **копии**: при смене доступа
  (перевыпуск сертификата кластера, другие ноды) их надо обновить — устаревший
  kubeconfig даёт `кластер не отвечает` или `Unauthorized`, а не ошибку скрипта.
  SSH-ключи в проекте не лежат: `ssh_config` ссылается на них по пути вне репозитория.

## 1. Инструменты (один раз на машине и в CI)

```bash
./scripts/bootstrap-tools.sh
```

Кладёт `helm`, `helmfile`, `kubectl`, `kubeconform`, `promtool` и плагин `helm-diff` в
`.tools/` (вне git), версии пиннуются в скрипте. Повторный запуск идемпотентен.
Офлайн-проверки проекта — одна команда:

```bash
./scripts/check.sh            # без сборки образов
./scripts/check.sh --images   # плюс docker build обеих приложений
CHECK_STRICT=1 ./scripts/check.sh   # как в CI: любой пропуск проверки — провал
```

`--strict` / `CHECK_STRICT=1` нужен потому, что иначе отсутствие инструмента
(`shellcheck`, `yamllint`, `docker`) оставляет ворота зелёными при меньшем покрытии:
в конце печатается список пропусков, и в строгом режиме он превращается в провал.
Отдельный шаг — тесты поведения дриллов без кластера (`bash drills/tests/signals.sh`,
он же внутри `check.sh`): прерванный дрилл не должен оставлять evidence `passed`.

## 2. Сборка и импорт образов

Registry в лабе нет: образы собираются локально и импортируются в containerd обеих нод.

```bash
./scripts/build-image.sh     # печатает теги вида demo-api:<sha>, demo-load:<sha>
./scripts/import-image.sh    # docker save | ssh 'sudo k3s ctr images import -' на каждую ноду
# сторонний/крупный образ (Loki, Alloy) — тоже импортом, если нода не тянет docker.io:
IMPORT_IMAGES="grafana/loki:3.6.11 grafana/alloy:v1.21.3" ./scripts/import-image.sh
```

Почему на обе ноды: поды раскидываются по нодам планировщиком, и импорт только на одной
даёт `ImagePullBackOff` на второй. `import-image.sh` берёт список нод у самого кластера
(`kubectl get nodes`) и после импорта проверяет тег через `k3s ctr images ls`.

Отдельный случай — `busybox:1.38.0`: чарт Grafana добавляет в под init-контейнер
`init-chown-data` (`chown 472:472 /var/lib/grafana`), потому что PVC на `local-path` —
это hostPath, и `fsGroup` на такой том не применяется. Без образа под Grafana висит в
`Init:ImagePullBackOff`, поэтому после включения PVC busybox импортируется так же:

```bash
IMPORT_IMAGES="busybox:1.38.0" ./scripts/import-image.sh
```

Тег = короткий git SHA: пересборка того же коммита перезаписывает тот же тег, поэтому
после правки кода сделай новый коммит (или задай `IMAGE_TAG`) и повтори импорт.

Первый импорт **нового** тега даёт пик записи на диск, и на control-plane от этого может
перезапуститься `k3s` (embedded etcd теряет лидерство; поды переживают, данные целы —
факт лабы 2026-11-03). `import-image.sh` это учитывает: при сбое ждёт готовности API и
containerd ноды, затем повторяет импорт один раз. Импорт новых образов лучше не совмещать
с другими работами на кластере.

Для крупных образов (Alloy 705 MB) стрим по ssh — худший вариант: пока он течёт,
containerd пишет на диск десятки секунд, API starve-ится и k3s падает с
`leaderelection lost` (факт 2026-11-04, повторилось 3 раза подряд). Поэтому
`IMPORT_IMAGES` работает иначе: tar кладётся файлом на ноду (`scp` + `/tmp`) и
импортируется оттуда с `--no-unpack` (~11 с, API не страдает). Образ распакуется при
первом старте пода — первый запуск на ноде поэтому дольше обычного.

## 3. Доставка демо-контура

```bash
./scripts/deploy.sh
```

Скрипт рендерит `deploy/base` + `deploy/dashboards` в `.tmp` (теги подставляет там же,
трекаемый `kustomization.yaml` не меняется), применяет манифесты, ждёт rollout трёх
деплойментов, затем через порт-форвард к Prometheus проверяет, что все цели
`up{job=~"demo-.*"}` равны 1 (до `WAIT_TARGETS` секунд — ServiceMonitor подхватывается
оператором не мгновенно).

Что появляется в кластере:

| Объект | Namespace | Зачем |
|---|---|---|
| `namespace/demo` | — | всё демо-содержимое отдельно от `monitoring` |
| `deploy/demo-api` (2 реплики) | `demo` | фикстура с RED-метриками, `/metrics` |
| `deploy/demo-load` | `demo` | нагрузка 5 rps через toxiproxy, клиентские метрики |
| `deploy/toxiproxy` | `demo` | точка инъекции сетевых сбоев (API `:8474`, прокси `:12001`) |
| `ServiceMonitor/demo-api`, `demo-load` | `demo` | скрейп с меткой `release: monitoring` |
| `ConfigMap/demo-red` | `monitoring` | дашборд Grafana (sidecar по метке `grafana_dashboard=1`) |
| `ConfigMap/slo-demo` | `monitoring` | дашборд SLO/burn rate (фаза 3), та же метка |
| `PrometheusRule/demo-slo`, `demo-slo-alerts` | `monitoring` | записывающие правила SLI и 6 burn-rate алертов (фаза 3) |
| `PrometheusRule/demo-infra`, `demo-meta` | `monitoring` | инфраструктурные и мета-алерты (фаза 3) |
| `PrometheusRule/demo-logs-pipeline` | `monitoring` | семь правил пайплайна логов Loki/Alloy (2026-11-07) |

Правка `deploy/base/toxiproxy.json` подхватывается сама: конфиг собирается
`configMapGenerator`, хеш попадает в имя ConfigMap и в pod template, поэтому
`./scripts/deploy.sh` перезапускает под `toxiproxy` без ручного `rollout restart`.
Если ConfigMap применяли руками (`kubectl apply -f`), хеш не обновится — тогда
`kubectl -n demo rollout restart deploy/toxiproxy`. Старый ConfigMap после переименования
не удаляется автоматически (`apply` без `--prune`) — удали его руками:
`kubectl -n demo get cm` → `kubectl -n demo delete cm <старое-имя>`.

Применять корневой `kustomization.yaml` напрямую (`kubectl apply -k .`) нельзя: в нём
заглушка `newTag: local`, поды уйдут в `ImagePullBackOff`. Штатный путь — `deploy.sh`.

Откат (удаляет namespace `demo` целиком, дашборды `demo-red`/`slo-demo` и пять
`PrometheusRule` в `monitoring` — то есть вместе с правилами уходит и SLO-оповещение;
образы в containerd остаются):

```bash
./scripts/rollback.sh        # спросит подтверждение
./scripts/rollback.sh --yes  # без вопроса
```

### Приёмка после деплоя

Что `deploy.sh` проверяет сам: `up == 1` у двух эндпоинтов `demo-api`, у `demo-load` и
`alert-sink`; живой ok-трафик; загрузку всех групп правил проекта; что сторож
`SloAlertRulesAbsent` не горит ложно (селектор находит 2 группы) и что серии `slo:*`
пишутся. Остальное проверяется временем — через 10 минут после apply:

```bash
# ничего не загорелось зря: 0 горящих ALERTS, кроме Watchdog
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 &
curl -sG http://127.0.0.1:9090/api/v1/query \
  --data-urlencode 'query=count(ALERTS{alertstate="firing",alertname!="Watchdog"}) or vector(0)' \
  | jq -r '.data.result[0].value[1]'
# ожидается 0; если не 0 — смотри, какая группа и какой lastError ниже
```

`Watchdog` в счёт не входит: он всегда `firing` по определению, и его наличие —
признак живого пути уведомлений, а не сбоя.

## 4. Где смотреть метрики и логи

```bash
# поды и их ноды ($KUBECONFIG уже экспортирован)
kubectl -n demo get pods -o wide
# UI — по именам через штатный Traefik k3s, без port-forward (см. ниже)
curl -sI -H 'Host: prometheus.lab.internal'   http://<нода>/ | head -1   # 302 → /query
curl -sI -H 'Host: alertmanager.lab.internal' http://<нода>/ | head -1   # 200
curl -sI -H 'Host: grafana.lab.internal'      http://<нода>/login | head -1  # 200
# port-forward нужен только тому, что в ingress не публикуется (Loki API, alert-sink):
kubectl -n monitoring port-forward svc/loki 3100:3100
kubectl -n demo port-forward svc/alert-sink 8080:8080
```

### Доступ к UI: Ingress и `/etc/hosts` (с 2026-11-07)

Prometheus, Alertmanager и Grafana опубликованы `Ingress`-объектами в
`helm/values/kps.yaml` (`prometheus.ingress`, `grafana.ingress`,
`alertmanager.ingress`), класс — встроенный в k3s `traefik`. Отдельный контроллер не
ставится: k3s уже держит Traefik на 80/443 обеих нод через klipper-lb
(`kubectl -n kube-system get svc traefik` → EXTERNAL-IP = IP нод).

```bash
kubectl -n monitoring get ingress
# NAME                                      CLASS     HOSTS
# monitoring-grafana                        traefik   grafana.lab.internal
# monitoring-kube-prometheus-alertmanager   traefik   alertmanager.lab.internal
# monitoring-kube-prometheus-prometheus     traefik   prometheus.lab.internal
```

Маршрутизация **host-based**, а не по путям: у Prometheus и Alertmanager
`--web.route-prefix=/`, их UI рассчитан на корень, и смена префикса потянула бы
рестарт подов. Имена резолвит рабочая машина — записью в её `/etc/hosts`
(`<workstation-ip>` — адрес машины, с которой открывают UI, `<node-ip>` — адрес ноды,
на которой слушает Traefik):

```
<node-ip>  prometheus.lab.internal alertmanager.lab.internal grafana.lab.internal
```

Дальше в браузере: `http://grafana.lab.internal/`, `http://prometheus.lab.internal/`,
`http://alertmanager.lab.internal/`.

- **Без правильного `Host` Traefik отвечает 404** — это ожидаемо, а не поломка
  ingress. Проверка без правки hosts — `curl -H 'Host: grafana.lab.internal'`.
- **Класс `traefik` и имена проверяются офлайн** шагом «доступ к UI (Ingress) в
  рендере» в `./scripts/check.sh`: он же сверяет, что `externalUrl` в CR
  Prometheus/Alertmanager и `server.domain` в `grafana.ini` выводятся из этих host'ов
  (чарт делает это сам из первого host'а Ingress). Без этого UI открывается, но
  ссылки внутри ведут на внутренние имена кластера.
- **Первый `helmfile apply` с ingress перезапустил все три пода** (2026-11-07):
  чарт поменял `externalUrl` в CR и `server.domain` в `grafana.ini`, а вместе с ними
  `checksum/config` в pod-шаблонах. Данные целы (PVC и WAL на месте), но пауза в
  несколько секунд была — это не «просто добавили Ingress».
- **`helmfile diff` по релизу `monitoring` всегда непустой**: admin-пароль Grafana
  рендерится случайным (`lookup` переиспользует живой только на `apply`), поэтому в
  diff видны `checksum/secret` и Secret, плюс `volumeName` у PVC. Смотреть надо на
  реальные поля, а изменённые объекты helm-diff печатает строкой
  `… has changed:`, добавленные — `… has been added:`.
- **Аутентификации нет** у Prometheus и Alertmanager: из подсети лабы можно создать
  silence (заглушить алерты) и дёрнуть lifecycle-эндпоинты Prometheus
  (`--web.enable-lifecycle` включён). Для изолированной лабы принято осознанно.
- Кнопка «Silence» в UI Prometheus ведёт на Alertmanager по адресу из
  `/api/v1/alertmanagers`, а там pod IP (`<pod-ip>:9093`) — из браузера он не
  открывается. Силенсы создавать в UI Alertmanager.

- Дашборд `demo — RED и латентность` (uid `demo-red`): RPS, доля ошибок (клиент/сервер),
  p95 по обеим гистограммам, доля запросов ≤ 300 мс (latency SLO) и панель «Логи demo
  (Loki)» — журнал всего namespace `demo` из Loki, новые строки сверху; поля JSON
  (`status`, `duration_ms`, `request_id`) видны по клику на строку.
- Дашборд `demo — SLI/SLO и burn rate` (uid `demo-slo`): остаток бюджета ошибок по двум
  SLO, текущий SLI за 3 дня, burn rate по окнам 5m/1h/30m/6h/3d, таблица по SLO,
  аннотация сработавших алертов на таймлайне.
- Метрики приложения: `http_requests_total{method,route,status_class}`,
  `http_request_duration_seconds{method,route}` (бакеты с `0.3`), `http_inflight_requests`.
- Метрики нагрузки: `load_requests_total{outcome="ok|error|timeout"}`,
  `load_request_duration_seconds`.
- Записанные серии SLO: `slo:demo_availability:ratio_<окно>`,
  `slo:demo_latency:ratio_<окно>` (доля ≤ 300 мс) и `...:burn_rate_<окно>`; окна —
  `5m`, `1h`, `30m`, `6h`, `3d`. Метки `service="demo-api"`, `slo="availability|latency"`.
- Логи приложений — stdout подов (`kubectl -n demo logs deploy/demo-api`), каждая строка
  JSON. Сбор в Loki — раздел «Логи (фаза 5)» ниже.

### Логи: Loki и Alloy (фаза 5)

```bash
helmfile apply -l name=loki -l name=alloy    # ставит оба релиза (values в helm/values/)
kubectl -n monitoring get pods,pvc | grep -E 'loki|alloy'
kubectl -n monitoring logs ds/alloy -c alloy --tail=20   # tailer'ы и ошибки записи
# API Loki (Service ClusterIP, поэтому порт-форвард)
kubectl -n monitoring port-forward svc/loki 3100:3100
#   http://127.0.0.1:3100/loki/api/v1/labels
#   http://127.0.0.1:3100/loki/api/v1/query_range?query={namespace="demo"}
#   http://127.0.0.1:3100/metrics  → loki_ingester_memory_streams (кардинальность)
#   http://127.0.0.1:3100/config   → живой конфиг (retention_period, compactor)
```

- В Grafana datasource `loki` (`uid: loki`, URL `http://loki.monitoring.svc:3100`) приезжает
  из `helm/values/kps.yaml` → `grafana.additionalDataSources`; ConfigMap
  `monitoring-kube-prometheus-grafana-datasource` читает sidecar
  `grafana-sc-datasources`, под Grafana при этом **не перезапускается**. Проверка
  запросом: `{namespace="demo", app="demo-api"} | json` → поля `status`, `duration_ms`,
  `request_id`.
- Метки потоков: `namespace`, `pod`, `container`, `app`, `app_kubernetes_io_name`,
  `cluster="lab-k3s"`, плюс `instance` (Alloy: `namespace/pod:container`) и
  `service_name`/`detected_level` (Loki 3.x). Собираются только namespace `demo` и
  `monitoring` — фильтр в конфиге Alloy.
- Alloy читает логи через Kubernetes API (`loki.source.kubernetes`), поэтому hostPath
  `/var/log/pods`, root и privileged не нужны: контейнер работает от UID 65534 с
  `readOnlyRootFilesystem` и `drop: [ALL]`, позиции пишет в emptyDir `/tmp/alloy`.
  RBAC сужен до `pods`, `pods/log`, `namespaces` (дефолтные правила чарта давали ещё
  cluster-wide `secrets`/`configmaps`; `clusterRules` остались дефолтными, потому что
  `clusterRules: []` ломает рендер чарта 1.15.0).
- **Каждая реплика читает только поды своей ноды** — `keep` по
  `__meta_kubernetes_pod_node_name` = `K8S_NODE_NAME`. Проверка, что двойного сбора нет:
  у каждого пода свой набор `target=…` в логах, пересечения нет
  (`kubectl -n monitoring logs <alloy-pod> -c alloy | grep -o 'target=[^ ]*' | sort -u`).
  Логи ноды, на которой Alloy не запущен, не собираются — это семантика DaemonSet.
- Позиции чтения лежат в `/tmp/alloy` (emptyDir) внутри пода: после рестарта Alloy
  перечитывает логи контейнеров с начала, а Loki отбрасывает старые записи
  (`entry too far behind`, 400 в логе Alloy). Дублей в Loki нет — это шум, не потеря
  свежих логов.
- Retention 72h включает **compactor** (`loki.compactor.retention_enabled: true` +
  `delete_request_store: filesystem`); без них `limits_config.retention_period` не
  действует и PVC 5Gi забивается. Данные на PVC — логи, не источник истины:
  `helmfile destroy -l name=loki -l name=alloy` удаляет и PVC
  (`persistentVolumeClaimRetentionPolicy.whenDeleted: Delete`).
- Политика удаления тома различает «удалить релиз» и «остановить компонент»:
  `whenDeleted: Delete` (destroy убирает том — контракт отката), `whenScaled: Retain`
  (масштабирование в 0 том **не** удаляет). Дефолт чарта — `whenScaled: Delete`: при
  нём `scale sts loki --replicas=0` стирает PVC вместе с логами, а не «останавливает
  компонент». Если проверяешь алерт на «компонент пропал», предпочитай удалить под
  (StatefulSet пересоздаст) или снять `ServiceMonitor`, а не масштабировать STS;
  политика проверяется в `./scripts/check.sh`.
- Образы запинены тегами в `helm/values/loki.yaml` (`loki.image.tag`) и
  `helm/values/alloy.yaml` (`alloy.image.tag`): в лабе нет registry, и обновление до
  нового тега = правка values + `IMPORT_IMAGES="<образ>" ./scripts/import-image.sh`,
  иначе под уйдёт в `ImagePullBackOff`.
- Часть этих гарантий проверяется офлайн: шаг «семантика значений Loki/Alloy» в
  `./scripts/check.sh` падает, если из рендера пропали `retention_period: 72h`,
  `retention_enabled: true`, push-URL, фильтр по ноде, или вернулись canary/кеши.

### Правила Loki ruler (фаза 5 v1.1)

Ruler — компонент внутри того же пода Loki (`-target=all`), который исполняет правила
по логам и отправляет результат в Alertmanager. Это второй класс проверки после
метрик: в логах есть то, чего нет в метриках (конкретный `status`, `route`,
`request_id`, событие `request_aborted` без HTTP-ответа), и наоборот — сетевой обрыв
до приложения виден только клиентской метрике.

```bash
# что загрузилось (ruler API: порт 3100, тот же Service, что у Loki)
kubectl -n monitoring port-forward svc/loki 3100:3100
#   curl -s http://127.0.0.1:3100/prometheus/api/v1/rules    → группа demo-api-logs
#   curl -s http://127.0.0.1:3100/prometheus/api/v1/alerts   → что горит сейчас
# правила в поде лежат здесь (ConfigMap loki-rules, только на чтение)
kubectl -n monitoring get configmap loki-rules -o jsonpath='{.data}' | head -40
# доставка: Alertmanager UI (alertmanager.lab.internal) или /timeline у sink
kubectl -n demo port-forward svc/alert-sink 8080:8080   # → http://127.0.0.1:8080/timeline
```

- Один файл правила — `deploy/loki-rules/demo-api-5xx.yaml` (`DemoApi5xxFromLogs`,
  `severity: ticket`): `sum(count_over_time({namespace="demo", app="demo-api"} | json |
  status >= 500 | route != "/ready" [5m])) > 0`, `for: 2m`. Применяется с остальными
  манифестами (`./scripts/deploy.sh`) — kustomize отдаёт его как ConfigMap `loki-rules`.
- **`/ready` из подсчёта исключён намеренно.** На SIGTERM `demo-api` сразу отвечает
  `/ready` → 503, чтобы под убрали из endpoints; это штатный дренаж, а не отказ клиенту.
  Одна такая строка держится в окне `5m`, `for: 2m` выполняется — и без фильтра правило
  горело бы `ticket` на каждом деплое, `rollout restart` и дрилле `oomkill` (проверено
  на живых данных 2026-11-09: единственная 5xx-строка за 72 ч — именно `/ready` при
  SIGTERM). Дрилл `errors` правило не проверяет и не должен: `reset_peer` рвёт соединение
  до приложения, и 5xx в логах не появляется.
- **Тенант в пути — не опечатка.** Локальное хранилище правил читает
  `<directory>/<tenant>/<файл>`, а при `auth_enabled: false` тенант всегда `fake`.
  Поэтому том смонтирован в `/etc/loki/rules/fake`, и новый файл правила обязан
  попасть в этот каталог (ключ ConfigMap — имя файла). Правило, положенное в корень
  `/etc/loki/rules`, ruler не увидит: ошибки не будет, будет тишина.
- Правка правила в ConfigMap: kustomize генерирует его **без хеша в имени**, поэтому
  обновляется тот же объект, а под получает новые данные без пересоздания тома.
  Ruler перечитывает правила по своему циклу (интервал группы `1m`), рестарт пода
  Loki для этого не нужен.
- Отключение: `ruler.enabled: false` в `helm/values/loki.yaml` →
  `helmfile apply -l name=loki`. Если правило только мешает, но ruler нужен, дешевле
  убрать его файл из `deploy/loki-rules/kustomization.yaml`.
- Побочный эффект правки values Loki: apply пересоздаёт под **всего** Loki, то есть
  на время рестарта приём логов останавливается. Alloy при этом не теряет данные —
  он ретраит запись (в логе видны ошибки push), но Grafana в эти секунды не читает
  логи. В тихое окно это секунды, а не минуты.
- Офлайн-гарантия: шаг «Loki ruler в рендере» в `./scripts/check.sh` проверяет всю
  цепочку — блок `ruler` в конфиге Loki (URL Alertmanager, `enable_api`, локальное
  хранилище), том `loki-rules` у StatefulSet с путём тенанта, ConfigMap с нужным
  ключом и структуру самого правила (включая фильтр `route != "/ready"`).
- **Как проверить сам путь, не дожидаясь 5xx.** В лабе настоящих 5xx нет (единственный
  источник — `/ready` при дренаже, и он исключён фильтром), поэтому цепочку
  «ruler → Alertmanager → sink» проверяют временным правилом по обычному трафику:
  добавить в ConfigMap ключ `probe-path.yaml` с
  `expr: sum(count_over_time({namespace="demo", app="demo-api"} [5m])) > 0` и меткой
  `probe: loki-path`, дождаться `firing` и записи в `/timeline`, затем удалить ключ и
  вернуть ConfigMap к состоянию git (`kubectl apply -k deploy/loki-rules`). Замер
  2026-11-09: загрузка ~90 с после правки ConfigMap, `firing` через 10 с, доставка в
  sink через 8 с; удалённое правило выгружается из ruler примерно за 80 с. Пробное
  правило — единственная допустимая «синтетика»: оно не пишет выдуманных логов, а
  считает реальные, и в git его нет.

### Метрики Loki и Alloy (с 2026-11-07)

`ServiceMonitor` для обоих релизов включён в values, поэтому `up` и `/metrics` теперь
есть в Prometheus — порт-форвард нужен только для того, чего нет в метриках
(`/config`, `/loki/api/v1/*`, `/ready`).

```bash
# цели и метки job: у Loki чарт переписывает job в "monitoring/<service>"
kubectl -n monitoring get servicemonitor loki alloy
#   up{job="monitoring/loki"} — одна серия, up{job="alloy"} — по одной на ноду
# приём на стороне Loki и потери на стороне Alloy
#   sum(rate(loki_distributor_lines_received_total[15m]))
#   sum by (reason) (rate(loki_write_dropped_entries_total[10m]))
# кардинальность Loki (в Prometheus теперь есть; порт-форвард не нужен)
#   loki_ingester_memory_streams
```

- Почему метка `job` разная: шаблон Loki-чарта делает relabeling `job -> monitoring/$1`,
  шаблон Alloy — нет (job = имя Service). На этом соглашении держатся правила
  `rules/pipeline.yaml`, поэтому оно проверяется в `./scripts/check.sh` по рендеру:
  если чарт передумает, ворота упадут, а не алерты молча замолчат.
- Цена: ~2,2 тыс. серий у Loki (histogram'ы по роутам) и ~270 на реплику Alloy; при
  `scrapeInterval: 30s` это единицы процентов уже занятого TSDB, ничего не вытесняет.
- Офлайн шаг «метрики Loki/Alloy и PVC Grafana в рендере» проверяет наличие обоих
  `ServiceMonitor` с меткой `release: monitoring`, порт `http-metrics` и relabeling job.

### Grafana: хранилище (с 2026-11-07)

`/var/lib/grafana` — на PVC `monitoring-grafana` (1Gi, `local-path`), состояние
`grafana.db` переживает рестарт пода: часовой пояс пользователя, избранные (starred)
дашборды, папки, аннотации, API-ключи. Дашборды и datasource при этом по-прежнему
приезжают из ConfigMap — это разные вещи.

```bash
kubectl -n monitoring get pvc monitoring-grafana
kubectl -n monitoring get deploy monitoring-grafana -o jsonpath='{.spec.strategy.type}'   # Recreate
```

- `strategy: Recreate`, а не `RollingUpdate`: PVC `ReadWriteOnce` на `local-path`
  привязан к ноде, и при раскатке второй под на другой ноде получил бы
  `Multi-Attach`/`volume node affinity conflict`, то есть подвисший rollout. Плата —
  несколько секунд простоя Grafana при каждом обновлении.
- Проверка сохраности: задать в UI часовой пояс и звезду на дашборде → удалить под
  Grafana (`kubectl -n monitoring delete pod -l app.kubernetes.io/name=grafana`) →
  после старта настройки на месте. Данные лежат на ноде в
  `/var/lib/rancher/k3s/storage/pvc-<uid>_monitoring_monitoring-grafana/grafana.db`.
- Плагины Grafana тоже живут на этом томе (~55 МиБ из 1Gi). Если когда-нибудь
  понадобится больше — размер меняется в `helm/values/kps.yaml` (`grafana.persistence.size`),
  но `local-path` не умеет расширять существующий том: нужен новый PVC.
- Том один и тот же на ноду: если нода потеряется, потеряется и `grafana.db`. Для лабы
  это приемлемо; для «настоящего» Grafana нужен либо `StatefulSet` с бэкапом БД, либо
  внешняя БД.

### Правила Prometheus (фаза 3)

```bash
# применить/обновить правила и дашборды (полный путь — ./scripts/deploy.sh)
kubectl apply -k rules
kubectl apply -k deploy/dashboards
# что загрузилось и как себя чувствует: health есть у правил, у групп его нет —
# здоровье группы видно по отсутствию lastError и свежести lastEvaluation
kubectl -n monitoring get prometheusrule | grep -E 'demo-(slo|infra|meta|logs)'
curl -s http://127.0.0.1:9090/api/v1/rules | jq '.data.groups[] | select(.name|startswith("demo-")) | {name, lastError, evaluationTime}'
```

- Файлы в `rules/` — `PrometheusRule` CRD: их находит оператор по метке
  `release: monitoring`. `promtool` CRD **не читает**, поэтому локальная проверка идёт
  через `./scripts/check.sh`: он выгружает `spec.groups` в `.tmp/rendered/rulefiles`, и
  только по этой выгрузке работают `promtool check rules`/`test rules`.
- Группа правил считается здоровой, если в API у неё нет `lastError`, `lastEvaluation`
  свежий (порядка `interval`, 30 с), а `prometheus_rule_group_iterations_missed_total`
  равен 0.
- Если `SloRulesAbsent` горит, а `slo:*` серий нет — правило не загрузилось (проверь
  метку `release=monitoring` и логи контейнера `config-reloader`).
- `SloAlertRulesAbsent` (`rules/meta.yaml`, `severity: page`) — сторож групп burn-rate
  алертов: записанные `slo:*` живут, а страниц нет. Выражение смотрит на метрику
  Prometheus `prometheus_rule_group_rules`, у которой метка `rule_group` имеет вид
  `<путь к файлу правил>;<имя группы>` (проверено на стенде 2026-11-07: путь содержит
  UID PrometheusRule), поэтому селектор в правиле — по хвосту регуляркой. Проверить,
  что группы на месте:

  ```bash
  curl -sG http://127.0.0.1:9090/api/v1/query \
    --data-urlencode 'query=count by (rule_group) (prometheus_rule_group_rules{rule_group=~".*;demo-.*"})' \
    | jq -r '.data.result[].metric.rule_group'
  ```

  Ожидается 10 групп (две `demo-slo`, две `demo-slo-alerts`, две `demo-infra`,
  `demo-meta.pipeline`, две `demo-logs-pipeline`, `demo-alerting-path.heartbeat`). Если правило горит — группа
  `demo-slo-alerts` не загрузилась или падает: смотри `/api/v1/rules` и `lastError`,
  метку `release=monitoring` у PrometheusRule `demo-slo-alerts`. `scripts/deploy.sh`
  проверяет тот же селектор сразу после apply, чтобы неверный формат метки не дал
  ложный page (проверка через 10 минут после apply — раздел «Приёмка после деплоя»).
- Своих инфраструктурных правил десять: `KubePodOOMKilled`, `PVCNearlyFull` (>85 %
  занято, без прогноза роста) и `NodeMemoryAvailableLow` (<15 % свободной памяти узла)
  в `rules/infra.yaml` плюс семь правил пайплайна логов в `rules/pipeline.yaml`
  (список — следующим пунктом). Остальная инфраструктура (узлы, диски, `TargetDown`,
  перезагрузка конфига Prometheus, сбои уведомлений Alertmanager) приходит от чарта
  kube-prometheus-stack: её `runbook_url` указывает на runbooks.prometheus-operator.dev.
- Пайплайн логов — `rules/pipeline.yaml` (PrometheusRule `demo-logs-pipeline`), 7 правил:
  `LokiDown` и `LokiTargetMissing` (ticket), `LokiNotIngesting` (info),
  `AlloyDown`, `AlloyTargetMissing`, `AlloyCoverageIncomplete`, `AlloyDroppedLogs`
  (ticket). Пара «цель есть, но не отвечает» (`up == 0`) и «цели нет вовсе»
  (`absent(up)`) — разные сигналы: при удалённом поде/объекте серия `up` исчезает, и
  `up == 0` не сработает никогда. Проверка логики — `rules/tests/pipeline.test.yaml`
  (promtool); живая проверка «Loki пропал» 2026-11-07 дала firing `LokiTargetMissing`
  и доставку в `/timeline` (см. CHANGELOG).

### Маршрут уведомлений и alert-sink (фаза 4)

```bash
# применить маршрут (AlertmanagerConfig в monitoring) и сам sink
./scripts/deploy.sh      # НЕ `kubectl apply -k deploy/monitoring`: он запишет
                         # плейсхолдеры example.invalid вместо ваших адресов
# что реально уехало в Alertmanager: сгенерированный конфиг лежит .gz внутри секрета
# (в нём открытый пароль SMTP — маскируйте, прежде чем показывать)
kubectl -n monitoring get secret alertmanager-monitoring-kube-prometheus-alertmanager-generated \
  -o jsonpath='{.data.alertmanager\.yaml\.gz}' | base64 -d | gunzip \
  | sed -E 's/auth_password:.*/auth_password: <скрыт>/' | grep -A3 webhook_configs
# уведомления, которые дошли до получателя (кольцо последних 200, память пода)
kubectl -n demo port-forward svc/alert-sink 8080:8080
#   http://127.0.0.1:8080/timeline — JSON-лента {received_at, status, group_key, alerts}
#   http://127.0.0.1:8080/metrics  — alertsink_notifications_total{status,severity},
#                                    alertsink_alert_events_total{alertname,status}
```

- `Watchdog` (`vector(1)`, всегда firing) — эталон «маршрут работает»: он приходит в
  `/timeline` первым. Нет его при живых алертах в Prometheus — проверяй
  `alertmanagerConfigMatcherStrategy` (обязан быть `None`, иначе оператор подмешивает
  `namespace="monitoring"` и алерты из `demo` не доходят) и лог Alertmanager.
- Метрики sink в Prometheus: `alertsink_notifications_total` и `up{job="alert-sink"}`
  (цель добавлена сверх плана фазы 4, иначе метрики живут только в поде).
- `AlertmanagerConfig` — CRD версии **v1alpha1**: у operator 0.94.2 версии `v1` нет, и
  `apply` с ней падает на «no matches for kind AlertmanagerConfig», хотя офлайн-рендер
  и `kubeconform` этого не видят.
- У webhook стоит `maxAlerts: 50`: sink принимает тело до 1 MiB и отвечает 413 на
  большее, а такое уведомление Alertmanager ретраит бесконечно (группа никогда не
  попадёт в `/timeline`). Проверить действующее значение —
  `curl -s <alertmanager>/api/v2/status | jq -r .config.original | grep max_alerts`.
- Маршрут — дерево, а не один получатель: `severity=~"page|critical"` уходит **и**
  письмом (подраздел «E-mail (SMTP)» ниже), `ticket|info|warning|none` — в `/timeline`.
  `Watchdog` (`none`) разбирается веткой sink, `SloDemoAvailabilityBurnSlow` (`ticket`) —
  тоже. Алерты `critical` от чарта (например `AlertmanagerFailedReload`) теперь уходят
  письмом: это отказ компонентов стека, а не шум. `KubeControllerManagerDown`,
  `KubeSchedulerDown`, `KubeProxyDown` в этом стенде не появляются — компоненты выключены
  в `helm/values/kps.yaml` (в k3s у них нет своих целей).

### E-mail (SMTP): page и critical

Дерево маршрутов в `deploy/monitoring/alertmanagerconfig.yaml`:

- родитель — `alert-sink` (`groupBy: [alertname, service]`, `groupWait: 10s`,
  `groupInterval: 30s`, `repeatInterval: 4h`);
- child 1 — `alertname=~"AlertSink.*"` → receiver `email`, `continue: true` (алерты самого
  пути уведомлений: у них `severity: ticket`, но канал нужен вне sink);
- child 2 — `severity=~"page|critical"` → receiver `email`, `continue: true`;
- child 3 — `severity=~"ticket|info|warning|none"` → receiver `alert-sink`;
- child 4 — **catch-all без матчеров** → `alert-sink`.

Почему так: `page`/`critical` означают «человеку пора смотреть», `ticket|info|warning` —
«разберут в рабочее время», но журнал `/timeline` нужен и для доказательств дриллов,
поэтому `page` попадает в оба места (разные получатели — это два уведомления, а не
дубль одного). Первая ветка нужна по той же логике, но с другой стороны: `AlertSink*`
(`rules/notifications.yaml`) сообщают, что маршрут до sink сломан, и почта для них —
единственный канал, который не зависит от наблюдаемого пути. `continue: true` у первой ветки обязателен: без него Alertmanager
останавливается на ней и остальные ветки для того же алерта не рассматривает.
Catch-all — страховка от нового или отсутствующего `severity`: без него такой алерт
ушёл бы в `null`-получатель и исчез молча.

**Что нужно от окружения (в git этого нет):**

1. SMTP-провайдер с **паролем приложения** (Яндекс: «Пароли приложений» в ID; Mail.ru:
   «Пароли для внешних приложений»). Основной пароль ящика провайдеры для SMTP не
   принимают — это частая причина «auth» в логах.
2. `smarthost` под провайдера: `smtp.yandex.ru:465`, `smtp.mail.ru:465` (implicit TLS);
   порт 587 работает по STARTTLS, в конфиге уже стоит `requireTLS: true`.
3. Egress со стенда до этого хоста и порта — проверяется **до** работ:
   `nc -z smtp.yandex.ru 465` с рабочей машины и из кластера. Закрытый порт не лечится
   конфигом.

**Порядок: Secret → конфиг.**

```bash
# пароль не набираем в командной строке: она попадает в history и в список процессов
read -rsp 'пароль приложения SMTP: ' SMTP_PASSWORD && printf '\n'
kubectl -n monitoring create secret generic alertmanager-smtp \
  --from-literal=smtp-password="${SMTP_PASSWORD}"
unset SMTP_PASSWORD
export ALERT_EMAIL_TO='alerts@<ваш-домен>'          # ящик человека для page|critical
export ALERT_EMAIL_FROM='alertmanager@<ваш-домен>'  # обычно = логин SMTP
export SMTP_SMARTHOST='smtp.yandex.ru:465'
export SMTP_USERNAME='alertmanager@<ваш-домен>'
./scripts/deploy.sh
```

`authPassword` в конфиге — ссылка на Secret `alertmanager-smtp`. Без него оператор не
соберёт конфиг Alertmanager: правка маршрута не применится, а снаружи всё выглядит
здоровым — старый конфиг продолжает работать. Поэтому `scripts/deploy.sh` проверяет
Secret до apply и падает с готовой командой создания.

Деплой без четырёх e-mail переменных **останавливается**, если в кластере уже стоят
живые адреса: `apply` декларативен, и плейсхолдеры `example.invalid` молча заменили бы
рабочий маршрут. Осознанный переход на плейсхолдеры (например, при сносе ветки) —
только явно: `ALERT_EMAIL_ALLOW_PLACEHOLDER=1 ./scripts/deploy.sh`.

**Пароль в сгенерированном конфиге лежит открытым текстом.** Оператор не монтирует
Secret файлом, а подставляет значение в `alertmanager-monitoring-kube-prometheus-alertmanager-generated`
(поле `auth_password`). В манифесте и в git пароля нет, но при просмотре конфига он
виден — маскируйте вывод (`sed -E 's/auth_password:.*/auth_password: <скрыт>/'`) и не
копируйте его в тикеты, чаты и логи CI. Утечка = смена пароля приложения у провайдера,
пересоздание Secret и `deploy.sh`.

Адреса подставляет оверлей при рендере (`scripts/lib.sh`: JSON6902-патч
`/spec/receivers/1/emailConfigs/0/{to,from,smarthost,authUsername}`), в git лежат
плейсхолдеры `example.invalid`. `SMTP_SMARTHOST` валидируется как `host:port`.
Порт 465 (implicit TLS) и 587 (STARTTLS) поддержаны клиентом Alertmanager; живьём
проверен только 587 — для 465 нет подтверждения на этом стенде.

**Проверка:**

```bash
# 1) маршрут и адреса так, как их видит Alertmanager (это же проверяет гейт deploy.sh:
#    метрика reload в одиночку ничего не доказывает — она остаётся 1 от прошлого reload)
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-alertmanager 9093:9093 &
curl -s http://127.0.0.1:9093/api/v2/status \
  | jq -r '.config.original' | sed -E 's/(auth_password:).*/\1 <скрыт>/' | grep -A4 '/email'
# 2) метрика reload — второй признак
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 &
curl -sG http://127.0.0.1:9090/api/v1/query --data-urlencode \
  'query=alertmanager_config_last_reload_successful{job="monitoring-kube-prometheus-alertmanager"}'
# 3) проба: page уходит письмом, ticket — в /timeline (sink: port-forward 8080)
curl -s -XPOST http://127.0.0.1:9093/api/v2/alerts -H 'Content-Type: application/json' \
  -d '[{"labels":{"alertname":"EmailProbe","severity":"page","service":"demo-api"},
       "annotations":{"summary":"проверка доставки почты"}}]'
# 4) ошибки интеграции e-mail — должно быть 0
curl -sG http://127.0.0.1:9090/api/v1/query --data-urlencode \
  'query=increase(alertmanager_notifications_failed_total{integration="email"}[15m])'
```

Проба `page` должна появиться и в `/timeline` (catch-all + `continue`), и в ящике —
проверять оба места: письмо может уйти в «Спам». Снять пробу нельзя: у `/api/v2/alerts`
нет метода удаления (`DELETE` отвечает 405). Проба без `endsAt` живёт до `resolve_timeout`
(5m) и остаётся `active` в API, пока Alertmanager не пересчитает её статус (обновление
алерта или сборка мусора), — **`resolved`-ветку (`sendResolved`) такой пробой проверить
нельзя**, её показывает дрилл `run.sh errors` (page-алерт закрывается сам).

**Типовые причины «письма не приходят»:**

| Симптом | Причина | Что делать |
|---|---|---|
| `notifications_failed_total{integration="email"}` растёт, в логе `auth` | неверный пароль приложения или `SMTP_USERNAME` ≠ логин | пересоздать Secret и повторить `deploy.sh` |
| `'require_tls' is true ... does not advertise the STARTTLS extension` | провайдеру нужен 465 (implicit TLS), а не 587 | `SMTP_SMARTHOST=smtp.<провайдер>:465` |
| `connection refused` / `i/o timeout` | закрыт egress 465/587 со стенда | `nc -z <host> 465`; это ограничение стенда, а не конфига |
| ошибок нет, письма нет | письмо в «Спаме» или `from` не совпадает с логином (провайдер отбрасывает молча) | проверить ящик, выставить `ALERT_EMAIL_FROM` = логин SMTP |
| горит `AlertmanagerFailedReload` | конфиг не загрузился, чаще всего из-за отсутствующего Secret | `kubectl -n monitoring logs sts/alertmanager-monitoring-kube-prometheus-alertmanager`, `/api/v2/status` |

**Откат:** `git revert` коммита с маршрутом → `kubectl apply -k deploy/monitoring`
(или `./scripts/deploy.sh`), затем `kubectl -n monitoring delete secret alertmanager-smtp`.
После отката маршрут снова один (`всё → alert-sink`): письма перестают приходить,
доставка в приёмник не страдает.

### Дриллы: прерванный прогон

`Ctrl-C`/`SIGTERM` во время дрилла не оставляет evidence `passed`: `drills/lib.sh`
ловит сигнал, помечает прогон прерванным и пишет `result: "failed"` (что снимать
вручную — по транскрипту `evidence/<дрилл>.console.log`). Если прогон убили
`SIGKILL` (или пропал хост), cleanup не выполнится вообще, и стенд остаётся в
инъецированном состоянии. Для дрилла `readiness` это означает сломанную пробу и
нулевое число реплик:

```bash
kubectl -n demo get deploy demo-api -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}'
# если не /ready — вернуть:
kubectl -n demo patch deploy demo-api --type=json -p \
  '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/ready"}]'
kubectl -n demo scale deploy demo-api --replicas=2
kubectl -n demo get endpointslices -l kubernetes.io/service-name=demo-api \
  -o json | jq '[.items[].endpoints[]? | select(.conditions.ready)] | length'   # 2
```

Для остальных дриллов: `latency`/`errors` — снять токсин
(`DELETE /proxies/demo-api/toxics/<имя>`), `oomkill` — ничего не остаётся.

## 5. Если кластер недоступен

Симптом: `die "кластер не отвечает"` или `kubectl` висит на `get nodes`. Кластер живёт в
лабе (две VM), и его состояние — состояние лабы, а не ошибка скриптов.

1. Проверь `kubectl get nodes --request-timeout=10s` с `KUBECONFIG` из лабы.
2. Если пусто/таймаут — VM лабы, скорее всего, остановлены: их старт — действие владельца
   стенда, а не часть этого проекта.
3. После старта ничего пересобирать не нужно: образы в containerd сохраняются между
   перезапусками, `deploy.sh` идемпотентен.

## 6. Частые сбои

| Симптом | Причина | Что делать |
|---|---|---|
| под в `ImagePullBackOff` | образ не импортирован на эту ноду | `./scripts/import-image.sh` (проверяет обе ноды) |
| `up{job="demo-api"}` пусто | у ServiceMonitor нет метки `release: monitoring` или селектор не совпал с меткой Service | `kubectl -n demo get servicemonitor -o yaml`, сверить `selector.matchLabels` |
| дашборда нет в Grafana | нет метки `grafana_dashboard=1` или sidecar не видит namespace | `kubectl -n monitoring get cm demo-red slo-demo --show-labels`, логи контейнера `grafana-sc-dashboard` |
| нет серий `slo:*` | `PrometheusRule` без метки `release=monitoring`, группа падает или оператор не перезагрузил правила | `kubectl -n monitoring get prometheusrule \| grep demo-`, `curl … /api/v1/rules` и поле `lastError` группы |
| в `/timeline` пусто | маршрут не подхвачен: `AlertmanagerConfig` не создан или не в `monitoring`, `matcherStrategy` не `None`, sink в `CrashLoop` | `kubectl -n monitoring get alertmanagerconfig`, сгенерированный конфиг (шаг 4), `kubectl -n demo logs deploy/alert-sink` |
| `demo-load` считает `outcome="error"` | toxiproxy недоступен или прокси выключен | `kubectl -n demo port-forward svc/toxiproxy 8474:8474`, затем `GET /proxies` |
| под demo-api бесконечно рестартует | падает проба или не хватает лимитов | `kubectl -n demo describe pod`, `kubectl -n demo logs <pod> --previous` |
| `kubectl top` пусто | нет metrics-server | для headroom смотреть `kubectl describe node` (Allocated resources) |
| `loki-0` или `alloy` в `ImagePullBackOff` | нода не скачала образ из docker.io (таймаут CloudFront) | `IMPORT_IMAGES="<образ>" ./scripts/import-image.sh`: tar кладётся на ноду и импортируется локально |
| `loki-0` `Pending` с пустым PVC | `local-path` провижинит том только после планирования пода | `kubectl -n monitoring describe pvc storage-loki-0` — событие `WaitForFirstConsumer`; если `Provisioning` нет, смотреть под `local-path-provisioner` в `kube-system` |
| в Alloy `entry too far behind, dropping data` | новый tailer перечитывает логи контейнера с начала, Loki отбрасывает записи старше уже принятых | это шум после рестарта Alloy, дублей в Loki нет; позиции и так лежат в `emptyDir /tmp/alloy`, поэтому томом это не лечится — источник шума снимается отбрасыванием старых строк на стороне Alloy (`stage.drop`, фаза 6 плана v1.1) |
| дашборда/панели логов нет в Grafana | datasource `loki` не подхвачен sidecar | `kubectl -n monitoring logs deploy/monitoring-grafana -c grafana-sc-datasources \| tail`, `GET /api/datasources` — должен быть `loki` |
| Loki отвечает 400 на push | `limits_config` (например, отбрасывание старых записей) или `schemaConfig` не совпадает с хранилищем | `kubectl -n monitoring port-forward svc/loki 3100:3100`, затем `GET /config`, логи `loki-0` |
| Grafana `Init:ImagePullBackOff` на `init-chown-data` | чарт добавил init-контейнер `busybox:1.38.0` (chown PVC), а в registry лабы его нет | `IMPORT_IMAGES="busybox:1.38.0" ./scripts/import-image.sh` |
| Grafana в `CrashLoopBackOff` после включения PVC, в логах `permission denied` на `/var/lib/grafana` | init-контейнер не отработал или том принадлежит другому UID | `kubectl -n monitoring logs <pod> -c init-chown-data`, `ls -ln` каталога PV на ноде: владелец должен быть `472:472` |
| горит `LokiTargetMissing` / `AlloyTargetMissing` | цели нет: удалён объект, выключен `ServiceMonitor`, у Service нет эндпоинтов | `kubectl -n monitoring get servicemonitor loki alloy`, `get endpoints loki alloy`, `get sts loki`/`get ds alloy` |
| горит `LokiDown` / `AlloyDown` | цель есть, но `/metrics` не отвечает: зависший процесс, лимит памяти, ошибка контейнера | `kubectl -n monitoring logs <pod> --tail=50`, `describe pod`, `kubectl top pod` |
| горит `AlloyDroppedLogs` | Alloy выбрасывает записи: `queue_is_full` (Loki не успевает), `rate_limited`, `ingester_error` | `kubectl -n monitoring logs ds/alloy`, метрика по `reason`, проверить `LokiNotIngesting` и PVC Loki |
| горит `LokiNotIngesting` | строки не доходят до Loki при живом процессе: сломан Alloy, RBAC, сеть или в namespace просто тихо | `kubectl -n monitoring logs ds/alloy --tail=50`, запрос `{namespace="demo"}` в Grafana, `up{job="alloy"}` |

## 7. Реакция на алерты

Раздел — про то, что делать, когда уведомление уже пришло. Как устроен маршрут и где
смотреть доставку — раздел «Маршрут уведомлений», правила — `rules/*.yaml`.

**Что означает `severity`:**

| Метка | Кто ставит | Смысл | Куда идёт (v1.1) |
|---|---|---|---|
| `page` | наш проект (`rules/demo-slo-alerts.yaml`, `rules/meta.yaml`) | пользователь страдает или вот-вот начнёт: горит бюджет ошибок/латентности, сторожа правил молчат | e-mail |
| `critical` | чарт kube-prometheus-stack | отказ компонента стека (например, `AlertmanagerFailedReload`) | e-mail |
| `ticket` | наш проект (`rules/demo-slo-alerts.yaml`, `rules/infra.yaml`, `rules/pipeline.yaml`) | разберут в рабочее время: медленный burn, инфраструктура, пайплайн логов | `alert-sink` (`/timeline`) |
| `info` | наш проект (`rules/pipeline.yaml`, `rules/meta.yaml`) | дефект мониторинга, а не отказ сервиса: телеметрия неполная, но пользователь жив | `alert-sink` |
| `warning` | чарт | ресурсы/состояние кластера, требует внимания, не срочно | `alert-sink` |
| `none` | чарт (`Watchdog`) | «доставка работает»: всегда firing | `alert-sink` |

Последняя колонка — действующий маршрут (`deploy/monitoring/alertmanagerconfig.yaml`:
ветка `alertname=~"AlertSink.*"` → `email` с `continue: true`, ветка `page|critical` →
`email`, остальное → `alert-sink`, плюс catch-all в sink). Исключение из таблицы —
алерты пути уведомлений: они `ticket`, но идут и в почту, и в sink.
Оговорка одна: письма уходят только если окружение задало адреса и SMTP при деплое
(`ALERT_EMAIL_TO`/`ALERT_EMAIL_FROM`/`SMTP_SMARTHOST`/`SMTP_USERNAME`), иначе в
маршруте стоят плейсхолдеры `example.invalid` — проверка и диагностика в подразделе
«E-mail (SMTP)» выше.

**Порядок разбора** (сначала факт, потом причина — иначе легко чинить не то):

1. **Открыть алерт в Prometheus UI** (`prometheus.lab.internal`) → вкладка Alerts: с какого
   времени `activeAt`, какие метки, какой `for`. Если алерт `inactive` — это был resolved
   или устаревшее уведомление.
2. **Дашборд** `demo-slo` — какой SLO и какое окно горит (fast 14,4x — отказ идёт прямо
   сейчас; medium 6x / slow 1x — деградация накопленная). `demo-red` — что видят клиенты:
   RPS, доля ошибок, p95.
3. **Логи** в Grafana (datasource `loki`, запрос `{namespace="demo", app="demo-api"} | json`,
   фильтр по `status >= 500` или по `request_id` из уведомления) — отвечают на «почему», но
   не на «насколько плохо»: счётчики потерь сети до клиента видны только в метриках.
4. **Не инъекция ли это** — дрилл или чужая правка стенда: `kubectl -n demo get pods`,
   токсины toxiproxy (`GET /proxies`), `kubectl -n demo get deploy demo-api -o yaml`.
5. **Действие** — по классу из таблицы `severity` выше и по ссылке `runbook_url` в самом
   уведомлении (если она заполнена).

### SLO доступности: burn rate fast, medium и slow

Три алерта по SLO доступности `demo-api` (99 %): `SloDemoAvailabilityBurnFast`,
`SloDemoAvailabilityBurnMedium`, `SloDemoAvailabilityBurnSlow`
(`rules/demo-slo-alerts.yaml`, группа `demo-slo.alerts.availability`). Считаются по
записанным сериям `slo:demo_availability:burn_rate_*`, а те — по клиентским исходам
`demo-load` (`outcome="ok"`): «доступность» здесь означает «клиент получил ответ», и
сетевой обрыв на пути `demo-load → toxiproxy → demo-api` виден так же, как 500 от
приложения.

| Алерт | Условие | Смысл | `severity` |
|---|---|---|---|
| Fast | burn 14,4x одновременно в 5m и 1h, `for: 2m` | отказ идёт прямо сейчас: за час такого темпа уходит ~20 % трёхдневного бюджета | page |
| Medium | burn 6x в 30m и 6h, `for: 15m` | устойчивая деградация: за 6 часов уходит ~50 % бюджета | ticket |
| Slow | burn 1x за 3d, `for: 1h` | бюджет сгорает к концу окна SLO без резкого всплеска | ticket |

Что смотреть и в каком порядке:

1. `demo-slo` — какой бюджет и какое окно горит: остаток бюджета, `burn_rate_*` по
   окнам, текущий SLI за 3 дня.
2. `demo-red` — что видят клиенты: RPS, доля ошибок (`клиент/сервер`), p95. Панель
   «Логи (Loki)» того же дашборда отвечает на «почему» (статусы, `request_id`), но не
   на «насколько плохо»: доля потерь на пути до клиента есть только в метриках.
3. `kubectl -n demo get pods -o wide` и `kubectl -n demo port-forward svc/toxiproxy
   8474:8474` → `GET /proxies`: toxiproxy включён/задержан, под `demo-api` не
   `Ready`, реплик меньше двух. Отдельно проверь, не идёт ли дрилл (`evidence/`).
4. Если инъекции нет — смотри `kubectl -n demo logs deploy/demo-api --tail=100` и
   `kubectl -n demo describe pod`: падение подов, OOM, сломанная проба.

Fast требует реакции в минутах: сначала восстанови путь (снять токсин, вернуть
реплики), потом разбирайся в причине — бюджет уже тратится. Medium и Slow — тикет:
разбор плановый, но с записью, какой маршрут/клиент съедает бюджет (у `demo-api`
маршруты заданы меткой `route` в `http_requests_total`). Сценарии инъекций —
`docs/drills.md` (`errors`, `readiness`).

### SLO латентности: burn rate fast, medium и slow

Три алерта по SLO латентности `demo-api` (95 % запросов ≤ 300 мс):
`SloDemoLatencyBurnFast|Medium|Slow` (`rules/demo-slo-alerts.yaml`, группа
`demo-slo.alerts.latency`). Метрика — клиентская гистограмма
`load_request_duration_seconds` с бакетом `0.3`, то есть задержка, которую видит
потребитель, включая путь через toxiproxy.

| Алерт | Условие | Смысл | `severity` |
|---|---|---|---|
| Fast | 14,4x в 5m и **30m**, `for: 2m` | медленных запросов столько, что за полчаса уходит ~10 % бюджета | page |
| Medium | 6x в 30m и 6h, `for: 15m` | за 6 часов уходит ~50 % бюджета | ticket |
| Slow | 1x за 3d, `for: 1h` | бюджет 5 % сгорает к концу окна SLO | ticket |

Почему у fast длинное окно 30m, а не 1h: при пороге 14,4x и бюджете 5 % условие с
окном 1h выполняется только на 43-й минуте полного замедления. Разбор — в комментарии
к `rules/demo-slo-alerts.yaml`.

Порядок разбора тот же, что у доступности, с поправкой на предмет:

1. `demo-slo` — доля запросов ≤ 300 мс и burn rate по окнам `5m`/`30m`/`6h`/`3d`.
2. `demo-red` — p95 по обеим гистограммам: если медленно только на клиенте, дело в
   пути (`toxiproxy`), а не в приложении.
3. `GET /proxies` у toxiproxy — включён ли токсин `latency` (дрилл `latency` добавляет
   задержку на прокси, а не в коде).
4. Если путь чист — ищи медленные маршруты: `histogram_quantile(0.95,
   sum by (route) (rate(http_request_duration_seconds_bucket[5m])))` и логи с большим
   `duration_ms`.

Латентностный бюджет уже потрачен к моменту page: чинить «прямо сейчас» — снять
задержку/перезапустить под, а не оптимизировать код.

### Инфраструктурные алерты

Три собственных правила (`rules/infra.yaml`), остальная инфраструктура — от чарта
kube-prometheus-stack.

- `KubePodOOMKilled` (ticket) — `kube_pod_container_status_last_terminated_reason
  {reason="OOMKilled"} == 1`: последнее завершение контейнера — OOM.
  `kubectl -n <ns> describe pod <pod>` → `Last State: Terminated, Reason: OOMKilled`,
  `kubectl -n <ns> get deploy <deploy> -o jsonpath='{.spec.template.spec.containers[*].resources}'`
  — сравнить `limits.memory` с рабочим набором. Метрика KSM отражает **последнее**
  завершение, поэтому алерт висит и после восстановления, пока контейнер не
  завершится по другой причине: смотри время последнего рестарта, а не только факт.
  На стенде это же состояние даёт дрилл `oomkill` (`docs/drills.md`).
- `PVCNearlyFull` (ticket) — `kubelet_volume_stats_used_bytes / capacity > 0.85`
  дольше 15 минут. `kubectl -n monitoring get pvc` → какой том,
  `kubectl -n monitoring describe pvc <имя>` → событие и нода. У `local-path`
  расширение существующего тома не работает: либо чистка (retention, старые
  WAL/блоки), либо новый PVC. Для тома Prometheus рост обычно даёт кардинальность
  метрик, для Loki — срок хранения логов.
- `NodeMemoryAvailableLow` (ticket) — `node_memory_MemAvailable_bytes / MemTotal < 0.15`
  дольше 10 минут. `kubectl describe node <нода>` → секция `Allocated resources`
  (`kubectl top` пуст: metrics-server не ставится). Это граница headroom:
  следующая раскатка может упереться в память. Более поздний случай (<10 %) ловит
  правило чарта `NodeMemoryHighUtilization`.

### Сторожа правил и SLO (meta)

Три сторожа в `rules/meta.yaml`, все про качество самого мониторинга, а не про
пользователя:

- `SloRulesAbsent` (page) — `absent(slo:demo_availability:ratio_5m)` или
  `absent(slo:demo_latency:ratio_5m)`. Записанных серий нет → burn-rate алерты по SLO
  молчат, и тишина выглядит как здоровый сервис. Проверь:
  `kubectl -n monitoring get prometheusrule | grep demo-` (метка `release=monitoring`),
  `curl -s http://127.0.0.1:9090/api/v1/rules | jq '.data.groups[] | select(.name|startswith("demo-")) | {name, lastError}'`,
  логи `config-reloader` в поде Prometheus.
- `SloAlertRulesAbsent` (page) — нет групп `demo-slo.alerts.availability` или
  `demo-slo.alerts.latency` в метрике `prometheus_rule_group_rules`: записанные `slo:*`
  живы, а страниц нет. Первый шаг — тот же `/api/v1/rules`; селектор по `rule_group`
  держится на формате `<путь>;<имя группы>` (проверено на стенде), поэтому ищи хвост
  `;demo-slo.alerts.availability`.
- `SloDemoNoTraffic` (info) — `demo-load` жив, но за 10 минут не отправил ни одного
  запроса — и так уже 15 минут (правило держит `for: 15m`); либо цель `demo-load`
  пропала из Prometheus совсем. Проверь под `demo-load`, его логи,
  `load_ticks_skipped_total` и конфиг toxiproxy: генератор мог остаться без цели.
  `info`, а не page: «нет трафика» — не отказ сервиса, а дефект фикстуры.

Подробности про выгрузку правил для `promtool` и про то, почему сторожей два, —
раздел «Правила Prometheus (фаза 3)».

### Пайплайн логов

Семь правил `rules/pipeline.yaml`: `LokiDown`, `LokiTargetMissing`,
`LokiNotIngesting`, `AlloyDown`, `AlloyTargetMissing`, `AlloyCoverageIncomplete`,
`AlloyDroppedLogs`. Ключевое различие: `*Down` — цель есть, но `/metrics` не отвечает
(`up == 0`); `*TargetMissing` — цели нет вовсе (`absent(up)`), то есть удалён
объект/`ServiceMonitor` или у Service нет эндпоинтов.

- `LokiDown`/`LokiTargetMissing` (ticket): `kubectl -n monitoring get sts loki`,
  `get endpoints loki`, `kubectl -n monitoring logs loki-0 --tail=100`,
  `port-forward svc/loki 3100:3100` → `/ready`, `/config`. Пока Loki стоит, Grafana не
  читает логи, а Alloy копит ошибки push.
- `AlloyDown`/`AlloyTargetMissing` (ticket): `kubectl -n monitoring get ds alloy`,
  `get pods -l app.kubernetes.io/name=alloy -o wide`, логи контейнера `alloy`.
  Выпавшая реплика = логи этой ноды не собираются.
- `AlloyCoverageIncomplete` (ticket): живых реплик меньше, чем нод. Причины — под не
  встал (ресурсы, taint), реплика не скрейпится, DaemonSet урезан `nodeSelector`.
- `AlloyDroppedLogs` (ticket): `loki_write_dropped_entries_total` растёт. Причина в
  метке `reason` (`queue_is_full` — Loki не успевает, `rate_limited`, `ingester_error`).
  Это потеря, а не задержка: `sum by (reason) (rate(loki_write_dropped_entries_total[10m]))`.
- `LokiNotIngesting` (info): distributor 15 минут не принимал строк, и так уже 30
  минут при живом процессе. Смотри Alloy, push-URL `loki.monitoring.svc:3100` и фильтр
  `__meta_kubernetes_pod_node_name`; возможно, в `demo`/`monitoring` просто тихо.

Как читать логи и метрики — разделы «Логи: Loki и Alloy» и «Метрики Loki и Alloy».

### Правило по логам (Loki ruler)

`DemoApi5xxFromLogs` (`deploy/loki-rules/demo-api-5xx.yaml`, `severity: ticket`) —
единственный алерт проекта, который считается **по логам, а не по метрикам**: ruler
внутри Loki видит строки `http_request` со `status >= 500` за 5 минут и держит
`for: 2m`. Он дополняет SLO-алерты, а не заменяет их.

- Сработал → `kubectl -n demo logs deploy/demo-api --tail=100` (или Grafana →
  Explore → `{namespace="demo", app="demo-api"} | json | status >= 500`): в строках
  есть `status`, `route`, `request_id`. Дальше — раздел 7 по классу причины
  (ошибки, латентность, ресурсы).
- **Логи и метрики расходятся намеренно.** Метрика доступности считает ответы
  сервера в окне 3 дней и не различает причин; лог видит `499` и `request_aborted`
  (обрыв клиента) как отдельное событие, но **не видит** сетевой обрыв до приложения
  — при разрыве через toxiproxy запрос до `demo-api` не доходит и строки в логе не
  появляется. Поэтому «метрика красная, лог молчит» — нормальный случай: смотри
  `load_requests_total{outcome="timeout"}` и сам toxiproxy.
- «Лог горит, метрика спокойна» — тоже возможен: 5xx в коротком окне 5 м при
  долгом окне SLO ещё не выедает бюджет. Это ранний сигнал, а не дубль page-алерта,
  поэтому `ticket`.
- Правило не горит → сначала проверь, что ruler жив: `/prometheus/api/v1/rules` на
  порту 3100 (раздел «Правила Loki ruler»), затем что логи вообще доезжают
  (`LokiNotIngesting`, `AlloyDroppedLogs` из «Пайплайн логов»).

### Путь уведомлений

**Статус: реализовано** (Phase 4 плана v1.1). Все три правила живут в
`rules/notifications.yaml` и ссылаются на этот подраздел через `runbook_url`; у чарта
сигнала о полном молчании маршрута нет.

Три правила `rules/notifications.yaml` (группа `demo-alerting-path.heartbeat`) сторожат
сам путь «Alertmanager → sink», потому что правила чарта
(`AlertmanagerFailedToSendAlerts`, `AlertmanagerClusterFailedToSendAlerts`) видят
только ошибки отправки, а не полное молчание маршрута:

- `AlertSinkHeartbeatMissing` — `alertsink_last_notification_timestamp_seconds` старше
  5,5 ч при живом sink. Порог выведен из `repeatInterval: 4h`: `Watchdog` (всегда
  firing) обязан приходить не реже, чем раз в 4 часа, и 5,5 ч тишины — это уже
  поломка, а не «ночью никто не алертил».
- `AlertSinkNeverReceived` — sink живёт дольше 5,5 ч, но
  `alertsink_last_notification_timestamp_seconds == 0`: не пришло ни одного
  уведомления, включая `Watchdog`. Значит, сломан маршрут/конфиг Alertmanager,
  а не доставка конкретного алерта.
- `AlertSinkTargetMissing` — серии `up{job="alert-sink"}` нет вовсе (`absent()`):
  удалён `ServiceMonitor` или `Service`, либо sink снят в 0 реплик. Первые два правила
  в этом случае молчат — им нужна серия, — а `TargetDown` чарта тоже не горит: он ждёт
  `up == 0`, а не отсутствие цели.

Порядок разбора:

1. `curl -s http://127.0.0.1:8080/metrics` (port-forward `svc/alert-sink`) —
   `alertsink_last_notification_timestamp_seconds`, `alertsink_process_start_time_seconds`.
2. `/timeline` — пусто или старые записи? Пусто при живом sink → маршрут.
3. `kubectl -n monitoring get alertmanagerconfig`, затем сгенерированный конфиг:
   `kubectl -n monitoring get secret alertmanager-monitoring-kube-prometheus-alertmanager-generated -o jsonpath='{.data.alertmanager\.yaml\.gz}' | base64 -d | gunzip | grep -A3 webhook_configs`
   — маршрут на месте? В действующем конфиге это дерево: ветка `AlertSink.*` → `email`,
   ветка `email` по `page|critical` (обе с `continue: true`), ветка `alert-sink` по
   `severity` и catch-all без матчеров.
4. `alertmanager_config_last_reload_successful{job="monitoring-kube-prometheus-alertmanager"}`
   и лог Alertmanager: при неудачном reload новый конфиг **не применяется**, продолжает
   работать предыдущий — поэтому доставка «как раньше» не означает «конфиг верный».
   Сам факт неудачи пишет `AlertmanagerFailedReload` (critical → e-mail); ошибка на старте
   пода (битый или неполный конфиг) уже роняет Alertmanager целиком.
5. Состояние самого sink: `up{job="alert-sink"}`, `kubectl -n demo logs deploy/alert-sink`,
   `kubectl -n demo get servicemonitor alert-sink -o yaml` (метка `release=monitoring`).

Устройство маршрута и проверка доставки — раздел «Маршрут уведомлений и alert-sink».

**Куда уходят эти алерты.** Имя каждого правила начинается с `AlertSink`, и в дереве
маршрутов для `alertname=~"AlertSink.*"` есть отдельная первая ветка → `email` с
`continue: true`. Без неё `severity: ticket` уводил бы сигнал «маршрут до sink сломан»
только в сломанный sink, и почта молчала бы вместе с путём. При переименовании правил
ветку маршрута нужно править вместе с ними — это проверяет `scripts/check.sh`.

**Ограничение, которое стоит знать:** пока `alertsink_last_notification_timestamp_seconds`
равен 0 (сразу после рестарта пода), `AlertSinkHeartbeatMissing` слепо, а
`AlertSinkNeverReceived` нужен аптайм 5,5 ч — sink, который рестартуют чаще, чем раз в
5,5 ч, при сломанном маршруте не репортится. Второе: правила опираются на `Watchdog` от
чарта; если его выключат или уведут в другой маршрут, `AlertSinkNeverReceived` начнёт
ложно гореть через 5,5 ч аптайма.

**Гигиена:** силенсы создаются **в UI Alertmanager** (`alertmanager.lab.internal`), не в
Prometheus: кнопка «Silence» в UI Prometheus ведёт на pod IP, который из браузера не
открывается. Силенс должен сопровождаться записью, почему и до какого времени; «заглушить
навсегда» — способ потерять настоящий отказ.

Аутентификации у UI нет — это ограничение лабы, а не настройка по умолчанию для
продакшена.
