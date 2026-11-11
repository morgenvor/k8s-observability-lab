#!/usr/bin/env bash
# Дрилл latency: задержка сети на прокси toxiproxy (снаружи приложения, код не меняется).
#
# Инъекция: токсин latency 400 мс ± 50 мс на прокси demo-api. demo-load видит это как
# рост клиентской латентности: запросы остаются успешными (timeout 1 с не превышен),
# поэтому деградирует ТОЛЬКО latency SLI, а доступность остаётся здоровой.
#
# Ожидание: fast-burn page по латентности. Длинное окно алерта — 30m, поэтому условие
# выполняется примерно на 22-й минуте (ratio_30m опускается ниже 0,28 при бюджете 5 %),
# а с `for: 2m` и доставкой реакция ~26 минут (измерено 2026-11-05). Держим инъекцию до
# фактического прихода уведомления, а не 12 минут.
#
# Использование: ./drills/latency.sh
# Env: LATENCY_MS (400), JITTER_MS (50), EXPECT_REACTION (1800 с), EXPECT_RECOVERY (600 с).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

LATENCY_MS="${LATENCY_MS:-400}"
JITTER_MS="${JITTER_MS:-50}"
EXPECT_REACTION="${EXPECT_REACTION:-1800}"
EXPECT_RECOVERY="${EXPECT_RECOVERY:-600}"
# Значения уходят в JSON токсина и в арифметику таймаутов: «400мс» или пустая строка
# дали бы либо невалидный payload, либо мгновенный/вечный дрилл. Та же проверка, что
# в drills/oomkill.sh.
for var in LATENCY_MS JITTER_MS EXPECT_REACTION EXPECT_RECOVERY; do
  case "${!var}" in
    ''|*[!0-9]*) die "${var}='${!var}' не целое положительное число" ;;
  esac
  [ "${!var}" -gt 0 ] || die "${var} должен быть больше нуля (получено '${!var}')"
done
TOXIC="latency_drill"

drill_evidence_init latency
drill_cleanup_add "снять токсин ${TOXIC} с прокси demo-api" drill_toxi_remove demo-api "${TOXIC}"
drill_preflight

event "baseline" "исходная латентность клиента (p95 за 5m)"
p95_before="$(drill_prom_value 'histogram_quantile(0.95, sum(rate(load_request_duration_seconds_bucket{job="demo-load"}[5m])) by (le))')"
assert_num "baseline_p95_seconds" le 0.3 "${p95_before}"

event "inject" "toxiproxy: latency ${LATENCY_MS} мс ± ${JITTER_MS} мс на прокси demo-api"
inject_epoch="$(date -u +%s)"
drill_toxi_add demo-api "${TOXIC}" latency "{\"latency\":${LATENCY_MS},\"jitter\":${JITTER_MS}}"

wait_alert SloDemoLatencyBurnFast "${EXPECT_REACTION}"
reaction=$((WAIT_ALERT_EPOCH - inject_epoch))
# gt 0 ловит ложное совпадение: /timeline помнит прошлый дрилл, а допуск на расхождение
# часов (±120 с) иначе мог бы засчитать чужое уведомление (нашло ревью 2026-11-06).
assert_num "reaction_seconds_positive" gt 0 "${reaction}"
assert_num "reaction_seconds" le "${EXPECT_REACTION}" "${reaction}"

event "check" "сверяю метрики клиента, пока инъекция держится"
p95_during="$(drill_prom_value 'histogram_quantile(0.95, sum(rate(load_request_duration_seconds_bucket{job="demo-load"}[5m])) by (le))')"
assert_num "client_p95_seconds_during_drill" gt 0.3 "${p95_during}"
assert_num "latency_ratio_5m_during_drill" lt 0.5 "$(drill_prom_value 'slo:demo_latency:ratio_5m')"
# Запросы укладываются в клиентский timeout 1 с: если бы нет, деградировала бы и
# доступность, и дрилл перестал бы быть дриллом одной SLI.
assert_num "availability_ratio_5m_during_drill" ge 0.99 \
  "$(drill_prom_value 'slo:demo_availability:ratio_5m')"

event "remove" "снимаю токсин ${TOXIC}"
remove_epoch="$(date -u +%s)"
drill_toxi_remove demo-api "${TOXIC}"
wait_resolved SloDemoLatencyBurnFast "${EXPECT_RECOVERY}"
recovery=$((WAIT_RESOLVED_EPOCH - remove_epoch))
assert_num "recovery_seconds_positive" gt 0 "${recovery}"
assert_num "recovery_seconds" le "${EXPECT_RECOVERY}" "${recovery}"

ratio_after="$(drill_wait_num 'slo:demo_latency:ratio_5m' ge 0.95 300 || true)"
assert_num "latency_ratio_5m_after" ge 0.95 "${ratio_after}"
p95_after="$(drill_wait_num 'histogram_quantile(0.95, sum(rate(load_request_duration_seconds_bucket{job="demo-load"}[5m])) by (le))' le 0.3 300 || true)"
assert_num "client_p95_seconds_after" le 0.3 "${p95_after}"

event "done" "латентность восстановилась, токсин снят"
# Финальный cleanup и запись evidence — в trap EXIT (drills/lib.sh).
