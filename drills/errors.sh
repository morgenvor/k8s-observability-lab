#!/usr/bin/env bash
# Дрилл errors: полный отказ сети на прокси toxiproxy (reset_peer).
#
# Инъекция: токсин reset_peer (toxicity 1.0) на прокси demo-api — каждое соединение
# сбрасывается, demo-load считает все запросы исходом error. Приложение живое и
# здоровое, отказ приходит снаружи — как при обрыве сети или падении балансировщика.
#
# Ожидание: доля успешных запросов падает почти до нуля, fast-burn page по доступности
# приходит примерно на 10–11-й минуте (burn_1h переваливает 14,4x на 8,6-й минуте
# отказа + for: 2m + доставка Alertmanager), затем resolved после снятия токсина.
#
# Использование: ./drills/errors.sh
# Env: EXPECT_REACTION (900 с), EXPECT_RECOVERY (600 с).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

EXPECT_REACTION="${EXPECT_REACTION:-900}"
EXPECT_RECOVERY="${EXPECT_RECOVERY:-600}"
TOXIC="errors_drill"

drill_evidence_init errors
drill_cleanup_add "снять токсин ${TOXIC} с прокси demo-api" drill_toxi_remove demo-api "${TOXIC}"
drill_preflight

event "baseline" "исходная доступность клиента"
assert_num "availability_ratio_5m_baseline" ge 0.99 \
  "$(drill_prom_value 'slo:demo_availability:ratio_5m')"

event "inject" "toxiproxy: reset_peer на прокси demo-api (все соединения сбрасываются)"
inject_epoch="$(date -u +%s)"
drill_toxi_add demo-api "${TOXIC}" reset_peer '{"timeout":0}'

# Ранняя проверка, что отказ реально дошёл до клиента (окно 5m заполняется ~5 минут,
# поэтому порог здесь грубый).
error_ratio_early="$(drill_wait_num 'slo:demo_availability:ratio_5m' le 0.5 300 || true)"
assert_num "availability_ratio_5m_early" le 0.5 "${error_ratio_early}"
# Полная доля ошибок проверяется отдельным ожиданием, а НЕ после прихода алерта: page
# может сработать раньше, если часовое окно ещё помнит предыдущий отказ (так и было
# 2026-11-05, когда дрилл шёл сразу после предыдущего).
error_ratio="$(drill_wait_num 'slo:demo_availability:ratio_5m' le 0.01 420 || true)"
assert_num "availability_ratio_5m_during_drill" le 0.01 "${error_ratio}"

wait_alert SloDemoAvailabilityBurnFast "${EXPECT_REACTION}"
assert_num "reaction_seconds" le "${EXPECT_REACTION}" "$((WAIT_ALERT_EPOCH - inject_epoch))"

event "remove" "снимаю токсин ${TOXIC}"
remove_epoch="$(date -u +%s)"
drill_toxi_remove demo-api "${TOXIC}"
wait_resolved SloDemoAvailabilityBurnFast "${EXPECT_RECOVERY}"
assert_num "recovery_seconds" le "${EXPECT_RECOVERY}" "$((WAIT_RESOLVED_EPOCH - remove_epoch))"

ratio_after="$(drill_wait_num 'slo:demo_availability:ratio_5m' ge 0.99 300 || true)"
assert_num "availability_ratio_5m_after" ge 0.99 "${ratio_after}"

event "done" "трафик восстановился, токсин снят"
# Финальный cleanup и запись evidence — в trap EXIT (drills/lib.sh).