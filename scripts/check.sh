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
step "helmfile template -> kubeconform"
helmfile -f helmfile.yaml template -l name=monitoring > .tmp/rendered/kps.yaml
kubeconform -strict -ignore-missing-schemas -summary -output text .tmp/rendered/kps.yaml

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
need_cmd python3
# PyYAML без объявления приезжает транзитивно с yamllint; проверяем явно, иначе
# шаг падал бы трейсбеком ModuleNotFoundError вместо понятного сообщения.
python3 -c 'import yaml' 2>/dev/null \
  || die "нет модуля PyYAML для выгрузки правил (python3 -m pip install pyyaml)"
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
mapfile -d '' -t SCAN_FILES < <(git ls-files -z --cached --others --exclude-standard)
if [ "${#SCAN_FILES[@]}" -eq 0 ]; then
  SKIPPED+=("скан секретов (git не видит файлов)")
elif grep -nIE \
  '192\.168\.252\.|BEGIN [A-Z ]*PRIVATE KEY|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abprs]-|AKIA[0-9A-Z]{16}|k8s[-]server|k8s[-]agent' \
  -- "${SCAN_FILES[@]}" ; then
  die "найдены секреты, адреса или hostname лабы в файлах, которые попадут в git"
fi

# --- Итог -------------------------------------------------------------------
printf '\nOK: все доступные проверки прошли\n'
if [ "${#SKIPPED[@]}" -gt 0 ]; then
  printf 'пропущено:\n'
  printf '  - %s\n' "${SKIPPED[@]}"
fi
