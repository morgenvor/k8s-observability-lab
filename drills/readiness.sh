#!/usr/bin/env bash
# Дрилл readiness: сломанная readiness-проба выводит поды из endpoints.
#
# Инъекция: readinessProbe.demo-api.httpGet.path = /nope (правка деплоймента).
#
# Почему после правки пробы поды приходится пересоздавать (масштабирование 0 → 2):
# стратегия деплоймента по умолчанию — RollingUpdate с maxUnavailable 0 и maxSurge 1.
# Новый ReplicaSet с плохой пробой создаёт один под, который так и не становится
# Ready, а старые поды с исправной пробой продолжают обслуживать трафик — endpoints
# не пустеют, и
# «дрилл» ничего бы не деградировал. Поэтому после правки пробы поды снимаются, а
# новые стартуют уже с /nope: они Running, но NotReady, endpoints пустеют, demo-load
# видит ошибки. Само maxUnavailable=0 — находка дрилла, а не повод менять спеку.
#
# Ожидание: под Ready=False, у Service demo-api ноль ready-адресов, клиентская
# доступность падает, fast-burn page по доступности приходит; после отката пробы
# endpoints и трафик восстанавливаются, спека деплоймента возвращается к исходной.
#
# Время реакции здесь больше, чем у дрилла errors (там page ~11 минут): пустые
# endpoints не отвергают соединения, а дропают пакеты, поэтому клиент уходит в свой
# timeout 1 с, общий rps падает с 4,7 до 1,9, и ratio_1h опускается вдвое медленнее.
# Измерено 2026-11-05 (чистое часовое окно на старте, `ratio_1h` 0,992): 1160 с
# (19,3 мин). Первая попытка дала 1099 с и не прошла порог 900 с — именно она была
# поводом поднять `EXPECT_REACTION` и объяснить причину.
#
# Использование: ./drills/readiness.sh
# Env: EXPECT_REACTION (1500 с), EXPECT_RECOVERY (600 с).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

EXPECT_REACTION="${EXPECT_REACTION:-1500}"
EXPECT_RECOVERY="${EXPECT_RECOVERY:-600}"

drill_evidence_init readiness
drill_preflight

# --- helpers ----------------------------------------------------------------
endpoint_ready_count() {
  kubectl -n "${DEMO_NS}" get endpointslices -l kubernetes.io/service-name=demo-api -o json \
    | jq '[.items[].endpoints[]? | select(.conditions.ready == true)] | length'
}

pods_not_ready_count() {
  kubectl -n "${DEMO_NS}" get pods -l app=demo-api -o json \
    | jq '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "False"))] | length'
}

demo_api_pods() {
  kubectl -n "${DEMO_NS}" get pods -l app=demo-api --no-headers 2>/dev/null | wc -l
}

probe_path() {
  kubectl -n "${DEMO_NS}" get deploy demo-api \
    -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}'
}

scale_to() {
  kubectl -n "${DEMO_NS}" scale deploy demo-api --replicas="$1" >/dev/null
}

# Опрос условия до таймаута: первым аргументом секунды, дальше — команда-проверка.
wait_until() { # <timeout_seconds> <команда...>
  local deadline=$((SECONDS + $1))
  shift
  while [ "${SECONDS}" -lt "${deadline}" ]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 5
  done
  return 1
}

pods_not_ready_at_least() { [ "$(pods_not_ready_count)" -ge "$1" ]; }
endpoints_ready_at_least() { [ "$(endpoint_ready_count)" -ge "$1" ]; }
endpoints_ready_exactly() { [ "$(endpoint_ready_count)" -eq "$1" ]; }
no_demo_api_pods() { [ "$(demo_api_pods)" -eq 0 ]; }

restore_spec() { # снимает инъекцию: проба и число реплик как до дрилла
  kubectl -n "${DEMO_NS}" patch deploy demo-api --type=json -p \
    "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/readinessProbe/httpGet/path\",\"value\":\"${PROBE_PATH_ORIGINAL}\"}]" \
    >/dev/null 2>&1 || true
  scale_to "${REPLICAS_ORIGINAL}"
  # Откат обязан быть проверяемым: patch мог не примениться, и тогда стенд остался бы
  # с /nope после «успешного» cleanup. В успешном пути это дублирует assert_eq ниже,
  # в аварийном (cleanup после падения) — единственная проверка.
  local restored
  restored="$(probe_path 2>/dev/null || true)"
  if [ "${restored}" != "${PROBE_PATH_ORIGINAL}" ]; then
    warn "readinessProbe не восстановилась: сейчас '${restored}', ожидалось '${PROBE_PATH_ORIGINAL}'"
    # shellcheck disable=SC2034  # флаг читает drill_cleanup/evidence в drills/lib.sh
    DRILL_FAILED=1
    return 1
  fi
}

# --- исходное состояние -----------------------------------------------------
event "baseline" "фиксирую пробу, число реплик и ready-адреса"
PROBE_PATH_ORIGINAL="$(probe_path)"
REPLICAS_ORIGINAL="$(kubectl -n "${DEMO_NS}" get deploy demo-api -o jsonpath='{.spec.replicas}')"
assert_eq "readiness_probe_path_baseline" "/ready" "${PROBE_PATH_ORIGINAL}"
assert_eq "endpoints_ready_baseline" "2" "$(endpoint_ready_count)"

drill_cleanup_add \
  "вернуть readinessProbe ${PROBE_PATH_ORIGINAL} и ${REPLICAS_ORIGINAL} реплики" restore_spec

# --- инъекция ---------------------------------------------------------------
event "inject" "readinessProbe.demo-api.httpGet.path = /nope"
kubectl -n "${DEMO_NS}" patch deploy demo-api --type=json -p \
  '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/nope"}]' \
  >/dev/null
inject_epoch="$(date -u +%s)"

event "adopt" "пересоздаю поды, чтобы шаблон с плохой пробой реально применился"
scale_to 0
wait_until 120 no_demo_api_pods || die "поды demo-api не удалились за 120 с"
scale_to "${REPLICAS_ORIGINAL}"

event "wait_not_ready" "жду под demo-api в состоянии Ready=False"
wait_until 180 pods_not_ready_at_least 2 || true
assert_num "pods_not_ready_during_drill" ge 2 "$(pods_not_ready_count)"

event "wait_endpoints" "жду ноль ready-адресов у Service demo-api"
wait_until 120 endpoints_ready_exactly 0 || true
assert_eq "endpoints_ready_during_drill" "0" "$(endpoint_ready_count)"

event "wait_client_errors" "жду, пока клиентская доступность упадёт"
error_ratio_early="$(drill_wait_num 'slo:demo_availability:ratio_5m' le 0.5 300 || true)"
assert_num "availability_ratio_5m_early" le 0.5 "${error_ratio_early}"
# Полная доля ошибок — отдельным ожиданием, а не после прихода алерта: page может
# сработать раньше, если часовое окно ещё помнит предыдущий отказ (проверено 2026-11-05).
error_ratio="$(drill_wait_num 'slo:demo_availability:ratio_5m' le 0.01 420 || true)"
assert_num "availability_ratio_5m_during_drill" le 0.01 "${error_ratio}"

wait_alert SloDemoAvailabilityBurnFast "${EXPECT_REACTION}"
reaction=$((WAIT_ALERT_EPOCH - inject_epoch))
# gt 0 ловит ложное совпадение: /timeline помнит прошлый дрилл, а допуск на расхождение
# часов (±120 с) иначе мог бы засчитать чужое уведомление (нашло ревью 2026-11-06).
assert_num "reaction_seconds_positive" gt 0 "${reaction}"
assert_num "reaction_seconds" le "${EXPECT_REACTION}" "${reaction}"

# --- восстановление ---------------------------------------------------------
event "restore" "возвращаю readinessProbe ${PROBE_PATH_ORIGINAL}"
remove_epoch="$(date -u +%s)"
restore_spec

wait_until 300 endpoints_ready_at_least 2 || true
assert_num "endpoints_ready_after" ge 2 "$(endpoint_ready_count)"
wait_resolved SloDemoAvailabilityBurnFast "${EXPECT_RECOVERY}"
recovery=$((WAIT_RESOLVED_EPOCH - remove_epoch))
assert_num "recovery_seconds_positive" gt 0 "${recovery}"
assert_num "recovery_seconds" le "${EXPECT_RECOVERY}" "${recovery}"

ratio_after="$(drill_wait_num 'slo:demo_availability:ratio_5m' ge 0.99 300 || true)"
assert_num "availability_ratio_5m_after" ge 0.99 "${ratio_after}"

event "verify_spec" "сверяю спеку деплоймента с состоянием до дрилла"
assert_eq "readiness_probe_path_after" "${PROBE_PATH_ORIGINAL}" "$(probe_path)"
assert_eq "replicas_after" "${REPLICAS_ORIGINAL}" \
  "$(kubectl -n "${DEMO_NS}" get deploy demo-api -o jsonpath='{.spec.replicas}')"

event "done" "endpoints и трафик восстановлены, спека как до дрилла"
# Финальный cleanup и запись evidence — в trap EXIT (drills/lib.sh).
