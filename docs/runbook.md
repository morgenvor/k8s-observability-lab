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

  Ожидается 9 групп (две `demo-slo`, две `demo-slo-alerts`, две `demo-infra`,
  `demo-meta.pipeline`, две `demo-logs-pipeline`). Если правило горит — группа
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
kubectl apply -k deploy/monitoring   # полный путь — ./scripts/deploy.sh
# что реально уехало в Alertmanager: сгенерированный конфиг лежит .gz внутри секрета
kubectl -n monitoring get secret alertmanager-monitoring-kube-prometheus-alertmanager-generated \
  -o jsonpath='{.data.alertmanager\.yaml\.gz}' | base64 -d | gunzip | grep -A3 webhook_configs
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
- Маршрут ловит все алерты без матчеров, поэтому в sink приходит и шум чарта
  (`KubeControllerManagerDown`, `KubeSchedulerDown`, `KubeProxyDown` — k3s не отдаёт эти
  цели) и `SloDemoAvailabilityBurnSlow`. Это не поломка маршрута, а состояние стенда.

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

| Метка | Кто ставит | Смысл | Куда идёт |
|---|---|---|---|
| `page` | наш проект (`rules/demo-slo-alerts.yaml`, `rules/meta.yaml`) | пользователь страдает или вот-вот начнёт: горит бюджет ошибок/латентности, сторожа правил молчат | e-mail |
| `critical` | чарт kube-prometheus-stack | отказ компонента стека (например, `AlertmanagerFailedReload`) | e-mail |
| `ticket` | наш проект (`rules/demo-slo-alerts.yaml`, `rules/infra.yaml`, `rules/pipeline.yaml`) | разберут в рабочее время: медленный burn, инфраструктура, пайплайн логов | `alert-sink` (`/timeline`) |
| `info` | наш проект (`rules/pipeline.yaml`) | дефект мониторинга, а не отказ сервиса: телеметрия неполная, но пользователь жив | `alert-sink` |
| `warning` | чарт | ресурсы/состояние кластера, требует внимания, не срочно | `alert-sink` |
| `none` | чарт (`Watchdog`) | «доставка работает»: всегда firing | `alert-sink` |

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

**Гигиена:** силенсы создаются **в UI Alertmanager** (`alertmanager.lab.internal`), не в
Prometheus: кнопка «Silence» в UI Prometheus ведёт на pod IP, который из браузера не
открывается. Силенс должен сопровождаться записью, почему и до какого времени; «заглушить
навсегда» — способ потерять настоящий отказ.

Аутентификации у UI нет — это ограничение лабы, а не настройка по умолчанию для
продакшена.
