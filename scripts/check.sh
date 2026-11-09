#!/usr/bin/env bash
# Офлайн-ворота проекта: те же проверки, что в CI, без обращения к кластеру.
# Использование: ./scripts/check.sh [--images] [--strict]
#   --images  дополнительно собрать docker-образы приложений (медленнее)
#   --strict  провал при любом пропуске проверки (в CI: CHECK_STRICT=1)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WITH_IMAGES=0
STRICT="${CHECK_STRICT:-0}"
for arg in "$@"; do
  case "${arg}" in
    --images) WITH_IMAGES=1 ;;
    --strict) STRICT=1 ;;
    -h|--help)
      sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "неизвестный флаг: ${arg} (см. --help)" ;;
  esac
done

cd "${PROJECT_ROOT}"
require_tools helm helmfile kubectl kubeconform promtool alloy
mkdir -p "${PROJECT_ROOT}/.tmp/rendered"
# Ворота герметичны: экспортированные в шелле SMTP_SMARTHOST/адреса меняли бы рендер
# (а неверный формат хоста ронял бы прогон). Тестовые значения задаются явно в шагах.
unset ALERT_EMAIL_TO ALERT_EMAIL_FROM SMTP_SMARTHOST SMTP_USERNAME
# PyYAML нужен выгрузке правил в формате promtool и подсчёту групп: проверяем
# сразу, иначе шаг падал бы трейсбеком ModuleNotFoundError на середине прогона.
need_cmd python3
python3 -c 'import yaml' 2>/dev/null \
  || die "нет модуля PyYAML для выгрузки правил (python3 -m pip install pyyaml)"

STEP="подготовка"
step() { STEP="$*"; printf '\n==> %s\n' "${STEP}"; }
trap 'printf "\nCHECK FAILED: %s\n" "${STEP}" >&2' ERR

SKIPPED=()

# --- 1. yamllint (если установлен; в CI ставится отдельным шагом) -------------
step "yamllint"
if command -v yamllint >/dev/null 2>&1; then
  mapfile -t YAML_FILES < <(
    find . \
      -path ./.git -prune -o \
      -path ./.tools -prune -o \
      -path ./.tmp -prune -o \
      -path '*/node_modules' -prune -o \
      \( -name '*.yaml' -o -name '*.yml' \) -print | sort
  )
  if [ "${#YAML_FILES[@]}" -gt 0 ]; then
    yamllint -d '{extends: relaxed, rules: {line-length: {max: 120}}}' "${YAML_FILES[@]}"
    printf 'проверено файлов: %d\n' "${#YAML_FILES[@]}"
  else
    SKIPPED+=("yamllint (в дереве нет .yaml/.yml)")
  fi
else
  SKIPPED+=("yamllint (не установлен)")
fi

# --- 2. Тесты приложений (появляются с фазой 1) ------------------------------
shopt -s nullglob
for pkg in app/*/package.json; do
  app_dir="$(dirname "${pkg}")"
  step "npm ci + npm test: ${app_dir}"
  ( cd "${app_dir}" && npm ci --silent && npm test )
done
shopt -u nullglob

# --- 3. Сторонние чарты: helmfile template + kubeconform ---------------------
# Рендерим ВСЕ релизы helmfile.yaml одним файлом: релиз без своей строки в воротах
# (loki/alloy появились в фазе 5) проходил бы проверку «на слово». Список релизов
# берётся из самого helmfile, второй копии нет.
step "helmfile template (все релизы) -> kubeconform"
helmfile -f helmfile.yaml template > .tmp/rendered/helmfile.yaml
[ -s .tmp/rendered/helmfile.yaml ] || die "рендер helmfile пуст — проверь releases в helmfile.yaml"
kubeconform -strict -ignore-missing-schemas -summary -output text .tmp/rendered/helmfile.yaml

# --- 3a. Семантика значений Loki/Alloy: kubeconform видит только структуру ----
# Гарантии фазы 5 иначе держатся на ручном прогоне бинарей (правило 10), а смена
# ключа чартом или опечатка в values уехала бы в кластер молча.
step "семантика значений Loki/Alloy в рендере"
grep -q 'retention_period: 72h' .tmp/rendered/helmfile.yaml \
  || die "в рендере нет limits_config.retention_period: 72h (helm/values/loki.yaml)"
grep -q 'retention_enabled: true' .tmp/rendered/helmfile.yaml \
  || die "в рендере нет compactor.retention_enabled: true — retention не применяется"
grep -q 'delete_request_store: filesystem' .tmp/rendered/helmfile.yaml \
  || die "в рендере нет compactor.delete_request_store — Loki 3.x не стартует с retention"
# В конфиге Alloy это не YAML-пара, а `url = "…"`, поэтому проверяем сам адрес.
grep -q 'loki.monitoring.svc:3100/loki/api/v1/push' .tmp/rendered/helmfile.yaml \
  || die "в рендере нет loki.write на loki.monitoring.svc:3100 (helm/values/alloy.yaml)"
# Каждая реплика Alloy обязана читать только свою ноду, иначе логи собираются дважды.
grep -q '__meta_kubernetes_pod_node_name' .tmp/rendered/helmfile.yaml \
  || die "в конфиге Alloy нет фильтра по ноде — DaemonSet будет читать все поды каждой репликой"
# Выключенное в values не должно появиться в рендере.
for disabled in loki-canary chunks-cache results-cache; do
  if grep -q "${disabled}" .tmp/rendered/helmfile.yaml; then
    die "в рендере есть ${disabled}: соответствующее выключение в helm/values/loki.yaml перестало работать"
  fi
done
printf 'ассерты Loki/Alloy: ok\n'

# --- 3a2. Конфиг Alloy: фильтр старых строк и alloy validate ------------------
# Ассерты идут по РАСПАКОВАННОМУ конфигу, а не по рендеру чарта: в манифесте конфиг
# лежит блоком с отступом, и якорь `^loki.process` там не сработал бы. Ревью
# 2026-11-09 показало и вторую причину: grep по подстроке проходил на
# закомментированном блоке (`// loki.process "drop_old" {`), а конфиг при этом
# ссылается на несуществующий компонент — Alloy не стартует, сбор логов встаёт
# целиком, ворота зелёные. Поэтому после grep-ассертов идёт `alloy validate`
# (синтаксис, свойства, компоненты). Версия валидатора пинится в
# scripts/bootstrap-tools.sh и обязана совпадать с образом в кластере.
step "конфиг Alloy: фильтр старых строк и alloy validate"
ALLOY_RENDERED_CONFIG="${PROJECT_ROOT}/.tmp/rendered/alloy-config/main.alloy"
mkdir -p "$(dirname "${ALLOY_RENDERED_CONFIG}")"
python3 - "${ALLOY_RENDERED_CONFIG}" <<'PY'
import sys

import yaml

out_path = sys.argv[1]
docs = [
    d
    for d in yaml.safe_load_all(open(".tmp/rendered/helmfile.yaml", encoding="utf-8"))
    if isinstance(d, dict)
]
for doc in docs:
    if doc.get("kind") == "ConfigMap" and (doc.get("metadata") or {}).get("name") == "alloy":
        config = (doc.get("data") or {}).get("config.alloy")
        if not config:
            sys.exit("ConfigMap alloy: нет ключа config.alloy — чарт сменил раскладку ключей")
        with open(out_path, "w", encoding="utf-8") as handle:
            handle.write(config)
        print(f"конфиг Alloy выгружен: {len(config.splitlines())} строк")
        break
else:
    sys.exit("ConfigMap alloy: нет в рендере helmfile")
PY
# Без фильтра пересоздание пода Alloy возвращает шум "entry too far behind": Loki
# отвечает 400 на всё, что старше окна приёма. Проверяется и цепочка — источник
# обязан писать в drop_old, а drop_old в loki.write; иначе stage.drop окажется в
# графе, но не на пути данных.
grep -qE '^loki\.process "drop_old" \{' "${ALLOY_RENDERED_CONFIG}" \
  || die "в конфиге Alloy нет компонента loki.process drop_old (helm/values/alloy.yaml)"
# Порог меньше окна приёма Loki (cutoff = newest - max-chunk-age/2 = 1h при дефолтах):
# при равенстве батч с задержкой уходит за границу и всё равно получает 400.
grep -qE 'older_than[[:space:]]*=[[:space:]]*"50m"' "${ALLOY_RENDERED_CONFIG}" \
  || die "в stage.drop нет older_than = \"50m\" — либо старые строки доедут до Loki, либо пропал запас до окна приёма"
grep -q 'drop_counter_reason = "too_old"' "${ALLOY_RENDERED_CONFIG}" \
  || die "в stage.drop нет drop_counter_reason = \"too_old\" — счётчик потерь не отличить от прочих"
grep -q 'forward_to = \[loki.process.drop_old.receiver\]' "${ALLOY_RENDERED_CONFIG}" \
  || die "loki.source.kubernetes пишет мимо drop_old — фильтр старых строк не работает"
if ! grep -A2 -E '^loki\.process "drop_old" \{' "${ALLOY_RENDERED_CONFIG}" \
  | grep -q 'forward_to = \[loki.write.local.receiver\]'; then
  die "drop_old не передаёт данные в loki.write — логи перестали бы уходить в Loki"
fi
alloy validate "${ALLOY_RENDERED_CONFIG}"
printf 'конфиг Alloy: ассерты и alloy validate — ok\n'

# --- 3b. Метрики Loki/Alloy и хранилище Grafana в рендере ---------------------
# Правила rules/pipeline.yaml держатся на соглашении о метке job: у Loki шаблон
# чарта переписывает job в "monitoring/<service>", а у Alloy job = имя Service.
# Соглашение живёт в шаблонах чартов, а не в наших values, поэтому проверяется по
# рендеру: иначе обновление чарта молча отключило бы все алерты пайплайна логов
# (правило «правила есть, а цели не совпадают» — худший вид тишины).
step "метрики Loki/Alloy и PVC Grafana в рендере"
python3 - .tmp/rendered/helmfile.yaml rules/pipeline.yaml <<'PY'
import sys

import yaml

render_path, rules_path = sys.argv[1], sys.argv[2]
docs = [
    d
    for d in yaml.safe_load_all(open(render_path, encoding="utf-8"))
    if isinstance(d, dict)
]


def fail(message):
    sys.exit(message)


def find(kind, name):
    for doc in docs:
        if doc.get("kind") == kind and (doc.get("metadata") or {}).get("name") == name:
            return doc
    fail(f"{kind} {name}: нет в рендере helmfile (проверь values и версию чарта)")


for sm_name in ("loki", "alloy"):
    sm = find("ServiceMonitor", sm_name)
    labels = (sm.get("metadata") or {}).get("labels") or {}
    if labels.get("release") != "monitoring":
        fail(
            f"ServiceMonitor {sm_name}: нет метки release=monitoring — Prometheus"
            " (serviceMonitorSelector matchLabels) его не подхватит"
        )
    ports = [endpoint.get("port") for endpoint in sm["spec"]["endpoints"]]
    if "http-metrics" not in ports:
        fail(f"ServiceMonitor {sm_name}: ожидался порт http-metrics, в рендере {ports}")

# Loki: чарт сам переписывает job -> "monitoring/<service>". Если это правило
# исчезнет, up{job="monitoring/loki"} перестанет существовать, а правила начнут
# молчать (LokiDown/NotIngesting не увидят цель, TargetMissing — увидит).
loki_endpoint = find("ServiceMonitor", "loki")["spec"]["endpoints"][0]
job_relabel = [
    r
    for r in loki_endpoint.get("relabelings") or []
    if r.get("targetLabel") == "job"
]
if not job_relabel:
    fail(
        "ServiceMonitor loki: пропал relabeling job -> monitoring/<service>."
        ' Правила в rules/pipeline.yaml смотрят на job="monitoring/loki"'
    )
if not str(job_relabel[0].get("replacement", "")).startswith("monitoring/"):
    fail(
        "ServiceMonitor loki: relabeling job больше не даёт префикс monitoring/ —"
        " поправь правила rules/pipeline.yaml и этот ассерт"
    )

rules_text = open(rules_path, encoding="utf-8").read()
for selector in ('job="monitoring/loki"', 'job="alloy"'):
    if selector not in rules_text:
        fail(f"{rules_path}: нет {selector} — правила пайплайна логов разошлись с метками рендера")

# Grafana: /var/lib/grafana обязан быть на PVC. С emptyDir при каждом рестарте пода
# теряются user.timezone, starred-дашборды и прочее состояние из grafana.db —
# ровно то, что дашборды из ConfigMap не восстанавливают.
grafana = find("Deployment", "monitoring-grafana")
volumes = grafana["spec"]["template"]["spec"]["volumes"]
pvc_volumes = [v for v in volumes if "persistentVolumeClaim" in v]
if not pvc_volumes:
    fail(
        "Deployment monitoring-grafana: /var/lib/grafana снова на emptyDir — настройки"
        " пользователя (timezone, starred) не переживут рестарт"
    )
claim_name = pvc_volumes[0]["persistentVolumeClaim"]["claimName"]
claim = find("PersistentVolumeClaim", claim_name)
if not (claim.get("spec", {}).get("resources", {}).get("requests") or {}).get("storage"):
    fail(f"PVC {claim_name}: не задан размер — чарт не сможет создать claim")
# Loki: масштабирование в 0 не должно удалять том. Дефолт чарта whenScaled: Delete,
# и это уже стоило данных: дрилл 2026-11-07 удалил storage-loki-0 вместе с логами.
loki_sts = find("StatefulSet", "loki")
policy = loki_sts["spec"].get("persistentVolumeClaimRetentionPolicy") or {}
if policy.get("whenScaled") != "Retain":
    fail(
        "StatefulSet loki: whenScaled=%r, ожидался Retain — scale в 0 удалит PVC"
        % policy.get("whenScaled")
    )

strategy = (grafana["spec"].get("strategy") or {}).get("type")
if strategy != "Recreate":
    fail(
        f"Deployment monitoring-grafana: strategy={strategy}, ожидалась Recreate."
        " RWO-PVC на local-path при RollingUpdate даёт Multi-Attach на второй ноде и"
        " подвисший rollout"
    )
print("ассерты метрик пайплайна и PVC Grafana: ok")
PY

# --- 3c. Доступ к UI без port-forward: Ingress в рендере ---------------------
# Публикация UI держится на двух фактах, и оба живут в шаблонах чарта, а не в наших
# values: (1) Ingress-объекты с классом traefik и host'ами, (2) внешние URL в CR
# Prometheus/Alertmanager и `server.domain` у Grafana, которые чарт выводит из этих
# host'ов. Без (2) рабочая страница ссылается на внутренние имена кластера, поэтому
# проверяется не «Ingress есть», а согласованность пары.
step "доступ к UI (Ingress) в рендере"
python3 - .tmp/rendered/helmfile.yaml <<'PY'
import sys

import yaml

docs = [
    d
    for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8"))
    if isinstance(d, dict)
]


def fail(message):
    sys.exit(message)


def find(kind, name):
    for doc in docs:
        if doc.get("kind") == kind and (doc.get("metadata") or {}).get("name") == name:
            return doc
    fail(f"{kind} {name}: нет в рендере helmfile (проверь values и версию чарта)")


# host -> (Ingress, backend Service, port). Имена — из ingress-блоков
# helm/values/kps.yaml; /etc/hosts на рабочей машине должен указывать на ноду,
# иначе Traefik отвечает 404 (host-based routing без Host не срабатывает).
expected = {
    "monitoring-grafana": ("grafana.lab.internal", "monitoring-grafana", 80),
    "monitoring-kube-prometheus-prometheus": (
        "prometheus.lab.internal",
        "monitoring-kube-prometheus-prometheus",
        9090,
    ),
    "monitoring-kube-prometheus-alertmanager": (
        "alertmanager.lab.internal",
        "monitoring-kube-prometheus-alertmanager",
        9093,
    ),
}
for ing_name, (host, svc_name, svc_port) in expected.items():
    ing = find("Ingress", ing_name)
    if ing["spec"].get("ingressClassName") != "traefik":
        fail(
            f"Ingress {ing_name}: ingressClassName="
            f"{ing['spec'].get('ingressClassName')!r}, ожидался traefik"
            " — в k3s контроллер встроенный и его класс default"
        )
    hosts = [r.get("host") for r in ing["spec"].get("rules") or []]
    if host not in hosts:
        fail(f"Ingress {ing_name}: host'ы {hosts}, ожидался {host}")
    backend = ((ing["spec"]["rules"][0].get("http") or {}).get("paths") or [{}])[0].get(
        "backend", {}
    )
    service = backend.get("service") or {}
    if service.get("name") != svc_name or (service.get("port") or {}).get("number") != svc_port:
        fail(
            f"Ingress {ing_name}: backend {service}, ожидался {svc_name}:{svc_port}"
        )

# CR — источник внешнего URL: чарт подставляет первый host Ingress. Если связь
# порвётся (обновление чарта, ручной host без ingress), UI и ссылки уведут на
# in-cluster адреса, недоступные из браузера.
for kind, name, host in (
    ("Prometheus", "monitoring-kube-prometheus-prometheus", "prometheus.lab.internal"),
    ("Alertmanager", "monitoring-kube-prometheus-alertmanager", "alertmanager.lab.internal"),
):
    cr = find(kind, name)
    external_url = cr["spec"].get("externalUrl") or ""
    if host not in external_url:
        fail(
            f"{kind} {name}: externalUrl={external_url!r} не содержит {host} —"
            " чарт перестал выводить внешний URL из ingress host, ссылки UI уйдут"
            " на внутренние имена"
        )

grafana_ini = (find("ConfigMap", "monitoring-grafana")["data"] or {}).get("grafana.ini", "")
if "domain = grafana.lab.internal" not in grafana_ini:
    fail(
        "ConfigMap monitoring-grafana: в grafana.ini нет domain = grafana.lab.internal"
        " — чарт выводит server.domain из ingress host; без него root_url и ссылки"
        " Grafana считаются от localhost"
    )
print("ассерты доступа к UI (Ingress + externalUrl/domain): ok")
PY

# --- 4. Свои манифесты: kustomize + kubeconform ------------------------------
step "kubectl kustomize . -> kubeconform"
kubectl kustomize . > .tmp/rendered/kustomize.yaml
# Пустой рендер теперь означает сломанный kustomization.yaml, а не «пока нечего рендерить».
[ -s .tmp/rendered/kustomize.yaml ] || die "рендер kustomize пуст — проверь resources в kustomization.yaml"
kubeconform -strict -ignore-missing-schemas -summary -output text .tmp/rendered/kustomize.yaml

# --- 4a. Дашборды Grafana: JSON внутри ConfigMap kubeconform не проверяет ----
step "дашборды: валидность JSON"
shopt -s nullglob
DASH_FILES=(deploy/dashboards/*.json)
shopt -u nullglob
if [ "${#DASH_FILES[@]}" -eq 0 ]; then
  SKIPPED+=("валидация JSON дашбордов (deploy/dashboards/*.json ещё нет)")
elif command -v jq >/dev/null 2>&1; then
  for dashboard in "${DASH_FILES[@]}"; do
    jq -e . "${dashboard}" >/dev/null
  done
  printf 'проверено JSON-файлов: %d (jq)\n' "${#DASH_FILES[@]}"
elif command -v python3 >/dev/null 2>&1; then
  for dashboard in "${DASH_FILES[@]}"; do
    python3 -m json.tool "${dashboard}" >/dev/null
  done
  printf 'проверено JSON-файлов: %d (python3)\n' "${#DASH_FILES[@]}"
else
  SKIPPED+=("валидация JSON дашбордов (нет ни jq, ни python3)")
fi

# --- 4b. Оверлей деплоя: тег подставляется во ВСЕ образы приложений ---------
# Ловит два класса ошибок: новый сервис с тегом :local (так было бы с alert-sink
# в фазе 4) и случайную заглушку, доехавшую до манифестов.
step "рендер оверлея деплоя (теги образов)"
OVERLAY_RENDER="$(render_demo_manifests ci-check)"
shopt -s nullglob
APP_DOCKERFILES=(app/*/Dockerfile)
shopt -u nullglob
for dockerfile in "${APP_DOCKERFILES[@]}"; do
  app_name="$(basename "$(dirname "${dockerfile}")")"
  grep -q "image: ${app_name}:ci-check" "${OVERLAY_RENDER}" \
    || die "в рендере нет образа ${app_name}:ci-check — build/import найдут этот сервис, а deploy оставит ему заглушку тега"
done
if grep -qE 'image: [^ "]*:local$' "${OVERLAY_RENDER}"; then
  die "в рендере остался тег :local — заглушка из kustomization.yaml попала в манифесты"
fi
printf 'образов с подставленным тегом: %d\n' "${#APP_DOCKERFILES[@]}"

# --- 4c. Маршрут уведомлений: severity -> e-mail/alert-sink -------------------
# kubeconform схему AlertmanagerConfig не знает (--ignore-missing-schemas), а вложенные
# child-routes в CRD объявлены как preserve-unknown-fields — то есть структуру маршрута
# офлайн не проверяет никто, кроме этого шага. Цена ошибки высокая: кривой конфиг
# останавливает ВСЮ доставку, включая приёмник, и молчание выглядит как «всё хорошо».
# Патч адресов проверяется двумя рендерами: с env (значения подставлены) и без него
# (в выводе плейсхолдеры) — иначе подстановка могла бы молча бить в чужой receiver.
step "маршрут уведомлений в рендере"
ROUTE_PLAIN="${PROJECT_ROOT}/.tmp/rendered/route-plain.yaml"
ROUTE_FILLED="${PROJECT_ROOT}/.tmp/rendered/route-filled.yaml"
ROUTE_BAD="${PROJECT_ROOT}/.tmp/rendered/route-bad.yaml"
ROUTE_QUOTED="${PROJECT_ROOT}/.tmp/rendered/route-quoted.yaml"
( unset ALERT_EMAIL_TO ALERT_EMAIL_FROM SMTP_SMARTHOST SMTP_USERNAME
  render_demo_manifests ci-route "${ROUTE_PLAIN}" >/dev/null )
( export ALERT_EMAIL_TO=page@example.invalid SMTP_SMARTHOST=smtp.example.invalid:587
  render_demo_manifests ci-route "${ROUTE_FILLED}" >/dev/null )
# Значение с пробелом, запятой и угловыми скобками: проверяет, что json.dumps действительно
# экранирует, а собранный вручную YAML не рвётся на «плохом» адресе.
( export ALERT_EMAIL_FROM='Alert Manager <alertmanager@example.invalid>, ops'
  render_demo_manifests ci-route "${ROUTE_QUOTED}" >/dev/null )
# Негативный прогон: хост без порта обязан упасть. Валидация, проверенная только руками
# (так было записано в CHANGELOG), пропустила бы опечатку до самого apply.
if ( export SMTP_SMARTHOST=smtp.example.invalid
     render_demo_manifests ci-route "${ROUTE_BAD}" ) >/dev/null 2>&1; then
  die "SMTP_SMARTHOST без порта прошёл рендер: валидация host:port в scripts/lib.sh сломана"
fi
[ ! -e "${ROUTE_BAD}" ] || rm -f "${ROUTE_BAD}"
python3 - "${ROUTE_PLAIN}" "${ROUTE_FILLED}" "${ROUTE_QUOTED}" <<'PY'
import sys

import yaml

PLACEHOLDER = {
    "to": "alerts@example.invalid",
    "from": "alertmanager@example.invalid",
    "smarthost": "smtp.example.invalid:587",
    "authUsername": "alertmanager",
}


def fail(message):
    sys.exit(message)


def route_spec(path):
    for doc in yaml.safe_load_all(open(path, encoding="utf-8")):
        if (
            isinstance(doc, dict)
            and doc.get("kind") == "AlertmanagerConfig"
            and (doc.get("metadata") or {}).get("name") == "demo-notifications"
        ):
            return doc["spec"]
    fail(f"{path}: в рендере нет AlertmanagerConfig demo-notifications")


def matcher(route, where):
    found = route.get("matchers")
    if not found or len(found) != 1:
        fail(f"{where}: matchers={found!r}, ожидался ровно один матчер по severity")
    only = found[0]
    if only.get("name") != "severity" or only.get("matchType") != "=~":
        fail(f"{where}: матчер {only!r}, ожидался name=severity matchType=~")
    return only.get("value")


spec = route_spec(sys.argv[1])
route = spec.get("route") or {}
expected = {
    "receiver": "alert-sink",
    "groupBy": ["alertname", "service"],
    "groupWait": "10s",
    "groupInterval": "30s",
    "repeatInterval": "4h",
}
for key, value in expected.items():
    if route.get(key) != value:
        fail(f"route.{key}={route.get(key)!r}, ожидалось {value!r}")

children = route.get("routes") or []
if len(children) != 4:
    fail(
        f"child-routes родителя: {len(children)}, ожидалось 4"
        " (heartbeat → e-mail, severity page|critical → e-mail, severity для остального,"
        " catch-all)"
    )
heartbeat_route, email_route, ticket_route, catch_all = children
# Heartbeat-ветка обязана быть первой: алерты AlertSink* имеют severity ticket, и без
# почты они остаются только в том sink, поломку которого описывают.
if heartbeat_route.get("receiver") != "email":
    fail(f"child-routes[0].receiver={heartbeat_route.get('receiver')!r}, ожидался email")
if heartbeat_route.get("continue") is not True:
    fail(
        "child-routes[0] без continue: true — heartbeat-алерт не доедет до sink,"
        " а /timeline останется без записи о поломке пути"
    )
hb_matchers = heartbeat_route.get("matchers") or []
if len(hb_matchers) != 1:
    fail(f"child-routes[0].matchers={hb_matchers!r}, ожидался ровно один матчер по alertname")
hb_only = hb_matchers[0]
if (hb_only.get("name"), hb_only.get("matchType"), hb_only.get("value")) != (
    "alertname",
    "=~",
    "AlertSink.*",
):
    fail(
        f"child-routes[0]: матчер {hb_only!r},"
        " ожидался alertname=~'AlertSink.*' (имена правил rules/notifications.yaml)"
    )
if email_route.get("receiver") != "email":
    fail(f"child-routes[1].receiver={email_route.get('receiver')!r}, ожидался email")
if email_route.get("continue") is not True:
    fail(
        "child-routes[1] без continue: true — Alertmanager остановится на e-mail-ветке,"
        " и остальные ветки для этого алерта не рассматриваются"
    )
if matcher(email_route, "child-routes[1]") != "page|critical":
    fail(f"child-routes[1]: severity={matcher(email_route, 'child-routes[1]')!r}, ожидалось page|critical")
if ticket_route.get("receiver") != "alert-sink":
    fail(f"child-routes[2].receiver={ticket_route.get('receiver')!r}, ожидался alert-sink")
if ticket_route.get("continue"):
    fail("child-routes[2] с continue: true — лишняя ветка ниже получит тот же алерт")
if matcher(ticket_route, "child-routes[2]") != "ticket|info|warning|none":
    fail(
        "child-routes[2]: severity="
        f"{matcher(ticket_route, 'child-routes[2]')!r}, ожидалось ticket|info|warning|none"
    )
if catch_all.get("receiver") != "alert-sink":
    fail(f"catch-all.receiver={catch_all.get('receiver')!r}, ожидался alert-sink")
if catch_all.get("matchers"):
    fail(
        f"catch-all с матчерами {catch_all.get('matchers')!r} — неизвестный severity"
        " уйдёт в null-получатель и исчезнет молча"
    )

receivers = spec.get("receivers") or []
names = [r.get("name") for r in receivers]
if names != ["alert-sink", "email"]:
    fail(
        f"receivers: {names}, ожидалось ['alert-sink', 'email'] —"
        " от индекса 1 зависит патч адресов в scripts/lib.sh"
    )
configs = receivers[1].get("emailConfigs") or []
if len(configs) != 1:
    fail(f"receivers[1].emailConfigs: {len(configs)}, ожидался один")
email = configs[0]
password = email.get("authPassword") or {}
if password.get("name") != "alertmanager-smtp" or password.get("key") != "smtp-password":
    fail(
        f"authPassword={password!r}, ожидался Secret alertmanager-smtp ключ smtp-password"
        " (docs/runbook.md, «Маршрут уведомлений»)"
    )
if email.get("requireTLS") is not True or email.get("sendResolved") is not True:
    fail(
        "emailConfigs[0]: requireTLS/sendResolved не true — письмо уйдёт без STARTTLS"
        " или о закрытии алерта не будет уведомления"
    )
if email.get("html"):
    fail("emailConfigs[0].html заполнен: план — только text, без html-вёрстки")
text = email.get("text") or ""
# Проверяем именно ссылки на поля шаблона, а не слова в комментарии: «alertname» есть
# в любом тексте, а письмо без `.Labels.alertname` бесполезно.
missing = [
    token
    for token in (
        ".Labels.alertname",
        ".Labels.severity",
        ".Annotations.summary",
        ".Annotations.runbook_url",
    )
    if token not in text
]
if missing:
    fail(f"emailConfigs[0].text без полей {missing} — в письме не будет {', '.join(missing)}")

for field, value in PLACEHOLDER.items():
    if email.get(field) != value:
        fail(
            f"базовый рендер: emailConfigs[0].{field}={email.get(field)!r},"
            f" ожидался плейсхолдер {value!r} (реальные значения подставляет оверлей)"
        )

filled_spec = route_spec(sys.argv[2])
filled = filled_spec["receivers"][1]["emailConfigs"][0]
if filled.get("to") != "page@example.invalid":
    fail(f"с ALERT_EMAIL_TO рендер дал to={filled.get('to')!r} — патч не доехал до receivers[1]")
if filled.get("smarthost") != "smtp.example.invalid:587":
    fail(f"с SMTP_SMARTHOST рендер дал smarthost={filled.get('smarthost')!r}, ожидалось smtp.example.invalid:587")
for field in ("from", "authUsername"):
    if filled.get(field) != PLACEHOLDER[field]:
        fail(
            f"задавали только ALERT_EMAIL_TO и SMTP_SMARTHOST, но {field}="
            f"{filled.get(field)!r} — патч задел то, что не передавали"
        )

# Значение с пробелом, запятой и угловыми скобками: YAML не должен развалиться, а строка —
# обрезаться по первому пробелу при сборке патча.
quoted = route_spec(sys.argv[3])["receivers"][1]["emailConfigs"][0]
expected_from = "Alert Manager <alertmanager@example.invalid>, ops"
if quoted.get("from") != expected_from:
    fail(f"адрес с пробелом и запятой отрендерился как {quoted.get('from')!r} — экранирование сломано")
print("ассерты маршрута уведомлений и подстановки адресов: ok")
PY

# --- 4d. Loki ruler: правило по логам в рендере -------------------------------
# Правило Loki живёт вне Prometheus: его читает ruler внутри пода Loki из каталога,
# смонтированного из ConfigMap. Ошибку здесь не видит ни kubeconform (это data
# ConfigMap), ни promtool (LogQL он не разбирает), а цена — молчащее правило:
# неверный путь тома, потерянный суффикс тенанта или выключенный ruler выглядят
# как «логов просто нет». Поэтому проверяется вся цепочка: конфиг ruler -> том
# у StatefulSet -> ConfigMap из kustomize -> сам файл правила.
step "Loki ruler в рендере"
python3 - .tmp/rendered/helmfile.yaml .tmp/rendered/kustomize.yaml <<'PY'
import sys

import yaml

render_path, kustomize_path = sys.argv[1], sys.argv[2]
docs = [
    d
    for d in yaml.safe_load_all(open(render_path, encoding="utf-8"))
    if isinstance(d, dict)
]
kustomize_docs = [
    d
    for d in yaml.safe_load_all(open(kustomize_path, encoding="utf-8"))
    if isinstance(d, dict)
]

ALERTMANAGER_URL = (
    "http://monitoring-kube-prometheus-alertmanager.monitoring.svc:9093"
)
# Локальное хранилище правил читает <directory>/<tenant>/<файл>, а тенант при
# auth_enabled: false — "fake" (docs Loki, multi-tenancy). Отсюда и путь тома.
RULES_DIR = "/etc/loki/rules"
TENANT_DIR = RULES_DIR + "/fake"
RULE_KEY = "demo-api-5xx.yaml"


def fail(message):
    sys.exit(message)


def find(docs_, kind, name):
    for doc in docs_:
        if doc.get("kind") == kind and (doc.get("metadata") or {}).get("name") == name:
            return doc
    fail(f"{kind} {name}: нет в рендере (проверь values и версию чарта)")


# 1) Конфиг Loki: ruler включён, смотрит в Alertmanager и читает наш каталог.
config_map = find(docs, "ConfigMap", "loki")
config = yaml.safe_load((config_map.get("data") or {}).get("config.yaml") or "")
ruler = (config or {}).get("ruler")
if not ruler:
    fail(
        "в config.yaml Loki нет блока ruler — ruleConfig из helm/values/loki.yaml"
        " не доехал, правило по логам не загрузится"
    )
if ruler.get("alertmanager_url") != ALERTMANAGER_URL:
    fail(
        f"ruler.alertmanager_url={ruler.get('alertmanager_url')!r}, ожидался {ALERTMANAGER_URL!r}"
        " (Service релиза monitoring; при другом адресе алерты правила уйдут в никуда)"
    )
if ruler.get("enable_api") is not True:
    fail(
        "ruler.enable_api не true — GET /prometheus/api/v1/rules не поднимется,"
        " и проверить загрузку правила будет нечем"
    )
storage = ruler.get("storage") or {}
if storage.get("type") != "local" or (storage.get("local") or {}).get("directory") != RULES_DIR:
    fail(
        f"ruler.storage={storage!r}, ожидалось type=local, directory={RULES_DIR}"
        " — другой тайп требует объектного хранилища, которого в лабе нет"
    )

# 2) Том у пода: ConfigMap смонтирован ровно в каталог тенанта, только на чтение.
sts = find(docs, "StatefulSet", "loki")
pod = sts["spec"]["template"]["spec"]
mounts = [
    m
    for container in pod["containers"]
    for m in container.get("volumeMounts") or []
    if m.get("name") == "loki-rules"
]
if len(mounts) != 1:
    fail(f"StatefulSet loki: смонтировано томов loki-rules {len(mounts)}, ожидался один")
mount = mounts[0]
if mount.get("mountPath") != TENANT_DIR:
    fail(
        f"том loki-rules смонтирован в {mount.get('mountPath')!r}, ожидалось {TENANT_DIR!r}."
        " Локальное хранилище правил ищет файлы в подкаталоге тенанта: плоский"
        " /etc/loki/rules правило не увидит"
    )
if mount.get("readOnly") is not True:
    fail("том loki-rules смонтирован не readOnly: правила не должны меняться из пода")
volumes = [v for v in pod.get("volumes") or [] if v.get("name") == "loki-rules"]
if len(volumes) != 1 or (volumes[0].get("configMap") or {}).get("name") != "loki-rules":
    fail(
        f"том loki-rules={volumes!r}, ожидался configMap loki-rules"
        " (ConfigMap создаёт kustomize из deploy/loki-rules)"
    )

# 3) ConfigMap из kustomize: тот самый ключ, который ждёт том.
rules_cm = find(kustomize_docs, "ConfigMap", "loki-rules")
if (rules_cm.get("metadata") or {}).get("namespace") != "monitoring":
    fail("ConfigMap loki-rules не в namespace monitoring — рядом с подом Loki его нет")
data = rules_cm.get("data") or {}
if RULE_KEY not in data:
    fail(
        f"в ConfigMap loki-rules ключи {sorted(data)}, ожидался {RULE_KEY}"
        " — смонтированный файл не совпадёт с тем, что читает ruler"
    )
rule_doc = yaml.safe_load(data[RULE_KEY]) or {}

# 4) Само правило: структурный разбор (LogQL promtool не проверяет).
groups = rule_doc.get("groups") or []
if not groups:
    fail(f"{RULE_KEY}: нет groups — файл правил пуст или это не формат ruler")
rule = None
for group in groups:
    for candidate in group.get("rules") or []:
        if candidate.get("alert") == "DemoApi5xxFromLogs":
            rule = candidate
            break
if rule is None:
    fail(f"{RULE_KEY}: нет правила DemoApi5xxFromLogs")
expr = rule.get("expr") or ""
for token in ("count_over_time(", '{namespace="demo", app="demo-api"}', "| json", "status >= 500"):
    if token not in expr:
        fail(f"DemoApi5xxFromLogs: в expr нет {token!r} — правило считает не то, что задумано")
# Штатный дренаж пода отвечает /ready → 503, и без фильтра правило горит ticket на
# каждом плановом рестарте с SIGTERM. Проверено на живых данных 2026-11-09: за доступное
# окно хранения (~46 ч — PVC Loki пересоздан 2026-11-07 11:13 UTC) единственная строка
# со status >= 500 — именно GET /ready при SIGTERM. Ассерт держит фильтр от удаления.
if 'route != "/ready"' not in expr:
    fail(
        "DemoApi5xxFromLogs: из expr пропал фильтр 'route != \"/ready\"'. Без него 503"
        " самопроверки готовности при SIGTERM даёт ложный ticket на каждом рестарте пода"
        " (см. комментарий в deploy/loki-rules/demo-api-5xx.yaml)"
    )
labels = rule.get("labels") or {}
if labels.get("severity") != "ticket":
    fail(
        f"DemoApi5xxFromLogs: severity={labels.get('severity')!r}, ожидался ticket"
        " — page увёл бы уточнение причины по логам в почту"
    )
if labels.get("service") != "demo-api":
    fail(f"DemoApi5xxFromLogs: service={labels.get('service')!r}, ожидался demo-api")
if rule.get("for") != "2m":
    fail(f"DemoApi5xxFromLogs: for={rule.get('for')!r}, ожидалось 2m")
print("ассерты Loki ruler (конфиг, том, ConfigMap, правило): ok")
PY
# Оверлей деплоя (scripts/lib.sh) — второй список ресурсов kustomize, и он тоже обязан
# содержать deploy/loki-rules: иначе deploy.sh применит StatefulSet с томом на
# несуществующий ConfigMap, под Loki не встанет, и встанет вся запись логов.
grep -q 'name: loki-rules' "${OVERLAY_RENDER}" \
  || die "в оверлее деплоя нет ConfigMap loki-rules — проверь список resources в scripts/lib.sh (render_demo_manifests)"

# --- 5. Правила Prometheus: синтаксис и юнит-тесты ---------------------------
# promtool не умеет читать PrometheusRule CRD («field apiVersion not found in type
# rulefmt.RuleGroups»), а правила обязаны быть CRD: оператор находит их по метке
# release=monitoring. Поэтому spec.groups выгружается в .tmp — единственное место,
# где формат правил превращается в формат promtool. Файлы rules/tests/*.test.yaml
# ссылаются на выгрузку относительным путём: второго источника истины нет.
step "promtool: PrometheusRule -> rulefiles в .tmp"
RULEFILES_DIR="${PROJECT_ROOT}/.tmp/rendered/rulefiles"
# :? — чтобы опечатка в PROJECT_ROOT не превратила это в rm -rf от корня.
rm -rf "${RULEFILES_DIR:?}"
mkdir -p "${RULEFILES_DIR}"
shopt -s nullglob
RULE_SOURCES=("${PROJECT_ROOT}"/rules/*.yaml)
shopt -u nullglob
[ "${#RULE_SOURCES[@]}" -gt 0 ] \
  || die "в rules/ нет ни одного .yaml — проверь, что каталог на месте"
python3 - "${RULEFILES_DIR}" "${RULE_SOURCES[@]}" <<'PY'
import os
import sys

import yaml

out_dir, paths = sys.argv[1], sys.argv[2:]
for path in paths:
    with open(path, encoding="utf-8") as handle:
        doc = yaml.safe_load(handle)
    # kustomization.yaml и прочие служебные файлы пропускаем: это не правила.
    if not isinstance(doc, dict) or doc.get("kind") != "PrometheusRule":
        continue
    groups = (doc.get("spec") or {}).get("groups")
    if not groups:
        sys.exit(f"{path}: в PrometheusRule нет spec.groups")
    name = os.path.basename(path)
    with open(os.path.join(out_dir, name), "w", encoding="utf-8") as handle:
        yaml.safe_dump({"groups": groups}, handle, sort_keys=False, allow_unicode=True)
    print(f"  {name}: групп {len(groups)}")
PY

step "promtool check rules"
shopt -s nullglob
RULE_FILES=("${RULEFILES_DIR}"/*.yaml)
shopt -u nullglob
# Пустая выгрузка означает не «правил ещё нет», а сломанный rules/: иначе ворота
# молча зеленели бы без единого проверенного правила.
[ "${#RULE_FILES[@]}" -gt 0 ] \
  || die "выгрузка не дала ни одного PrometheusRule: в rules/ только служебные файлы?"
promtool check rules "${RULE_FILES[@]}"

# --- 5a. Ссылки в алертах: абсолютные и с живым анкором ----------------------
# runbook_url из уведомления открывает браузер по абсолютному адресу, поэтому
# относительный путь ("docs/runbook.md") — это 404 у получателя. Анкор сверяется
# со slug заголовков runbook по алгоритму GitHub: переименование подраздела иначе
# тихо ломает все ссылки, и видно это только в письме. dashboard_url проверяется
# тем же проходом — по uid существующих дашбордов.
step "ссылки в алертах: runbook_url и dashboard_url"
python3 - "${RULEFILES_DIR}" <<'PY'
import glob
import json
import os
import re
import sys

import yaml

RUNBOOK = (
    "https://github.com/morgenvor/k8s-observability-lab/blob/main/docs/runbook.md#"
)
DASHBOARD = "http://grafana.lab.internal/d/"
rulefiles_dir = sys.argv[1]


def slug(heading):
    # Алгоритм GitHub: нижний регистр, пунктуация вырезается, пробелы -> дефис.
    text = heading.strip().lower()
    text = re.sub(r"[^\w\- ]", "", text, flags=re.UNICODE)
    return text.replace(" ", "-")


anchors = {}
suffix_seen = {}
in_fence = False
with open("docs/runbook.md", encoding="utf-8") as handle:
    for line in handle:
        # Заголовки внутри код-фенсов GitHub анкорами не считает: без этого
        # "<<## ...>>" в примере дал бы анкор, который в реальности не резолвится.
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        match = re.match(r"#{2,3} +(.+?)\s*$", line)
        if not match:
            continue
        base = slug(match.group(1))
        # Повторный заголовок GitHub делает "slug-1", "slug-2": без этого ссылка
        # на второй такой заголовок выглядела бы мёртвой, хотя она работает.
        if base in anchors:
            suffix_seen[base] = suffix_seen.get(base, 1) + 1
            anchors[f"{base}-{suffix_seen[base] - 1}"] = match.group(1)
        else:
            anchors[base] = match.group(1)
if not anchors:
    sys.exit("в docs/runbook.md не найдено ни одного заголовка ##/###")

uids = {}
for path in glob.glob("deploy/dashboards/*.json"):
    with open(path, encoding="utf-8") as handle:
        uid = json.load(handle).get("uid")
    if uid:
        uids[uid] = path
if not uids:
    sys.exit("в deploy/dashboards/*.json нет ни одного uid")

errors = []
checked = {"runbook": 0, "dashboard": 0}
# Источники алертов: правила Prometheus (выгруженные из CRD groups) и правила Loki ruler
# (свой формат, CRD нет). Второй источник добавлен в фазе 5 v1.1: иначе единственный
# алерт, чья ссылка ведёт к человеку, никем бы не проверялся.
sources = [
    (path, os.path.join("rules", os.path.basename(path)))
    for path in sorted(glob.glob(os.path.join(rulefiles_dir, "*.yaml")))
]
sources += [
    (path, path) for path in sorted(glob.glob("deploy/loki-rules/*.yaml"))
]
for path, source in sources:
    with open(path, encoding="utf-8") as handle:
        doc = yaml.safe_load(handle)
    for group in (doc or {}).get("groups") or []:
        for rule in group.get("rules") or []:
            if "alert" not in rule:
                continue
            annotations = rule.get("annotations") or {}
            where = f"{source}: {rule['alert']}"
            runbook = annotations.get("runbook_url")
            if not runbook:
                errors.append(f"{where}: нет runbook_url — уведомление не ведёт в процедуру")
            elif not runbook.startswith(RUNBOOK):
                errors.append(f"{where}: runbook_url не абсолютный или мимо файла: {runbook}")
            else:
                anchor = runbook[len(RUNBOOK):]
                if anchor not in anchors:
                    errors.append(
                        f"{where}: анкора #{anchor} нет в docs/runbook.md"
                        f" (ближайшие заголовки: {', '.join(sorted(anchors)[:8])})"
                    )
                checked["runbook"] += 1
            dashboard = annotations.get("dashboard_url")
            if dashboard:
                if not dashboard.startswith(DASHBOARD):
                    errors.append(f"{where}: dashboard_url не http://grafana.lab.internal/d/<uid>: {dashboard}")
                elif dashboard[len(DASHBOARD):] not in uids:
                    errors.append(
                        f"{where}: uid '{dashboard[len(DASHBOARD):]}' нет в deploy/dashboards/*.json"
                        f" (есть: {', '.join(sorted(uids))})"
                    )
                else:
                    checked["dashboard"] += 1
if errors:
    for error in errors:
        print(f"  {error}", file=sys.stderr)
    sys.exit(f"ссылки в алертах: ошибок {len(errors)}")
# Ноль проверенных ссылок — не «всё хорошо», а «проверять было нечего»: файл правил
# без groups прошёл бы через glob молча.
if not sum(checked.values()):
    sys.exit(f"в {rulefiles_dir} не найдено ни одного алерта со ссылками — проверять нечего")
print(
    f"проверено ссылок: runbook_url {checked['runbook']},"
    f" dashboard_url {checked['dashboard']}; анкоров в runbook {len(anchors)}"
)
PY

step "promtool test rules"
shopt -s nullglob
RULE_TESTS=(rules/tests/*.test.yaml)
shopt -u nullglob
if [ "${#RULE_TESTS[@]}" -gt 0 ]; then
  promtool test rules "${RULE_TESTS[@]}"
else
  SKIPPED+=("promtool test rules (rules/tests появятся в фазе 3)")
fi

# --- 5b. Поведение дриллов (offline): сигналы и cleanup ----------------------
# Регресс на «passed без дрилла»: доказательство дрилла — JSON с result: passed,
# и он не должен появляться у прерванного прогона или при сбое шага cleanup.
# Кластер не нужен: каталоги evidence/state указывают в .tmp.
step "тесты дриллов (offline)"
bash drills/tests/signals.sh

# --- 6. shellcheck (если установлен; в CI предустановлен) --------------------
step "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  shopt -s nullglob
  SHELL_FILES=(scripts/*.sh drills/*.sh drills/tests/*.sh)
  shopt -u nullglob
  if [ "${#SHELL_FILES[@]}" -gt 0 ]; then
    shellcheck -S warning "${SHELL_FILES[@]}"
  else
    SKIPPED+=("shellcheck (нет .sh-файлов)")
  fi
else
  SKIPPED+=("shellcheck (не установлен)")
fi

# --- 7. Образы приложений (по флагу) ----------------------------------------
if [ "${WITH_IMAGES}" -eq 1 ]; then
  step "docker build"
  shopt -s nullglob
  DOCKERFILES=(app/*/Dockerfile)
  shopt -u nullglob
  if [ "${#DOCKERFILES[@]}" -eq 0 ]; then
    SKIPPED+=("docker build (нет app/*/Dockerfile)")
  else
    need_cmd docker
    for dockerfile in "${DOCKERFILES[@]}"; do
      app_dir="$(dirname "${dockerfile}")"
      name="$(basename "${app_dir}")"
      printf -- '--- %s\n' "${name}"
      docker build -t "${name}:check" "${app_dir}"
    done
  fi
fi

# --- 8. Секреты и лабораторные адреса в файлах, которые попадут в git --------
# Сканируем ровно публикуемый набор: трекаемые файлы + untracked, не покрытые
# ignore. Внутренние документы (.dsh/, AGENTS.md, CHANGELOG.md) исключены локальным
# .git/info/exclude и намеренно содержат hostname лабы — их в git нет.
step "скан секретов и адресов"
# Без git список публикуемого набора не построить: молчаливый пропуск здесь означал
# бы зелёные ворота без скана вовсе.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "скан секретов требует git (git ls-files): репозиторий не найден"
mapfile -d '' -t SCAN_FILES < <(git ls-files -z --cached --others --exclude-standard)
[ "${#SCAN_FILES[@]}" -gt 0 ] \
  || die "git не видит файлов для скана — проверь репозиторий и .git/info/exclude"
# .secrets/ (kubeconfig и ssh-конфиг лабы) обязан быть вне индекса. Скан ниже поймал
# бы ключи и адреса и так, но причина другая — «файл попал в индекс», а не «утечка»,
# и сообщение об этом должно называть настоящий шаг исправления.
SECRETS_TRACKED="$(git ls-files --cached -- '.secrets' || true)"
[ -z "${SECRETS_TRACKED}" ] \
  || die ".secrets/ попал в индекс git (${SECRETS_TRACKED}); убери: git rm --cached -r .secrets"
git check-ignore -q '.secrets/kubeconfig' \
  || die ".secrets/ не исключён .gitignore — любой git add . утащит kubeconfig в публикуемый набор"
SCAN_OUT=".tmp/scan.out"
scan_rc=0
# Что ловим: приватные сети стенда и pod CIDR, приватные ключи и токены, имена нод
# лабы и следы лаборатории/рабочей станции в тексте. Шаблоны 10.x не обобщаем: широкий
# регэксп начал бы падать на номерах версий в чужих values. Часть слов набрана с
# классом символов (prox[m]ox, par[r]ot) и без цифр в комментариях: иначе скан находит
# сам себя в этом файле.
grep -nIE \
  '192\.168\.|10\.42\.|BEGIN [A-Z ]*PRIVATE KEY|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abprs]-|AKIA[0-9A-Z]{16}|k8s[-]server|k8s[-]agent|prox[m]ox|par[r]ot|VM 10[12]' \
  -- "${SCAN_FILES[@]}" >"${SCAN_OUT}" 2>&1 || scan_rc=$?
case "${scan_rc}" in
  0)
    # Печатаем только файл:строку: содержимое совпавшей строки — это может быть
    # сам секрет, и он не должен попадать в лог CI или терминал.
    cut -d: -f1,2 "${SCAN_OUT}" | sed 's/^/  /'
    die "найдены секреты, адреса или hostname лабы в файлах, которые попадут в git (файл:строка выше)"
    ;;
  1) : ;; # совпадений нет — норма
  *) die "скан секретов не выполнился (grep вернул ${scan_rc}), см. ${SCAN_OUT}" ;;
esac

# --- 8a. Личные адреса: в публикуемом наборе только example.invalid/example.com --
# Правило 4 AGENTS: реальный адрес получателя — такой же секрет, как IP стенда.
# Домены example.* зарезервированы RFC 2606 и намеренно остаются в файлах как
# плейсхолдеры (README прямо это объясняет). Регэксп требует точку в домене и
# пишется с классом [@]: широкий вариант ловил бы scoped-пакеты (@types/node) и
# находил бы сам себя в этом файле. Строки с адресами не печатаем — печатаем файл.
step "скан личных адресов"
python3 - "${SCAN_FILES[@]}" <<'PY'
import re
import sys

# Адрес: local-part@домен с хотя бы одной точкой. Домен без точки (scoped-пакет,
# digest @sha256) адресом не считается.
ADDRESS = re.compile(r"[A-Za-z0-9._%+-]+[@][A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+")
ALLOWED = re.compile(r"[@](?:example[.]invalid|example[.]com)$", re.IGNORECASE)

bad = []
seen = 0
for path in sys.argv[1:]:
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    except OSError:
        continue
    # Бинарные файлы (изображения в docs/images) текстом не разбираем: там случайные
    # байты, а секретов в картинке скан всё равно не найдёт — её проверяет человек.
    if "\x00" in text:
        continue
    for number, line in enumerate(text.splitlines(), 1):
        for match in ADDRESS.finditer(line):
            seen += 1
            if not ALLOWED.search(match.group(0)):
                bad.append(f"{path}:{number}")
if bad:
    for where in bad:
        print(f"  {where}", file=sys.stderr)
    sys.exit(
        f"найдено адресов вне example.invalid/example.com: {len(bad)}"
        " (файл:строка выше; реальный адрес подставляет окружение, в git только плейсхолдер)"
    )
print(f"адреса в публикуемом наборе: {seen}, все в example.invalid/example.com")
PY

# --- Итог -------------------------------------------------------------------
if [ "${#SKIPPED[@]}" -gt 0 ]; then
  printf '\nпропущено:\n'
  printf '  - %s\n' "${SKIPPED[@]}"
  if [ "${STRICT}" -eq 1 ]; then
    die "строгий режим (--strict/CHECK_STRICT=1): проверок пропущено ${#SKIPPED[@]} — зелёный результат без них недостоверен"
  fi
fi
printf '\nOK: все доступные проверки прошли\n'

