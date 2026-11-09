#!/usr/bin/env bash
# Общие функции скриптов проекта. Подключается через `source`, сам не запускается.
# Здесь только пути и проверки: никаких IP, секретов и обращений к кластеру при source.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT
TOOLS_DIR="${PROJECT_ROOT}/.tools"
export TOOLS_DIR
TOOLS_BIN="${TOOLS_DIR}/bin"

info() { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Заголовок шага. Запоминает имя в STEP: по нему ERR-ловушка вызывающего скрипта
# сообщает, какой именно шаг упал, а не «что-то пошло не так».
STEP=""
step() { STEP="$*"; printf '\n==> %s\n' "${STEP}"; }

# Инструменты проекта лежат в .tools (bootstrap-tools.sh), helm-состояние — тоже там.
use_tools() {
  export PATH="${TOOLS_BIN}:${PATH}"
  export HELM_CONFIG_HOME="${TOOLS_DIR}/helm/config"
  export HELM_CACHE_HOME="${TOOLS_DIR}/helm/cache"
  export HELM_DATA_HOME="${TOOLS_DIR}/helm/data"
  mkdir -p "${HELM_CONFIG_HOME}" "${HELM_CACHE_HOME}" "${HELM_DATA_HOME}"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "нет команды '$1' (нужные инструменты ставит scripts/bootstrap-tools.sh)"
}

# PyYAML нужен выгрузке правил, подсчёту групп и ассертам в scripts/checks: проверяем
# сразу и одним сообщением, иначе шаг падал бы трейсбеком ModuleNotFoundError.
need_pyyaml() {
  need_cmd python3
  python3 -c 'import yaml' 2>/dev/null \
    || die "нет модуля PyYAML (python3 -m pip install pyyaml)"
}

# Проверяет, что инструменты уже скачаны; иначе подсказывает bootstrap.
require_tools() {
  local missing=()
  local t
  for t in "$@"; do
    [ -x "${TOOLS_BIN}/${t}" ] || missing+=("$t")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    die "нет инструментов в .tools/bin: ${missing[*]}; запусти ./scripts/bootstrap-tools.sh"
  fi
  use_tools
}

# Число групп правил проекта — из самих файлов rules/*.yaml, а не из константы в
# скрипте: новый PrometheusRule не может «тихо» не доехать до Prometheus, а число
# не нужно править руками (раньше «7» жило и в комментарии, и в коде).
expected_rule_groups() {
  need_pyyaml
  local files=()
  mapfile -t files < <(printf '%s\n' "${PROJECT_ROOT}"/rules/*.yaml)
  [ -e "${files[0]}" ] || die "в rules/ нет ни одного .yaml — считать нечего"
  python3 - "${files[@]}" <<'PY'
import sys

import yaml

total = 0
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as handle:
        doc = yaml.safe_load(handle)
    # Служебные файлы (kustomization.yaml) — не правила.
    if not isinstance(doc, dict) or doc.get("kind") != "PrometheusRule":
        continue
    total += len((doc.get("spec") or {}).get("groups") or [])
print(total)
PY
}

# KUBECONFIG: из env, иначе .secrets/kubeconfig рядом с проектом (каталог в
# .gitignore: в git он не попадает, копий в репозитории нет).
# Возвращает путь в stdout; при отсутствии — ошибка с понятным следующим шагом.
default_kubeconfig() {
  if [ -n "${KUBECONFIG:-}" ]; then
    [ -f "${KUBECONFIG}" ] || die "KUBECONFIG='${KUBECONFIG}' не найден"
    printf '%s\n' "${KUBECONFIG}"
    return 0
  fi
  local fallback="${PROJECT_ROOT}/.secrets/kubeconfig"
  if [ -f "${fallback}" ]; then
    printf '%s\n' "${fallback}"
    return 0
  fi
  die "нет kubeconfig: задай KUBECONFIG или положи файл в .secrets/kubeconfig (каталог вне git; см. docs/runbook.md, «Как адаптировать»)"
}

# Строковый литерал в стиле JSON: и для JSON6902-патча, и как YAML-скаляр он
# годится без дополнительного экранирования, а bash-кавычки в значениях (адрес с
# запятой, пробелом) ломают ручную сборку YAML.
json_string() { python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1"; }

# Рендер демо-контура с тегами образов в .tmp: трекаемый kustomization.yaml не меняется.
# Печатает путь к отрендеренному файлу. Используется deploy.sh, rollback.sh и check.sh.
# Второй аргумент — куда писать рендер (по умолчанию .tmp/rendered/deploy.yaml):
# check.sh рендерит дважды (с подстановкой адресов и без) и сравнивает результаты.
# Env ALERT_EMAIL_TO/ALERT_EMAIL_FROM/SMTP_SMARTHOST/SMTP_USERNAME подставляет реальные
# адреса и SMTP-хост вместо плейсхолдеров example.invalid из git.
render_demo_manifests() {
  local tag="$1"
  local overlay="${PROJECT_ROOT}/.tmp/overlay"
  local out="${2:-${PROJECT_ROOT}/.tmp/rendered/deploy.yaml}"
  mkdir -p "${overlay}" "$(dirname "${out}")"

  # SMTP-хост обязан быть host:port: оверлей — не место, где это выяснится уже
  # после apply (письмо тогда просто не уйдёт, а конфиг останется валидным).
  if [ -n "${SMTP_SMARTHOST:-}" ]; then
    [[ "${SMTP_SMARTHOST}" =~ ^[^:]+:[0-9]+$ ]] \
      || die "SMTP_SMARTHOST='${SMTP_SMARTHOST}' не формата host:port (например smtp.example.invalid:587)"
  fi
  # Пары «json-pointer значение»: по одной строке на заданную переменную. Патч
  # появляется только для того, что реально передали: адреса и SMTP-хост можно
  # задать по отдельности (проверка в check.sh подставляет только два из четырёх).
  local email_patches=()
  if [ -n "${ALERT_EMAIL_TO:-}" ]; then
    email_patches+=("/spec/receivers/1/emailConfigs/0/to $(json_string "${ALERT_EMAIL_TO}")")
  fi
  if [ -n "${ALERT_EMAIL_FROM:-}" ]; then
    email_patches+=("/spec/receivers/1/emailConfigs/0/from $(json_string "${ALERT_EMAIL_FROM}")")
  fi
  if [ -n "${SMTP_SMARTHOST:-}" ]; then
    email_patches+=("/spec/receivers/1/emailConfigs/0/smarthost $(json_string "${SMTP_SMARTHOST}")")
  fi
  if [ -n "${SMTP_USERNAME:-}" ]; then
    email_patches+=("/spec/receivers/1/emailConfigs/0/authUsername $(json_string "${SMTP_USERNAME}")")
  fi
  if [ "${#email_patches[@]}" -eq 0 ] && [ -z "${EMAIL_PLACEHOLDER_WARNED:-}" ]; then
    # Один раз на процесс: deploy/rollback/check рендерят несколько раз подряд.
    EMAIL_PLACEHOLDER_WARNED=1
    warn "ALERT_EMAIL_TO/ALERT_EMAIL_FROM/SMTP_SMARTHOST/SMTP_USERNAME не заданы — в маршруте останутся плейсхолдеры example.invalid"
  fi
  local images=()
  local dockerfile
  for dockerfile in "${PROJECT_ROOT}"/app/*/Dockerfile; do
    [ -f "${dockerfile}" ] || continue
    images+=("$(basename "$(dirname "${dockerfile}")")")
  done
  [ "${#images[@]}" -gt 0 ] || die "нет app/*/Dockerfile — тегировать нечего"

  {
    printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\n'
    # LoadRestrictionsNone нужен ниже: оверлей в .tmp ссылается на deploy/ в корне.
    printf 'resources:\n  - ../../deploy/base\n  - ../../deploy/dashboards\n  - ../../deploy/loki-rules\n  - ../../deploy/monitoring\n  - ../../rules\n'
    printf 'images:\n'
    # Список образов — из app/*/Dockerfile, как в build-image.sh/import-image.sh:
    # иначе новый сервис (alert-sink в фазе 4) отрендерился бы с заглушкой :local.
    for dockerfile in "${images[@]}"; do
      printf '  - name: %s\n    newTag: %s\n' "${dockerfile}" "${tag}"
    done
    if [ "${#email_patches[@]}" -gt 0 ]; then
      printf 'patches:\n'
      printf '  - target:\n      group: monitoring.coreos.com\n      version: v1alpha1\n'
      printf '      kind: AlertmanagerConfig\n      name: demo-notifications\n'
      printf '    patch: |-\n'
      local pair
      for pair in "${email_patches[@]}"; do
        # Значение — последняя часть строки после первого пробела: JSON-литерал
        # может содержать пробелы (например «Имя <адрес>») и не должен резаться.
        printf '      - op: replace\n        path: %s\n        value: %s\n' \
          "${pair%% *}" "${pair#* }"
      done
    fi
  } > "${overlay}/kustomization.yaml"
  kubectl kustomize --load-restrictor LoadRestrictionsNone "${overlay}" > "${out}"
  [ -s "${out}" ] || die "рендер манифестов пуст — проверь kustomization.yaml и deploy/base"
  printf '%s\n' "${out}"
}

require_cluster() {
  local kc
  kc="$(default_kubeconfig)"
  export KUBECONFIG="${kc}"
  require_tools kubectl
  kubectl get nodes --request-timeout=10s >/dev/null 2>&1 \
    || die "кластер не отвечает (KUBECONFIG=${KUBECONFIG}); проверь, что машины стенда запущены"
}
