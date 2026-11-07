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
  need_cmd python3
  python3 -c 'import yaml' 2>/dev/null \
    || die "нет модуля PyYAML для подсчёта групп правил (python3 -m pip install pyyaml)"
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

# KUBECONFIG: из env, иначе дефолт лабы (файл вне репозитория).
# Возвращает путь в stdout; при отсутствии — ошибка с понятным следующим шагом.
default_kubeconfig() {
  if [ -n "${KUBECONFIG:-}" ]; then
    [ -f "${KUBECONFIG}" ] || die "KUBECONFIG='${KUBECONFIG}' не найден"
    printf '%s\n' "${KUBECONFIG}"
    return 0
  fi
  local fallback="${PROJECT_ROOT}/../proxmox-lab/.secrets/kubeconfig-phase5b"
  if [ -f "${fallback}" ]; then
    printf '%s\n' "$(cd "$(dirname "${fallback}")" && pwd)/$(basename "${fallback}")"
    return 0
  fi
  die "нет kubeconfig: задай KUBECONFIG или положи его в ../proxmox-lab/.secrets/ (кластер живёт в лабе; если VM 101/102 остановлены — их старт это действие владельца)"
}

# Рендер демо-контура с тегами образов в .tmp: трекаемый kustomization.yaml не меняется.
# Печатает путь к отрендеренному файлу. Используется deploy.sh и rollback.sh.
render_demo_manifests() {
  local tag="$1"
  local overlay="${PROJECT_ROOT}/.tmp/overlay"
  local out="${PROJECT_ROOT}/.tmp/rendered/deploy.yaml"
  mkdir -p "${overlay}" "$(dirname "${out}")"
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
    printf 'resources:\n  - ../../deploy/base\n  - ../../deploy/dashboards\n  - ../../deploy/monitoring\n  - ../../rules\n'
    printf 'images:\n'
    # Список образов — из app/*/Dockerfile, как в build-image.sh/import-image.sh:
    # иначе новый сервис (alert-sink в фазе 4) отрендерился бы с заглушкой :local.
    for dockerfile in "${images[@]}"; do
      printf '  - name: %s\n    newTag: %s\n' "${dockerfile}" "${tag}"
    done
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
    || die "кластер не отвечает (KUBECONFIG=${KUBECONFIG}); проверь, что VM 101/102 запущены в лабе"
}
