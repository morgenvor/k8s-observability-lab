#!/usr/bin/env bash
# Офлайн-тесты поведения дриллов (без кластера): сигналы и cleanup.
#
# Зачем: доказательство дрилла — JSON с result: passed. Без этих тестов passed мог
# появиться у прогона, который никто не довёл до конца: SIGTERM в середине
# (инъекция снята, но дрилл прерван), падение шага cleanup или сценарий, оборванный
# до финального события done. Регресс ровно на это и проверяется.
#
# Как: дриллы-заглушки создаются во временном каталоге и запускаются отдельными
# процессами; EVIDENCE_DIR и DRILL_STATE_DIR указывают в .tmp, поэтому настоящие
# evidence/ не трогаются. Кластер не нужен.
#
# Использование: bash drills/tests/signals.sh
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

need_cmd bash
need_cmd jq

TESTS_DIR="${PROJECT_ROOT}/.tmp/drills-tests"
export EVIDENCE_DIR="${TESTS_DIR}/evidence"
export DRILL_STATE_DIR="${TESTS_DIR}/state"
rm -rf "${TESTS_DIR}"
mkdir -p "${EVIDENCE_DIR}" "${DRILL_STATE_DIR}"

TODAY="$(date -u +%F)"
FAILURES=0
pass() { printf '  PASS  %s\n' "$*"; }
fail() {
  printf '  FAIL  %s\n' "$*"
  FAILURES=1
}

# Запускает дрилл-заглушку в фоне, при необходимости шлёт сигнал, возвращает код выхода.
run_drill() { # <script> <signal|""> <delay_seconds>
  local script="$1" signal="$2" delay="$3" pid code
  bash "${script}" >"${script%.sh}.log" 2>&1 &
  pid=$!
  if [ -n "${signal}" ]; then
    sleep "${delay}"
    kill "-${signal}" "${pid}" 2>/dev/null || true
  fi
  code=0
  wait "${pid}" || code=$?
  printf '%s' "${code}"
}

field() { # <json file> <jq filter>
  jq -r "$2" "$1" 2>/dev/null || printf 'нет файла или поля'
}

# --- 1. прерывание сигналом: failed и ненулевой код -------------------------
# sleep запускается в фоне и ждётся через wait: wait прерывается сигналом, а
# обычный `sleep 30` в foreground просил бы дождаться его конца (так bash
# откладывает выполнение ловушки).
cat >"${TESTS_DIR}/interrupted.sh" <<'CHILD'
set -euo pipefail
source "${PROJECT_ROOT}/drills/lib.sh"
drill_evidence_init signalterm
event "start" "тестовый дрилл"
assert_eq "baseline" "1" "1"
sleep 30 &
wait $!
event "done" "этого события быть не должно"
CHILD

printf '== прерывание SIGTERM ==\n'
code="$(run_drill "${TESTS_DIR}/interrupted.sh" TERM 1)"
evidence="${EVIDENCE_DIR}/${TODAY}-signalterm.json"
[ "${code}" -ne 0 ] && pass "код возврата ${code} != 0" || fail "прерванный дрилл вернул 0"
[ "$(field "${evidence}" '.result')" = "failed" ] \
  && pass "result: failed" \
  || fail "result: $(field "${evidence}" '.result'), ожидалось failed"
jq -e 'select(.step == "done")' "${DRILL_STATE_DIR}/signalterm.events.ndjson" >/dev/null 2>&1 \
  && fail "в прерванном прогоне появилось событие done" \
  || pass "события done нет"

# --- 2. штатное завершение: passed и код 0 ---------------------------------
cat >"${TESTS_DIR}/finished.sh" <<'CHILD'
set -euo pipefail
source "${PROJECT_ROOT}/drills/lib.sh"
drill_evidence_init finished
event "start" "тестовый дрилл"
assert_eq "baseline" "1" "1"
event "done" "тестовый сценарий завершён"
CHILD

printf '== штатное завершение ==\n'
code="$(run_drill "${TESTS_DIR}/finished.sh" "" 0)"
evidence="${EVIDENCE_DIR}/${TODAY}-finished.json"
[ "${code}" -eq 0 ] && pass "код возврата 0" || fail "штатный дрилл вернул ${code}"
[ "$(field "${evidence}" '.result')" = "passed" ] \
  && pass "result: passed" \
  || fail "result: $(field "${evidence}" '.result'), ожидалось passed"
[ "$(field "${evidence}" '.images | length')" = "3" ] \
  && pass "в evidence три образа" \
  || fail "в evidence $(field "${evidence}" '.images | length') образ(ов), ожидалось 3"

# --- 3. die в шаге cleanup не обрывает cleanup ------------------------------
# Шаги выполняются в обратном порядке: сначала «сбой», затем «маркер». До правки
# die внутри шага завершал весь скрипт — маркер не появлялся, а evidence не
# записывался.
cat >"${TESTS_DIR}/cleanupfail.sh" <<'CHILD'
set -euo pipefail
source "${PROJECT_ROOT}/drills/lib.sh"
drill_evidence_init cleanupfail
marker_step() { printf 'маркер\n' >>"${MARKER_FILE}"; }
die_step() { die "тестовый сбой шага cleanup"; }
drill_cleanup_add "маркер после сбоя" marker_step
drill_cleanup_add "сбой cleanup" die_step
event "start" "тестовый дрилл"
event "done" "тестовый сценарий завершён"
CHILD

printf '== сбой шага cleanup ==\n'
export MARKER_FILE="${TESTS_DIR}/cleanup.marker"
: >"${MARKER_FILE}"
code="$(run_drill "${TESTS_DIR}/cleanupfail.sh" "" 0)"
evidence="${EVIDENCE_DIR}/${TODAY}-cleanupfail.json"
[ "${code}" -ne 0 ] && pass "код возврата ${code} != 0" || fail "дрилл со сбоем cleanup вернул 0"
grep -q 'маркер' "${MARKER_FILE}" \
  && pass "шаг после сбоя выполнился" \
  || fail "шаг после сбоя не выполнился — cleanup прервался"
[ "$(field "${evidence}" '.result')" = "failed" ] \
  && pass "result: failed" \
  || fail "result: $(field "${evidence}" '.result'), ожидалось failed"

if [ "${FAILURES}" -ne 0 ]; then
  printf 'ERROR: тесты сигналов дриллов провалены (см. %s)\n' "${TESTS_DIR}" >&2
  exit 1
fi
printf 'OK: тесты сигналов дриллов прошли\n'