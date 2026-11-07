#!/usr/bin/env bash
# Дрилл oomkill: контейнер demo-api убит OOM внутри лимита памяти.
#
# Инъекция: kubectl exec в под demo-api и запись в буфер размером больше лимита
# (200 MiB при лимите 128Mi). cgroup-лимит достигается на записи в страницы, после
# чего `memory.oom.group=1` в pod-cgroup убивает весь cgroup: контейнер завершается
# с OOMKilled (exit 137), kubelet его перезапускает. Спеку и лимиты не меняем —
# дрейфа манифестов после дрилла быть не должно.
#
# Проверено 2026-11-05: одного `Buffer.alloc(200 MiB)` НЕ достаточно — выделение идёт
# через calloc/mmap, страницы не трогаются, RSS не растёт, cgroup-OOM не наступает
# (exec вернул 0, рестарта не было). Нужна запись: `b.fill(1)`.
#
# Ожидание: у пода lastState.terminated.reason=OOMKilled, алерт KubePodOOMKilled
# (for: 1m) в alert-sink, под снова Ready, .spec деплоймента не изменился.
# Resolved у этого алерта не ждём: KSM отдаёт ПОСЛЕДНЕЕ завершение контейнера, и
# правило остаётся firing, пока контейнер не завершится по другой причине
# (shortcut зафиксирован в rules/infra.yaml). Это ограничение метрики, а не дрилла.
#
# Из того же ограничения — шаг `reset`: перед инъекцией поды с прошлым OOMKilled
# удаляются, иначе алерт уже firing, нового уведомления в /timeline не будет
# (repeat_interval Alertmanager — часы), и дрилл нечего доказывать.
#
# Использование: ./drills/oomkill.sh
# Env: ALLOC_MB (200), EXPECT_REACTION (300 с), EXPECT_RECOVERY (180 с).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

ALLOC_MB="${ALLOC_MB:-200}"
EXPECT_REACTION="${EXPECT_REACTION:-300}"
EXPECT_RECOVERY="${EXPECT_RECOVERY:-180}"

# ALLOC_MB уходит прямо в код node -e: нечисловое значение либо ничего не выделит,
# либо сломает инъекцию на середине дрилла. Проверяем до старта.
case "${ALLOC_MB}" in
  '' | *[!0-9]*) die "ALLOC_MB должен быть положительным целым, получено: '${ALLOC_MB}'" ;;
esac
[ "${ALLOC_MB}" -gt 0 ] || die "ALLOC_MB должен быть больше нуля, получено: ${ALLOC_MB}"

drill_evidence_init oomkill
drill_preflight

spec_hash() {
  kubectl -n "${DEMO_NS}" get deploy demo-api -o json | jq -S '.spec' | sha256sum | awk '{print $1}'
}

oom_marked_pods() {
  kubectl -n "${DEMO_NS}" get pods -l app=demo-api -o json \
    | jq -r '.items[] | select(any(.status.containerStatuses[]?; .lastState.terminated.reason == "OOMKilled")) | .metadata.name'
}

# --- сброс прошлого состояния OOMKilled ------------------------------------
event "reset" "проверяю, нет ли прошлого OOMKilled (иначе алерт уже firing и не переотправится)"
previous_oom="$(oom_marked_pods)"
if [ -n "${previous_oom}" ]; then
  # shellcheck disable=SC2086  # имена подов через пробел, из jsonpath одного пода на строку
  kubectl -n "${DEMO_NS}" delete pod ${previous_oom} >/dev/null
fi
reset_deadline=$((SECONDS + 180))
series=1
while [ "${SECONDS}" -lt "${reset_deadline}" ]; do
  # `or vector(0)` обязателен: отсутствие серии — это и есть нужное «0 серий», а пустой
  # результат запроса иначе выглядел бы как «состояние не сброшено» (поймано 2026-11-05).
  series="$(drill_prom_value 'count(kube_pod_container_status_last_terminated_reason{reason="OOMKilled", namespace="demo"} == 1) or vector(0)')"
  [ "${series}" = "0" ] && break
  sleep 10
done
assert_eq "oom_state_reset" "0" "${series}"

# --- инъекция ---------------------------------------------------------------
event "baseline" "фиксирую спеку деплоймента и счётчик рестартов"
spec_before="$(spec_hash)"
pod="$(kubectl -n "${DEMO_NS}" get pods -l app=demo-api \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"
[ -n "${pod}" ] || die "нет Running-пода demo-api — инъекция невозможна"
restarts_before="$(kubectl -n "${DEMO_NS}" get pod "${pod}" \
  -o jsonpath='{.status.containerStatuses[0].restartCount}')"
# Пустое или нечисловое значение дало бы арифметику с "null" и ложный PASS/FAIL.
case "${restarts_before}" in
  '' | *[!0-9]*) die "restartCount пода ${pod} не число: '${restarts_before}'" ;;
esac
event "target" "под ${pod}, рестартов до дрилла: ${restarts_before}"

event "inject" "kubectl exec ${pod}: пишу ${ALLOC_MB} MiB при лимите 128Mi"
inject_epoch="$(date -u +%s)"
# Процесс и контейнер убивает cgroup, поэтому ненулевой код возврата (137) здесь
# ожидаем и не является ошибкой дрилла: результат проверяется по состоянию пода.
kubectl -n "${DEMO_NS}" exec "${pod}" -- \
  node -e "const b = Buffer.alloc(${ALLOC_MB} * 1024 * 1024); b.fill(1)" \
  >/dev/null 2>&1 || true

event "wait_oom" "жду lastState.terminated.reason=OOMKilled у подов demo-api"
deadline=$((SECONDS + 180))
while [ "${SECONDS}" -lt "${deadline}" ]; do
  [ -n "$(oom_marked_pods)" ] && break
  sleep 5
done
terminated_reason="$(kubectl -n "${DEMO_NS}" get pods -l app=demo-api -o json \
  | jq -r '[.items[].status.containerStatuses[]?
            | select(.lastState.terminated.reason == "OOMKilled")
            | .lastState.terminated.reason] | first // "нет"')"
assert_eq "last_terminated_reason" "OOMKilled" "${terminated_reason}"

wait_alert KubePodOOMKilled "${EXPECT_REACTION}"
reaction=$((WAIT_ALERT_EPOCH - inject_epoch))
# gt 0 ловит ложное совпадение: /timeline помнит прошлый дрилл, а допуск на расхождение
# часов (±120 с) иначе мог бы засчитать чужое уведомление (нашло ревью 2026-11-06).
assert_num "reaction_seconds_positive" gt 0 "${reaction}"
assert_num "reaction_seconds" le "${EXPECT_REACTION}" "${reaction}"

event "wait_ready" "жду, пока под снова станет Ready"
kubectl -n "${DEMO_NS}" wait --for=condition=Ready pod -l app=demo-api \
  --timeout="${EXPECT_RECOVERY}s" >/dev/null \
  || die "под demo-api не вернулся в Ready за ${EXPECT_RECOVERY} с"
restarts_after="$(kubectl -n "${DEMO_NS}" get pod "${pod}" \
  -o jsonpath='{.status.containerStatuses[0].restartCount}')"
case "${restarts_after}" in
  '' | *[!0-9]*) die "restartCount пода ${pod} после дрилла не число: '${restarts_after}'" ;;
esac
assert_num "restart_count_delta" ge 1 "$((restarts_after - restarts_before))"

event "verify_spec" "сверяю .spec деплоймента с состоянием до дрилла"
assert_eq "deployment_spec_unchanged" "sha256 ${spec_before}" "sha256 $(spec_hash)"

event "done" "под перезапущен, спеку не трогали"
# Финальный cleanup и запись evidence — в trap EXIT (drills/lib.sh).
