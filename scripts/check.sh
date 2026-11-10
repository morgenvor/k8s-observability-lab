#!/usr/bin/env bash
# Офлайн-ворота проекта: те же проверки, что в CI, без обращения к кластеру.
# Использование: ./scripts/check.sh [--images] [--smoke] [--strict]
#   --images  дополнительно собрать docker-образы приложений (медленнее)
#   --smoke   плюс smoke фикстуры в docker: собрать образы и запустить их вне кластера
#   --strict  провал при любом пропуске проверки (в CI: CHECK_STRICT=1)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WITH_IMAGES=0
WITH_SMOKE=0
STRICT="${CHECK_STRICT:-0}"
for arg in "$@"; do
  case "${arg}" in
    --images) WITH_IMAGES=1 ;;
    --smoke) WITH_SMOKE=1 ;;
    --strict) STRICT=1 ;;
    -h|--help)
      sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
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
# PyYAML нужен выгрузке правил в формате promtool, подсчёту групп и ассертам в
# scripts/checks: проверяем сразу, а не трейсбеком на середине прогона.
need_pyyaml

STEP="подготовка"
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
    # --strict: предупреждение (например, длинная строка) — это провал. Без него часть
    # правил линтера фактически выключена, а «зелёный yamllint» ничего не значит.
    yamllint --strict -d '{extends: relaxed, rules: {line-length: {max: 120}}}' "${YAML_FILES[@]}"
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
# проходил бы проверку «на слово». Список релизов берётся из самого helmfile.
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
# Ассерты идут по РАСПАКОВАННОМУ конфигу: в манифесте он лежит блоком с отступом, и
# якорь `^loki.process` там не сработал бы. Почему grep по рендеру недостаточно —
# в docstring scripts/checks/alloy_config.py. Затем `alloy validate`; версия
# валидатора пинится в bootstrap-tools.sh и совпадает с образом в кластере.
step "конфиг Alloy: фильтр старых строк и alloy validate"
ALLOY_RENDERED_CONFIG="${PROJECT_ROOT}/.tmp/rendered/alloy-config/main.alloy"
mkdir -p "$(dirname "${ALLOY_RENDERED_CONFIG}")"
python3 "${PROJECT_ROOT}/scripts/checks/alloy_config.py" \
  "${PROJECT_ROOT}/.tmp/rendered/helmfile.yaml" "${ALLOY_RENDERED_CONFIG}"
# Без фильтра пересоздание пода Alloy возвращает шум "entry too far behind" (Loki
# отвечает 400 на всё старше окна приёма); цепочка drop_old обязана дойти до loki.write.
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
# Правила rules/pipeline.yaml держатся на метке job, которую задают шаблоны чартов, а
# не наши values: расхождение = тишина в алертах логов (детали — loki_metrics.py).
step "метрики Loki/Alloy и PVC Grafana в рендере"
python3 "${PROJECT_ROOT}/scripts/checks/loki_metrics.py" \
  "${PROJECT_ROOT}/.tmp/rendered/helmfile.yaml" "${PROJECT_ROOT}/rules/pipeline.yaml"

# --- 3c. Доступ к UI без port-forward: Ingress в рендере ---------------------
# UI публикуется парой: Ingress с host'ом и внешний URL/domain, который чарт из него
# выводит; проверяется согласованность пары, а не «Ingress есть» (ingress.py).
step "доступ к UI (Ingress) в рендере"
python3 "${PROJECT_ROOT}/scripts/checks/ingress.py" \
  "${PROJECT_ROOT}/.tmp/rendered/helmfile.yaml"

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
# Синтаксически валидный дашборд может ссылаться на несуществующую метрику, на чужой uid
# datasource или на namespace, который Alloy не читает: панель тогда молчит («No data»),
# и отличить поломку от тишины по экрану нельзя (scripts/checks/dashboards.py).
# Namespace берётся из отрендеренного конфига Alloy (шаг выше), а не из values: два
# парсера одного факта разошлись бы между собой.
if [ "${#DASH_FILES[@]}" -gt 0 ]; then
  python3 "${PROJECT_ROOT}/scripts/checks/dashboards.py" \
    "${PROJECT_ROOT}" "${ALLOY_RENDERED_CONFIG}"
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
# kubeconform схему AlertmanagerConfig не знает, а child-routes в CRD объявлены как
# preserve-unknown-fields: маршрут офлайн не проверяет никто, кроме этого шага.
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
python3 "${PROJECT_ROOT}/scripts/checks/route_tree.py" \
  "${ROUTE_PLAIN}" "${ROUTE_FILLED}" "${ROUTE_QUOTED}"

# --- 4d. Loki ruler: правило по логам в рендере -------------------------------
# Правило Loki читает ruler из ConfigMap: ни kubeconform, ни promtool эту цепочку не
# видят, а неверный путь тома выглядит как «логов просто нет». Последний аргумент —
# свои правила-сторожа: имя группы ruler обязано быть в их селекторах rule_group,
# иначе переименование группы тихо отключает сторожа (loki_ruler.py).
step "Loki ruler в рендере"
python3 "${PROJECT_ROOT}/scripts/checks/loki_ruler.py" \
  "${PROJECT_ROOT}/.tmp/rendered/helmfile.yaml" "${PROJECT_ROOT}/.tmp/rendered/kustomize.yaml" \
  "${PROJECT_ROOT}/rules/pipeline.yaml"
# Оверлей деплоя (scripts/lib.sh) — второй список ресурсов kustomize, и он тоже обязан
# содержать deploy/loki-rules: иначе deploy.sh применит StatefulSet с томом на
# несуществующий ConfigMap, под Loki не встанет, и встанет вся запись логов.
grep -q 'name: loki-rules' "${OVERLAY_RENDER}" \
  || die "в оверлее деплоя нет ConfigMap loki-rules — проверь список resources в scripts/lib.sh (render_demo_manifests)"

# --- 4e. Связка Alertmanager и AlertmanagerConfig -----------------------------
# Маршрут выше проверен как файл, но не как «Alertmanager его прочитает»: дефолт
# оператора (OnNamespace) молча отрезает конфиг из monitoring (alertmanager_wiring.py).
step "связка Alertmanager и AlertmanagerConfig"
python3 "${PROJECT_ROOT}/scripts/checks/alertmanager_wiring.py" \
  "${PROJECT_ROOT}/.tmp/rendered/helmfile.yaml" "${PROJECT_ROOT}/.tmp/rendered/kustomize.yaml"

# --- 4f. Размещение правил: метки, namespace, членство в kustomization --------
# Выгрузка для promtool берёт только spec.groups, поэтому метка release=monitoring,
# namespace и членство в kustomization проверяются здесь (детали — rule_placement.py).
step "размещение правил (метки, namespace, членство)"
python3 "${PROJECT_ROOT}/scripts/checks/rule_placement.py" \
  "${PROJECT_ROOT}/.tmp/rendered/helmfile.yaml" "${PROJECT_ROOT}/.tmp/rendered/kustomize.yaml" \
  "${PROJECT_ROOT}/rules" "${PROJECT_ROOT}/rules/kustomization.yaml"

# --- 4g. Паритет оверлея деплоя и kustomization.yaml --------------------------
# Два пути деплоя: `kubectl apply -k .` и scripts/deploy.sh со своим списком каталогов
# в render_demo_manifests (детали — overlay_parity.py).
step "паритет оверлея деплоя и kustomization"
python3 "${PROJECT_ROOT}/scripts/checks/overlay_parity.py" \
  "${PROJECT_ROOT}/.tmp/rendered/kustomize.yaml" "${OVERLAY_RENDER}"

# --- 5. Правила Prometheus: синтаксис и юнит-тесты ---------------------------
# promtool не читает PrometheusRule CRD, а правила обязаны быть CRD: spec.groups
# выгружается в .tmp — единственное место, где формат правил превращается в формат
# promtool; rules/tests/*.test.yaml ссылаются на выгрузку по относительному пути.
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
python3 "${PROJECT_ROOT}/scripts/checks/rulefiles.py" \
  "${RULEFILES_DIR}" "${RULE_SOURCES[@]}"

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
# runbook_url открывает браузер по абсолютному адресу: относительный путь — 404 у
# получателя, а переименованный подраздел тихо ломает ссылки (alert_links.py).
step "ссылки в алертах: runbook_url и dashboard_url"
python3 "${PROJECT_ROOT}/scripts/checks/alert_links.py" \
  "${RULEFILES_DIR}" "${PROJECT_ROOT}"

step "promtool test rules"
shopt -s nullglob
RULE_TESTS=(rules/tests/*.test.yaml)
shopt -u nullglob
if [ "${#RULE_TESTS[@]}" -gt 0 ]; then
  promtool test rules "${RULE_TESTS[@]}"
else
  SKIPPED+=("promtool test rules (rules/tests появятся в фазе 3)")
fi

# --- 5b. Покрытие правил тестами и соглашение о severity ----------------------
# promtool проверяет только те правила, для которых есть тест: новый алерт без теста
# прошёл бы молча. Опечатка в severity не ломает ни promtool, ни рендер, но уводит
# уведомление в catch-all — поэтому enum проверяется по всем правилам (rule_coverage.py).
step "покрытие правил тестами и enum severity"
python3 "${PROJECT_ROOT}/scripts/checks/rule_coverage.py" \
  "${RULEFILES_DIR}" "${PROJECT_ROOT}/rules/tests"

# --- 5c. Поведение дриллов (offline): сигналы и cleanup ----------------------
# Регресс на «passed без дрилла»: доказательство — JSON с result: passed, и его не
# должно быть у прерванного прогона или при сбое cleanup. Кластер не нужен.
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

# --- 7b. Smoke фикстуры без кластера (по флагу) ------------------------------
# Закрывает разрыв «собралось ≠ запускается»: `npm test` идёт по исходникам, а сломанный
# CMD, порт или env видны только при запуске контейнера. Скрипт тот же, что для ручного
# прогона; пропуска нет — флаг просят явно, поэтому нет docker = провал.
if [ "${WITH_SMOKE}" -eq 1 ]; then
  step "smoke фикстуры в docker"
  need_cmd docker
  bash "${PROJECT_ROOT}/scripts/smoke-local.sh"
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
# Что ловим: приватные сети и pod CIDR, ключи и токены, имена нод и следы лаборатории
# в тексте. Шаблоны 10.x не обобщаем (широкий регэксп падал бы на версиях в чужих
# values), а часть слов набрана классом символов (prox[m]ox, par[r]ot): иначе скан
# находит сам себя в этом файле.
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
# Правило 4 AGENTS: реальный адрес получателя — такой же секрет, как IP стенда; в
# публикуемом наборе допустимы только example.invalid/example.com (address_scan.py).
step "скан личных адресов"
python3 "${PROJECT_ROOT}/scripts/checks/address_scan.py" "${SCAN_FILES[@]}"

# --- Итог -------------------------------------------------------------------
if [ "${#SKIPPED[@]}" -gt 0 ]; then
  printf '\nпропущено:\n'
  printf '  - %s\n' "${SKIPPED[@]}"
  if [ "${STRICT}" -eq 1 ]; then
    die "строгий режим (--strict/CHECK_STRICT=1): проверок пропущено ${#SKIPPED[@]} — зелёный результат без них недостоверен"
  fi
fi
printf '\nOK: все доступные проверки прошли\n'

