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
  {
    printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\n'
    # LoadRestrictionsNone нужен ниже: оверлей в .tmp ссылается на deploy/ в корне.
    printf 'resources:\n  - ../../deploy/base\n  - ../../deploy/dashboards\n'
    printf 'images:\n'
    for image in demo-api demo-load; do
      printf '  - name: %s\n    newTag: %s\n' "${image}" "${tag}"
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
