# Runbook — k8s-observability-lab

Процедуры для лабы: как поставить инструменты, доставить демо-контур в k3s и что делать,
если что-то не отвечает. Правила и архитектура — в `AGENTS.md`, история — в `CHANGELOG.md`.

Агент работает вне кластера: kubeconfig и SSH-ключи лабы живут в `../proxmox-lab/.secrets/`
и в репозиторий не попадают. Скрипты берут их из env:

| Переменная | Назначение | Значение по умолчанию |
|---|---|---|
| `KUBECONFIG` | доступ к кластеру k3s | `<проект>/../proxmox-lab/.secrets/kubeconfig-phase5b` |
| `LAB_SSH_CONFIG` | SSH к нодам для импорта образов | `<проект>/../proxmox-lab/.secrets/ssh_config` |
| `IMAGE_TAG` | тег образов | короткий git SHA |
| `WAIT_TARGETS` | сколько секунд `deploy.sh` ждёт цели в Prometheus | `180` |

## 1. Инструменты (один раз на машине и в CI)

```bash
./scripts/bootstrap-tools.sh
```

Кладёт `helm`, `helmfile`, `kubectl`, `kubeconform`, `promtool` и плагин `helm-diff` в
`.tools/` (вне git), версии пиннуются в скрипте. Повторный запуск идемпотентен.
Офлайн-проверки проекта — одна команда:

```bash
./scripts/check.sh            # без сборки образов
./scripts/check.sh --images   # плюс docker build обоих приложений
```

## 2. Сборка и импорт образов

Registry в лабе нет: образы собираются локально и импортируются в containerd обеих нод.

```bash
./scripts/build-image.sh     # печатает теги вида demo-api:<sha>, demo-load:<sha>
./scripts/import-image.sh    # docker save | ssh 'sudo k3s ctr images import -' на каждую ноду
```

Почему на обе ноды: поды раскидываются по нодам планировщиком, и импорт только на одной
даёт `ImagePullBackOff` на второй. `import-image.sh` берёт список нод у самого кластера
(`kubectl get nodes`) и после импорта проверяет тег через `k3s ctr images ls`.

Тег = короткий git SHA: пересборка того же коммита перезаписывает тот же тег, поэтому
после правки кода сделай новый коммит (или задай `IMAGE_TAG`) и повтори импорт.

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

Правка `toxiproxy.json` (или другого ConfigMap) применяется только после перезапуска
подов — хеш конфига в имени ConfigMap не участвует:

```bash
kubectl -n demo rollout restart deploy/toxiproxy
```

Применять корневой `kustomization.yaml` напрямую (`kubectl apply -k .`) нельзя: в нём
заглушка `newTag: local`, поды уйдут в `ImagePullBackOff`. Штатный путь — `deploy.sh`.

Откат (удаляет namespace `demo` целиком и дашборд; образы в containerd остаются):

```bash
./scripts/rollback.sh        # спросит подтверждение
./scripts/rollback.sh --yes  # без вопроса
```

## 4. Где смотреть метрики и логи

```bash
# поды и их ноды
KUBECONFIG=../proxmox-lab/.secrets/kubeconfig-phase5b kubectl -n demo get pods -o wide
# цели в Prometheus (порт-форвард, т.к. сервис ClusterIP)
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090
#   в браузере: http://127.0.0.1:9090  → up{job=~"demo-.*"}
# Grafana
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80
```

- Дашборд `demo — RED и латентность` (uid `demo-red`): RPS, доля ошибок (клиент/сервер),
  p95 по обеим гистограммам, доля запросов ≤ 300 мс (latency SLO).
- Метрики приложения: `http_requests_total{method,route,status_class}`,
  `http_request_duration_seconds{method,route}` (бакеты с `0.3`), `http_inflight_requests`.
- Метрики нагрузки: `load_requests_total{outcome="ok|error|timeout"}`,
  `load_request_duration_seconds`.
- Логи приложений — stdout подов (`kubectl -n demo logs deploy/demo-api`), каждая строка
  JSON. Сбор в Loki — фаза 5 плана.

## 5. Если кластер недоступен

Симптом: `die "кластер не отвечает"` или `kubectl` висит на `get nodes`. Кластер живёт в
лабе (две VM), и его состояние — состояние лабы, а не ошибка скриптов.

1. Проверь `kubectl get nodes --request-timeout=10s` с `KUBECONFIG` из лабы.
2. Если пусто/таймаут — VM лабы, скорее всего, остановлены: их старт — действие владельца,
   см. `../proxmox-lab/AGENTS.md`.
3. После старта ничего пересобирать не нужно: образы в containerd сохраняются между
   перезапусками, `deploy.sh` идемпотентен.

## 6. Частые сбои

| Симптом | Причина | Что делать |
|---|---|---|
| под в `ImagePullBackOff` | образ не импортирован на эту ноду | `./scripts/import-image.sh` (проверяет обе ноды) |
| `up{job="demo-api"}` пусто | у ServiceMonitor нет метки `release: monitoring` или селектор не совпал с меткой Service | `kubectl -n demo get servicemonitor -o yaml`, сверить `selector.matchLabels` |
| дашборда нет в Grafana | нет метки `grafana_dashboard=1` или sidecar не видит namespace | `kubectl -n monitoring get cm demo-red --show-labels`, логи контейнера `grafana-sc-dashboard` |
| `demo-load` считает `outcome="error"` | toxiproxy недоступен или прокси выключен | `kubectl -n demo port-forward svc/toxiproxy 8474:8474`, затем `GET /proxies` |
| под demo-api бесконечно рестартует | падает проба или не хватает лимитов | `kubectl -n demo describe pod`, `kubectl -n demo logs <pod> --previous` |
| `kubectl top` пусто | нет metrics-server | для headroom смотреть `kubectl describe node` (Allocated resources) |