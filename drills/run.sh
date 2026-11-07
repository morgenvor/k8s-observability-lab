#!/usr/bin/env bash
# Последовательный запуск дриллов: единый лог прогона и ненулевой код возврата,
# если хотя бы один дрилл провалился. Сам по себе ничего не инжектирует.
#
# Использование: ./drills/run.sh latency|errors|oomkill|readiness|all [...]
# Единый лог: evidence/<YYYY-MM-DD>-drills-run.console.log. Плюс каждый дрилл пишет
# свой транскрипт evidence/<drill>.console.log и evidence/<YYYY-MM-DD>-<drill>.json.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

DRILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALL_DRILLS=(latency errors oomkill readiness)

[ "$#" -gt 0 ] || die "укажи дрилл: ${ALL_DRILLS[*]} или all"

# Дедупликация: `run.sh all latency` не должен прогонять latency дважды — дрилл
# идёт ~20 минут, а повтор ещё и перезаписал бы свои же доказательства.
DRILLS=()
declare -A SEEN=()
for arg in "$@"; do
  case "${arg}" in
    all) add_drills=("${ALL_DRILLS[@]}") ;;
    latency | errors | oomkill | readiness) add_drills=("${arg}") ;;
    *) die "неизвестный дрилл '${arg}': ожидается ${ALL_DRILLS[*]} или all" ;;
  esac
  for drill in "${add_drills[@]}"; do
    [ -n "${SEEN[${drill}]:-}" ] && continue
    SEEN["${drill}"]=1
    DRILLS+=("${drill}")
  done
done

mkdir -p "${EVIDENCE_DIR}"
# Лог не перезаписывается: прогоны за день копятся в одном файле с заголовками, иначе
# второй запуск уничтожал бы доказательство первого.
LOG="${EVIDENCE_DIR}/$(date -u +%F)-drills-run.console.log"
{
  printf '\n########## прогон %s: %s ##########\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${DRILLS[*]}"
} >>"${LOG}"
info "прогон дриллов: ${DRILLS[*]} (единый лог: ${LOG#"${PROJECT_ROOT}"/})"

FAILED=()
for drill in "${DRILLS[@]}"; do
  [ -x "${DRILL_DIR}/${drill}.sh" ] || die "нет исполняемого дрилла ${DRILL_DIR}/${drill}.sh"
  {
    printf '\n===== %s: старт %s =====\n' "${drill}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } | tee -a "${LOG}"
  if "${DRILL_DIR}/${drill}.sh" 2>&1 | tee -a "${LOG}"; then
    printf '===== %s: PASS =====\n' "${drill}" | tee -a "${LOG}"
  else
    printf '===== %s: FAIL =====\n' "${drill}" | tee -a "${LOG}"
    FAILED+=("${drill}")
  fi
done

if [ "${#FAILED[@]}" -gt 0 ]; then
  warn "провалены дриллы: ${FAILED[*]} (см. ${LOG#"${PROJECT_ROOT}"/})"
  exit 1
fi
info "все дриллы прошли: ${DRILLS[*]}"
