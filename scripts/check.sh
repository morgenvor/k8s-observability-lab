#!/usr/bin/env bash
# Офлайн-ворота проекта: те же проверки, что в CI, без обращения к кластеру.
# Использование: ./scripts/check.sh [--images]
#   --images  дополнительно собрать docker-образы приложений (медленнее)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WITH_IMAGES=0
for arg in "$@"; do
  case "${arg}" in
    --images) WITH_IMAGES=1 ;;
    -h|--help)
      sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "неизвестный флаг: ${arg} (см. --help)" ;;
  esac
done

cd "${PROJECT_ROOT}"
require_tools helm helmfile kubectl kubeconform promtool
mkdir -p "${PROJECT_ROOT}/.tmp/rendered"

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
  yamllint -d '{extends: relaxed, rules: {line-length: {max: 120}}}' "${YAML_FILES[@]}"
  printf 'проверено файлов: %d\n' "${#YAML_FILES[@]}"
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
step "helmfile template -> kubeconform"
helmfile -f helmfile.yaml template -l name=monitoring > .tmp/rendered/kps.yaml
kubeconform -strict -ignore-missing-schemas -summary -output text .tmp/rendered/kps.yaml

# --- 4. Свои манифесты: kustomize + kubeconform ------------------------------
step "kubectl kustomize . -> kubeconform"
kubectl kustomize . > .tmp/rendered/kustomize.yaml
if [ -s .tmp/rendered/kustomize.yaml ]; then
  kubeconform -strict -ignore-missing-schemas -summary -output text .tmp/rendered/kustomize.yaml
else
  SKIPPED+=("kubeconform для kustomize (resources ещё пуст: deploy/base — фаза 2, rules — фаза 3)")
fi

# --- 5. Правила Prometheus: синтаксис и юнит-тесты ---------------------------
step "promtool check rules"
shopt -s nullglob
RULE_FILES=(rules/*.yaml)
shopt -u nullglob
if [ "${#RULE_FILES[@]}" -gt 0 ]; then
  promtool check rules "${RULE_FILES[@]}"
else
  SKIPPED+=("promtool check rules (rules/*.yaml появятся в фазе 3)")
fi

step "promtool test rules"
shopt -s nullglob
RULE_TESTS=(rules/tests/*.test.yaml)
shopt -u nullglob
if [ "${#RULE_TESTS[@]}" -gt 0 ]; then
  promtool test rules "${RULE_TESTS[@]}"
else
  SKIPPED+=("promtool test rules (rules/tests появятся в фазе 3)")
fi

# --- 6. shellcheck (если установлен; в CI предустановлен) --------------------
step "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  shopt -s nullglob
  SHELL_FILES=(scripts/*.sh drills/*.sh)
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
  need_cmd docker
  shopt -s nullglob
  for dockerfile in app/*/Dockerfile; do
    app_dir="$(dirname "${dockerfile}")"
    name="$(basename "${app_dir}")"
    printf -- '--- %s\n' "${name}"
    docker build -t "${name}:check" "${app_dir}"
  done
  shopt -u nullglob
fi

# --- 8. Секреты и лабораторные адреса в трекаемых файлах --------------------
step "скан секретов и адресов"
if grep -rInE \
  --exclude-dir=.git --exclude-dir=.tools --exclude-dir=.tmp --exclude-dir=node_modules \
  --exclude='*.tar' --exclude='*.tgz' --exclude='*.gz' \
  '192\.168\.252\.|BEGIN [A-Z ]*PRIVATE KEY|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abprs]-|AKIA[0-9A-Z]{16}' \
  . ; then
  die "найдены секреты или лабораторные адреса в трекаемых файлах (см. вывод выше)"
fi

# --- Итог -------------------------------------------------------------------
printf '\nOK: все доступные проверки прошли\n'
if [ "${#SKIPPED[@]}" -gt 0 ]; then
  printf 'пропущено:\n'
  printf '  - %s\n' "${SKIPPED[@]}"
fi
