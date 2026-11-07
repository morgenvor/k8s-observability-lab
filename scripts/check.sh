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
require_tools helm helmfile kubectl kubeconform promtool
mkdir -p "${PROJECT_ROOT}/.tmp/rendered"
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

# --- Итог -------------------------------------------------------------------
if [ "${#SKIPPED[@]}" -gt 0 ]; then
  printf '\nпропущено:\n'
  printf '  - %s\n' "${SKIPPED[@]}"
  if [ "${STRICT}" -eq 1 ]; then
    die "строгий режим (--strict/CHECK_STRICT=1): проверок пропущено ${#SKIPPED[@]} — зелёный результат без них недостоверен"
  fi
fi
printf '\nOK: все доступные проверки прошли\n'

