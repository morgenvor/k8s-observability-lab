#!/usr/bin/env bash
# Доставка демо-контура в k3s лабы: рендер kustomize с тегами образов и один apply.
# Живое действие: создаёт namespace demo и объекты в monitoring (дашборды и
# PrometheusRule с правилами SLI/SLO, инфраструктурными и мета-алертами).
# Использование: ./scripts/deploy.sh
# Env: IMAGE_TAG (иначе короткий git SHA), KUBECONFIG (иначе kubeconfig лабы),
#      WAIT_TARGETS (секунды ожидания targets, по умолчанию 180),
#      ALERT_EMAIL_TO/ALERT_EMAIL_FROM/SMTP_SMARTHOST/SMTP_USERNAME (адреса и SMTP
#      для ветки e-mail; без них в маршруте останутся плейсхолдеры example.invalid),
#      ALERT_EMAIL_ALLOW_PLACEHOLDER=1 (явно разрешить заменить живые адреса
#      плейсхолдерами — по умолчанию такой деплой останавливается)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cd "${PROJECT_ROOT}"
require_cluster
need_cmd curl
need_cmd docker
need_cmd git
# PyYAML нужен гейту активного конфига Alertmanager: он разбирает /api/v2/status.
need_pyyaml

TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD 2>/dev/null)}"
[ -n "${TAG}" ] || die "не удалось определить тег: нет git-репозитория? задай IMAGE_TAG"
WAIT_TARGETS="${WAIT_TARGETS:-180}"
case "${WAIT_TARGETS}" in
  ''|*[!0-9]*) die "WAIT_TARGETS='${WAIT_TARGETS}' не число секунд (ожидается целое, например 180)" ;;
esac

# Маршрут v1.1: page|critical уходит письмом. В git лежат плейсхолдеры example.invalid,
# поэтому деплой без env оставил бы доставку человеку нерабочей — сообщаем заранее, чтобы
# «письма не приходят» не искали под чайником в Alertmanager.
EMAIL_UNSET=()
for email_var in ALERT_EMAIL_TO ALERT_EMAIL_FROM SMTP_SMARTHOST SMTP_USERNAME; do
  [ -n "${!email_var:-}" ] || EMAIL_UNSET+=("${email_var}")
done
if [ "${#EMAIL_UNSET[@]}" -gt 0 ]; then
  warn "не заданы ${EMAIL_UNSET[*]}: если в кластере живых адресов нет, в маршруте останутся плейсхолдеры example.invalid (см. docs/runbook.md, «E-mail (SMTP)»)"
fi
# Secret с паролем приложения обязан существовать ДО apply — при любом наборе env:
# emailConfigs ссылается на него через authPassword даже когда в маршруте плейсхолдеры.
# Без Secret оператор не соберёт конфиг Alertmanager: правка маршрута не применится,
# а снаружи всё выглядит здоровым, потому что старый конфиг продолжает работать.
kubectl -n monitoring get secret alertmanager-smtp >/dev/null 2>&1 \
  || die "нет Secret monitoring/alertmanager-smtp — сначала создай его (порядок важен: Secret -> конфиг): kubectl -n monitoring create secret generic alertmanager-smtp --from-literal=smtp-password=<пароль-приложения>"

# Тег = git SHA, поэтому после нового коммита старых образов для деплоя уже нет.
# Без этой проверки apply прошёл бы, а поды ушли в ImagePullBackOff (registry нет).
shopt -s nullglob
for dockerfile in app/*/Dockerfile; do
  image_name="$(basename "$(dirname "${dockerfile}")"):${TAG}"
  docker image inspect "${image_name}" >/dev/null 2>&1 \
    || die "нет локального образа ${image_name}: сначала ./scripts/build-image.sh и ./scripts/import-image.sh (тег = short SHA коммита)"
done
shopt -u nullglob

info "рендер манифестов (тег ${TAG})"
RENDERED="$(render_demo_manifests "${TAG}")"

# apply декларативен: деплой без e-mail env заменил бы ЖИВЫЕ адреса плейсхолдерами
# example.invalid. Конфиг остался бы валидным, гейты зелёными, а письма человеку
# перестали бы приходить — тихая поломка paging-пути. Поэтому сравниваем рендер с тем,
# что уже стоит в кластере: живое значение, которое не задано в env, — повод остановиться.
# Осознанный переход на плейсхолдеры (например, при сносе ветки) разрешается явно:
# ALERT_EMAIL_ALLOW_PLACEHOLDER=1.
live_email_field() {
  kubectl -n monitoring get alertmanagerconfig demo-notifications \
    -o jsonpath="{.spec.receivers[1].emailConfigs[0].$1}" 2>/dev/null || true
}
if [ "${ALERT_EMAIL_ALLOW_PLACEHOLDER:-0}" != "1" ]; then
  PLACEHOLDER_DOWNGRADED=()
  for email_pair in "to:ALERT_EMAIL_TO" "from:ALERT_EMAIL_FROM" \
      "smarthost:SMTP_SMARTHOST" "authUsername:SMTP_USERNAME"; do
    email_field="${email_pair%%:*}"
    email_env="${email_pair#*:}"
    if [ -n "${!email_env:-}" ]; then
      continue
    fi
    live_value="$(live_email_field "${email_field}")"
    if [ -z "${live_value}" ]; then
      continue
    fi
    case "${live_value}" in
      *example.invalid*) continue ;;
    esac
    PLACEHOLDER_DOWNGRADED+=("${email_field}")
  done
  [ "${#PLACEHOLDER_DOWNGRADED[@]}" -eq 0 ] \
    || die "в кластере живые значения полей ${PLACEHOLDER_DOWNGRADED[*]}, а env для них не задан: apply заменил бы их плейсхолдерами example.invalid и письма по page|critical перестали бы приходить. Задай ALERT_EMAIL_TO/ALERT_EMAIL_FROM/SMTP_SMARTHOST/SMTP_USERNAME (docs/runbook.md, «E-mail (SMTP)») или подтверди намерение явно: ALERT_EMAIL_ALLOW_PLACEHOLDER=1"
fi

info "kubectl apply (namespace demo + демо-объекты + дашборды и правила в monitoring)"
kubectl apply -f "${RENDERED}"

info "ожидание rollout"
kubectl -n demo rollout status deploy/demo-api --timeout=180s
kubectl -n demo rollout status deploy/demo-load --timeout=180s
kubectl -n demo rollout status deploy/alert-sink --timeout=180s
kubectl -n demo rollout status deploy/toxiproxy --timeout=180s

info "состояние подов и ServiceMonitor"
kubectl -n demo get pods -o wide
kubectl -n demo get servicemonitor

# Проверка целей в Prometheus: порт-форвард на сервис и PromQL.
PROM_SVC="monitoring-kube-prometheus-prometheus"
PROM_PORT="${PROM_PORT:-19090}"
kubectl -n monitoring port-forward "svc/${PROM_SVC}" "${PROM_PORT}:9090" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "${PF_PID}" >/dev/null 2>&1 || true' EXIT

# Порт-форвард поднимается не мгновенно, поэтому любая неудача curl — это «данных пока
# нет», а не повод падать: решение принимает петля ожидания ниже.
prom_scalar() { # $1 — PromQL; печатает значение единственной серии или пусто
  curl -sf -G "http://127.0.0.1:${PROM_PORT}/api/v1/query" \
    --data-urlencode "query=$1" 2>/dev/null \
    | sed -n 's/.*"value":\[[0-9.eE+-]*,"\([^"]*\)"\].*/\1/p' || true
}

info "ожидание порт-форварда к Prometheus"
forward_ready=0
for _ in $(seq 1 30); do
  if curl -sf -G "http://127.0.0.1:${PROM_PORT}/api/v1/query" \
      --data-urlencode 'query=vector(1)' >/dev/null 2>&1; then
    forward_ready=1
    break
  fi
  sleep 1
done
[ "${forward_ready}" -eq 1 ] || die "порт-форвард к Prometheus не поднялся на 127.0.0.1:${PROM_PORT}"

# Гейт проверяет четыре вещи по отдельности, а не «сколько-то целей живы»:
#  1) оба эндпоинта demo-api (2 реплики) скрейпятся;
#  2) demo-load скрейпится (иначе пропажа его ServiceMonitor прошла бы незамеченной);
#  3) alert-sink скрейпится: без этой проверки пропажа ServiceMonitor/alert-sink
#     оставила бы метрики доставки только в самом сервисе;
#  4) нагрузка реально доходит до demo-api — up=1 ничего не говорит о работоспособности
#     пути demo-load → toxiproxy → demo-api (инцидент с конфигом toxiproxy 2026-11-03
#     давал up=1 при 100 % ошибок у клиента).
info "ожидание целей и живого трафика (до ${WAIT_TARGETS} с)"
deadline=$((SECONDS + WAIT_TARGETS))
api_up=""; load_up=""; sink_up=""; ok_rate=""
while [ "${SECONDS}" -lt "${deadline}" ]; do
  api_up="$(prom_scalar 'count(up{job="demo-api"} == 1)')"
  load_up="$(prom_scalar 'count(up{job="demo-load"} == 1)')"
  sink_up="$(prom_scalar 'count(up{job="alert-sink"} == 1)')"
  ok_rate="$(prom_scalar 'sum(rate(load_requests_total{outcome="ok"}[2m]))')"
  if [ "${api_up:-0}" -ge 2 ] && [ "${load_up:-0}" -ge 1 ] && [ "${sink_up:-0}" -ge 1 ] \
      && awk -v a="${ok_rate:-0}" 'BEGIN{exit !(a > 0)}'; then
    break
  fi
  sleep 5
done

[ "${api_up:-0}" -ge 2 ] || die "demo-api: up==1 у ${api_up:-0} эндпоинтов (нужно 2); проверь поды и ServiceMonitor (метка release=monitoring)"
[ "${load_up:-0}" -ge 1 ] || die "demo-load: up==1 у ${load_up:-0} целей (нужно 1); проверь ServiceMonitor/demo-load"
[ "${sink_up:-0}" -ge 1 ] || die "alert-sink: up==1 у ${sink_up:-0} целей (нужно 1); проверь ServiceMonitor/alert-sink и под alert-sink"
awk -v a="${ok_rate:-0}" 'BEGIN{exit !(a > 0)}' \
  || die "нагрузка не доходит до demo-api: rate(load_requests_total{outcome=\"ok\"}) = ${ok_rate:-0}; проверь toxiproxy (прокси demo-api:12001 → demo-api:8080) и TARGET_URL"
info "цели живы (demo-api ${api_up}, demo-load ${load_up}, alert-sink ${sink_up}), ok-трафик ${ok_rate} rps"

# Гейт «маршрут действительно активен». Одного `alertmanager_config_last_reload_successful
# == 1` мало: значение остаётся 1 от ПРЕДЫДУЩЕГО успешного reload, поэтому проверка
# проходит и тогда, когда оператор не смог собрать новый конфиг (например, нет Secret) —
# а доставка при этом идёт по старому маршруту. Настоящее доказательство — активный конфиг
# самого Alertmanager (/api/v2/status): в нём должен быть получатель …/email с теми
# адресами и smarthost, которые мы только что применили. Сравнение печатает только имена
# полей: в конфиге лежит пароль приложения, выводить его нельзя.
info "гейт: маршрут активен в Alertmanager (до 60 с)"
AM_SVC="monitoring-kube-prometheus-alertmanager"
AM_PORT="${AM_PORT:-19093}"
kubectl -n monitoring port-forward "svc/${AM_SVC}" "${AM_PORT}:9093" >/dev/null 2>&1 &
AM_PF_PID=$!
trap 'kill "${PF_PID}" "${AM_PF_PID}" >/dev/null 2>&1 || true' EXIT

EXPECT_TO="${ALERT_EMAIL_TO:-alerts@example.invalid}"
EXPECT_FROM="${ALERT_EMAIL_FROM:-alertmanager@example.invalid}"
EXPECT_HOST="${SMTP_SMARTHOST:-smtp.example.invalid:587}"
EXPECT_USER="${SMTP_USERNAME:-alertmanager}"
route_active=0
route_deadline=$((SECONDS + 60))
while [ "${SECONDS}" -lt "${route_deadline}" ]; do
  if curl -sf "http://127.0.0.1:${AM_PORT}/api/v2/status" 2>/dev/null \
      | python3 -c '
import json
import sys

import yaml

want = {
    "to": sys.argv[1],
    "from": sys.argv[2],
    "smarthost": sys.argv[3],
    "authUsername": sys.argv[4],
}
try:
    status = json.load(sys.stdin)
    config = yaml.safe_load(status["config"]["original"])
except (KeyError, ValueError, yaml.YAMLError):
    sys.exit(2)
for receiver in config.get("receivers") or []:
    if not str(receiver.get("name", "")).endswith("/email"):
        continue
    email = (receiver.get("email_configs") or [{}])[0]
    actual = {
        "to": email.get("to"),
        "from": email.get("from"),
        "smarthost": email.get("smarthost"),
        "authUsername": email.get("auth_username"),
    }
    mismatched = [key for key, value in want.items() if actual.get(key) != value]
    if mismatched:
        print(", ".join(mismatched), file=sys.stderr)
        sys.exit(1)
    sys.exit(0)
print("/email", file=sys.stderr)
sys.exit(1)
' "${EXPECT_TO}" "${EXPECT_FROM}" "${EXPECT_HOST}" "${EXPECT_USER}" 2>/dev/null; then
    route_active=1
    break
  fi
  sleep 5
done
[ "${route_active}" = "1" ] \
  || die "активный конфиг Alertmanager не совпал с применённым (получатель /email или поля из env). Оператор мог не пересобрать конфиг — проверь 'kubectl -n monitoring get alertmanagerconfig demo-notifications', Secret alertmanager-smtp и лог Alertmanager; gzip-конфиг лежит в secret ...-generated (не печатай его: там пароль)"
# Метрика reload — второй, дешёвый признак: 0 означает, что Alertmanager отверг конфиг.
# Скрейп Prometheus приходит с задержкой, поэтому ждём отдельно и недолго.
reload_ok=""
reload_deadline=$((SECONDS + 60))
while [ "${SECONDS}" -lt "${reload_deadline}" ]; do
  reload_ok="$(prom_scalar 'min(alertmanager_config_last_reload_successful{job="monitoring-kube-prometheus-alertmanager"})')"
  if [ "${reload_ok:-0}" = "1" ]; then
    break
  fi
  sleep 5
done
[ "${reload_ok:-0}" = "1" ] \
  || die "alertmanager_config_last_reload_successful=${reload_ok:-нет данных}: reload конфига Alertmanager неуспешен (доставка идёт по старому конфигу)"
info "маршрут активен: получатель /email с применёнными адресами, reload успешен"

# Правила приезжают тем же apply, но подхватывает их оператор: без этой проверки
# PrometheusRule без метки release=monitoring или с падающей группой доехал бы
# молча — цели остались бы up=1, а правил бы не было. Проверяются ВСЕ группы
# проекта (метрика Prometheus про загруженные группы), а не только записанные серии:
# иначе отсутствие demo-slo-alerts/demo-infra/demo-meta прошло бы незамеченным.
# Ожидаемое число выводится из rules/*.yaml (scripts/lib.sh: expected_rule_groups):
# состав правил меняется в одном месте, число руками не правится. Переопределить
# можно через RULE_GROUPS_EXPECTED (например, при разборе инцидента).
RULE_GROUPS_EXPECTED="${RULE_GROUPS_EXPECTED:-$(expected_rule_groups)}"
info "ожидание правил проекта в Prometheus (до 120 с, групп: ${RULE_GROUPS_EXPECTED})"
rules_deadline=$((SECONDS + 120))
groups=""
while [ "${SECONDS}" -lt "${rules_deadline}" ]; do
  groups="$(prom_scalar 'count(prometheus_rule_group_rules{rule_group=~".*;demo-.*"})')"
  if [ "${groups:-0}" -ge "${RULE_GROUPS_EXPECTED}" ]; then
    break
  fi
  sleep 5
done
if [ "${groups:-0}" -ne "${RULE_GROUPS_EXPECTED}" ]; then
  warn "группы правил проекта в Prometheus:"
  curl -sf -G "http://127.0.0.1:${PROM_PORT}/api/v1/query" \
    --data-urlencode 'query=count by (rule_group) (prometheus_rule_group_rules{rule_group=~".*;demo-.*"})' \
    | sed -n 's/.*"rule_group":"\([^"]*\)".*/  - \1/p' || true
  die "правил проекта ${groups:-0} групп, ожидалось ${RULE_GROUPS_EXPECTED}: PrometheusRule не подхватились (метка release=monitoring?) или группа упала — смотри /api/v1/rules и поле lastError"
fi
info "правила проекта загружены: групп ${groups} (ожидалось ${RULE_GROUPS_EXPECTED})"

# Селектор сторожа SloAlertRulesAbsent (rules/meta.yaml) смотрит на группы по
# хвосту метки rule_group («<путь к файлу>;<имя группы>»). Если формат метки в этой
# версии Prometheus другой, absent() будет истинным всегда и правило загорится
# ложно — это проверяется ДО деплоя правила одним запросом, а не ожиданием 10 минут:
# при совпадении селектора absent() не может быть истинным. Отдельная живая проверка
# «ALERTS{...} пусто через 10 минут» — в docs/runbook.md (проверка после деплоя).
selector_groups="$(prom_scalar 'count(prometheus_rule_group_rules{rule_group=~".*;demo-slo[.]alerts[.](availability|latency)"})')"
[ "${selector_groups:-0}" = "2" ] \
  || die "селектор SloAlertRulesAbsent видит ${selector_groups:-0} групп из 2: формат метки rule_group не совпал с выражением в rules/meta.yaml — правило загорится ложно; проверь prometheus_rule_group_rules в /api/v1/query"
pending_alerts="$(prom_scalar 'count(ALERTS{alertname="SloAlertRulesAbsent"}) or vector(0)')"
[ "${pending_alerts:-0}" = "0" ] \
  || die "SloAlertRulesAbsent уже в ALERTS: правило считает группы отсутствующими — не деплой, сначала разберись с rule_group"
info "сторож групп burn-rate: селектор находит 2 группы, ложных ALERTS нет"

info "проверка записанных серий SLI"
av="$(prom_scalar 'count(slo:demo_availability:ratio_5m) or vector(0)')"
lat="$(prom_scalar 'count(slo:demo_latency:ratio_5m) or vector(0)')"
[ "${av:-0}" = "1" ] \
  || die "серии slo:demo_availability:ratio_5m нет, хотя группа loaded: проверь выражение записи в rules/demo-slo.yaml"
[ "${lat:-0}" = "1" ] \
  || die "серии slo:demo_latency:ratio_5m нет, хотя группа loaded: проверь выражение записи в rules/demo-slo.yaml"
info "серии SLI пишутся (availability и latency)"

info "headroom нод"
kubectl top nodes || warn "kubectl top недоступен (metrics-server?), проверь вручную"
