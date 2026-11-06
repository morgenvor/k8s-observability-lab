#!/usr/bin/env bash
# Общие функции дриллов фазы 6. Подключается через `source`, сам не запускается и к
# кластеру при подключении не обращается: только пути, переменные и определения.
#
# Что здесь живёт:
#   preflight        — кластер отвечает, поды Ready, цели up, toxiproxy и /timeline живы;
#   evidence_init    — старт дрилла: транскрипт в evidence/<drill>.console.log, trap EXIT;
#   event            — шаг дрилла в таймлайн (t, step, detail);
#   assert_eq/assert_num — утверждения с записью expected/actual/passed;
#   wait_alert / wait_resolved — ожидание записи в /timeline alert-sink;
#   cleanup          — гарантированное снятие инъекций (через trap EXIT), даже при провале.
#
# Доказательство — evidence/<YYYY-MM-DD>-<drill>.json, схема drill-evidence/v1:
#   {schema, drill, cluster_version, started_at, finished_at,
#    assertions: [{name, expected, actual, passed}],
#    timeline:   [{t, step, detail}],
#    alerts:     [{name, fired_at, resolved_at, source}]}
# Все даты — UTC ISO-8601. Алерты берутся из /timeline alert-sink (это доказательство
# доставки), а не из Prometheus: «алерт горел» и «уведомление дошло» — разные факты.

# shellcheck source=../scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/lib.sh"

DEMO_NS="${DEMO_NS:-demo}"
PROM_SVC="${PROM_SVC:-monitoring-kube-prometheus-prometheus}"
# Локальные порты порт-форвардов: не совпадают с scripts/deploy.sh (19090), чтобы
# дрилл можно было запустить при живом деплое.
DRILL_PROM_PORT="${DRILL_PROM_PORT:-19091}"
DRILL_SINK_PORT="${DRILL_SINK_PORT:-18081}"
DRILL_TOXI_PORT="${DRILL_TOXI_PORT:-18475}"

EVIDENCE_DIR="${PROJECT_ROOT}/evidence"
DRILL_STATE_DIR="${PROJECT_ROOT}/.tmp/drills"

DRILL_NAME=""
DRILL_STARTED_AT=""
DRILL_STARTED_EPOCH=0
DRILL_CONSOLE=""
DRILL_EVIDENCE=""
DRILL_EVENTS=""
DRILL_ASSERTIONS=""
DRILL_ALERTS=""
DRILL_FAILED=0
DRILL_CLEANUP_DONE=0
DRILL_CLUSTER_VERSION="unknown"
DRILL_IMAGE_TAG="unknown"
WAIT_ALERT_AT=""
WAIT_ALERT_EPOCH=0
WAIT_RESOLVED_AT=""
WAIT_RESOLVED_EPOCH=0

declare -A PF_PIDS=()
declare -A PF_ARGS=()
declare -a CLEANUP_DESCS=()
declare -a CLEANUP_FUNCS=()
declare -a CLEANUP_ARGS=()

# --- порт-форварды ----------------------------------------------------------
# Порт-форвард — обычный процесс kubectl; живёт до конца дрилла и убивается в cleanup.
# Обрыв возможен (сон машины, сеть до лабы), поэтому любая неудача запроса один раз
# пере-поднимает форвард, а не валит дрилл на середине 20-минутного ожидания.
#
# PID нельзя хранить только в переменных: почти все запросы к Prometheus/alert-sink
# идут из подстановок `$(...)`, а переменные подпроцесса родителю не видны — cleanup
# видел пустой массив и оставлял форварды висеть (нашло ревью 2026-11-06). Поэтому PID
# пишется ещё и в файл состояния дрилла: его видно из любой подстановки.
_pf_state_file() { printf '%s/%s.forwards' "${DRILL_STATE_DIR}" "${DRILL_NAME}"; }

_pf_record() { # <local_port> <pid> <ns> <svc> <remote_port> <probe_path>
  local file line
  file="$(_pf_state_file)"
  line="$1 $2 $3 $4 $5 $6"
  # Одна строка на порт: старые записи о нём удаляем, чтобы файл не рос.
  {
    grep -v "^$1 " "${file}" 2>/dev/null || true
    printf '%s\n' "${line}"
  } >"${file}.tmp"
  mv "${file}.tmp" "${file}"
}

_pf_state_line() { # <local_port> -> "local pid ns svc remote probe"
  grep "^$1 " "$(_pf_state_file)" 2>/dev/null | tail -1
}

_pf_start() { # <ns> <svc> <local_port> <remote_port> <probe_path>
  local ns="$1" svc="$2" local_port="$3" remote_port="$4" probe="$5" i pid
  # kubectl приходит из .tools/bin, а PATH наполняет require_tools: без явной проверки
  # ошибка выглядела бы как «порт-форвард не поднялся» вместо «нет kubectl».
  need_cmd kubectl
  PF_ARGS["${local_port}"]="${ns} ${svc} ${local_port} ${remote_port} ${probe}"
  kubectl -n "${ns}" port-forward "svc/${svc}" "${local_port}:${remote_port}" >/dev/null 2>&1 &
  pid=$!
  PF_PIDS["${local_port}"]="${pid}"
  _pf_record "${local_port}" "${pid}" "${ns}" "${svc}" "${remote_port}" "${probe}"
  for i in $(seq 1 30); do
    # Проверка живости своего процесса обязательна: если порт уже занят чужим
    # листенером, проба пройдёт, а это не наш форвард (и такой «успех» маскировал
    # утечки — нашло ревью 2026-11-06).
    if ! kill -0 "${pid}" 2>/dev/null; then
      warn "kubectl port-forward ${local_port} сразу завершился (порт занят?)"
      return 1
    fi
    if curl -sf --max-time 2 "http://127.0.0.1:${local_port}${probe}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

_pf_alive() { # <local_port>
  local pid="${PF_PIDS[${1}]:-}"
  [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null
}

_pf_restart() { # <local_port>
  local port="$1" pid="" ns svc remote probe args
  if [ -n "${PF_PIDS[${port}]:-}" ]; then
    kill "${PF_PIDS[${port}]}" >/dev/null 2>&1 || true
  fi
  # В подпроцессе аргументов родителя нет — берём их из файла состояния.
  if [ -z "${PF_ARGS[${port}]:-}" ]; then
    read -r _ pid ns svc remote probe < <(_pf_state_line "${port}")
  else
    read -r ns svc _ remote probe <<<"${PF_ARGS[${port}]}"
    [ -n "${ns}" ] || die "порт ${port} не обслуживается порт-форвардом дрилла"
  fi
  [ -n "${ns:-}" ] || die "порт ${port} не обслуживается порт-форвардом дрилла"
  _pf_start "${ns}" "${svc}" "${port}" "${remote}" "${probe}" \
    || die "порт-форвард на 127.0.0.1:${port} не поднялся"
}

_pf_ensure() { # <local_port> <ns> <svc> <remote_port> <probe_path>
  local port="$1"
  if _pf_alive "${port}"; then return 0; fi
  # Из подстановки массив PID родителя не виден: там достаточно ответа порта, а
  # запущенный форвард попадёт в файл состояния и будет убит в cleanup.
  if [ -z "${PF_ARGS[${port}]:-}" ] \
    && curl -sf --max-time 2 "http://127.0.0.1:${port}${5}" >/dev/null 2>&1; then
    return 0
  fi
  _pf_start "$2" "$3" "${port}" "$4" "$5" \
    || die "порт-форвард ${2}/${3} на 127.0.0.1:${port} не поднялся"
}

_fetch() { # <local_port> <path> [curl args...] — stdout тело ответа
  local port="$1" path="$2"
  shift 2
  local out
  if out="$(curl -sf --max-time 10 "http://127.0.0.1:${port}${path}" "$@")"; then
    printf '%s' "${out}"
    return 0
  fi
  warn "порт-форвард ${port} не ответил — перезапускаю"
  _pf_restart "${port}"
  curl -sf --max-time 10 "http://127.0.0.1:${port}${path}" "$@" \
    || die "запрос ${path} на 127.0.0.1:${port} не удался и после перезапуска порт-форварда"
}

# --- Prometheus -------------------------------------------------------------
drill_prom_json() { # <promql>
  _pf_ensure "${DRILL_PROM_PORT}" monitoring "${PROM_SVC}" 9090 /-/ready
  _fetch "${DRILL_PROM_PORT}" /api/v1/query -G --data-urlencode "query=$1"
}

drill_prom_value() { # <promql> -> значение первой серии или пустая строка
  local json
  json="$(drill_prom_json "$1")" || return 0
  printf '%s' "${json}" | jq -r '.data.result[0].value[1] // empty'
}

# --- alert-sink -------------------------------------------------------------
drill_sink_timeline() {
  _pf_ensure "${DRILL_SINK_PORT}" "${DEMO_NS}" alert-sink 8080 /healthz
  _fetch "${DRILL_SINK_PORT}" /timeline
}

# --- toxiproxy --------------------------------------------------------------
drill_toxi_json() { # <method> <path> [json body]
  _pf_ensure "${DRILL_TOXI_PORT}" "${DEMO_NS}" toxiproxy 8474 /proxies
  local method="$1" path="$2" data="${3:-}"
  local args=(-X "${method}" -H "content-type: application/json")
  if [ -n "${data}" ]; then args+=(-d "${data}"); fi
  _fetch "${DRILL_TOXI_PORT}" "${path}" "${args[@]}"
}

drill_toxi_add() { # <proxy> <toxic_name> <type> <attributes_json>
  drill_toxi_json POST "/proxies/$1/toxics" \
    "{\"name\":\"$2\",\"type\":\"$3\",\"stream\":\"downstream\",\"attributes\":$4}" >/dev/null
}

# Снятие токсина идемпотентно: 404 значит «токсина уже нет» (повторный cleanup после
# падения или ручное вмешательство), и это успех, а не ошибка.
drill_toxi_remove() { # <proxy> <toxic_name>
  local port="${DRILL_TOXI_PORT}" code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -X DELETE "http://127.0.0.1:${port}/proxies/$1/toxics/$2" || true)"
  if [ "${code}" = "000" ]; then
    _pf_restart "${port}"
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
      -X DELETE "http://127.0.0.1:${port}/proxies/$1/toxics/$2" || true)"
  fi
  case "${code}" in
    204 | 404) return 0 ;;
    *)
      warn "снятие токсина $2 на прокси $1 вернуло HTTP ${code}"
      return 1
      ;;
  esac
}

# --- события и утверждения --------------------------------------------------
event() { # <step> <detail>
  local t step="$1" detail="$2"
  t="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -cn --arg t "${t}" --arg s "${step}" --arg d "${detail}" \
    '{t: $t, step: $s, detail: $d}' >>"${DRILL_EVENTS}"
  printf '  [%s] %s: %s\n' "${t}" "${step}" "${detail}"
}

_record_assertion() { # <name> <expected> <actual> <true|false>
  local name="$1" expected="$2" actual="$3" passed="$4"
  jq -cn --arg n "${name}" --arg e "${expected}" --arg a "${actual}" --argjson p "${passed}" \
    '{name: $n, expected: $e, actual: $a, passed: $p}' >>"${DRILL_ASSERTIONS}"
  if [ "${passed}" = "true" ]; then
    printf '  PASS  %s: %s\n' "${name}" "${actual}"
  else
    printf '  FAIL  %s: ожидалось %s, получено %s\n' "${name}" "${expected}" "${actual}"
    DRILL_FAILED=1
    exit 1
  fi
}

assert_eq() { # <name> <expected> <actual>
  local passed=false
  [ "$2" = "$3" ] && passed=true
  _record_assertion "$1" "$2" "$3" "${passed}"
}

assert_num() { # <name> <ge|gt|le|lt|eq> <expected> <actual>
  local name="$1" op="$2" expected="$3" actual="$4"
  local passed=false symbol="${op}"
  case "${op}" in
    ge) symbol=">=" ;;
    gt) symbol=">" ;;
    le) symbol="<=" ;;
    lt) symbol="<" ;;
    eq) symbol="==" ;;
  esac
  if [ -n "${actual}" ] && awk -v a="${actual}" -v b="${expected}" -v op="${op}" '
      BEGIN {
        if (op == "ge") exit !(a >= b);
        if (op == "gt") exit !(a >  b);
        if (op == "le") exit !(a <= b);
        if (op == "lt") exit !(a <  b);
        if (op == "eq") exit !(a == b);
        exit 1;
      }'; then
    passed=true
  fi
  _record_assertion "${name}" "${symbol} ${expected}" "${actual:-нет данных}" "${passed}"
}

# Ждёт, пока значение запроса удовлеворит условию; печатает последнее увиденное.
drill_wait_num() { # <promql> <ge|le|gt|lt> <threshold> <timeout_seconds>
  local q="$1" op="$2" threshold="$3" timeout="$4" value=""
  local deadline=$((SECONDS + timeout))
  while [ "${SECONDS}" -lt "${deadline}" ]; do
    value="$(drill_prom_value "${q}")"
    if [ -n "${value}" ] && awk -v a="${value}" -v b="${threshold}" -v op="${op}" '
        BEGIN {
          if (op == "ge") exit !(a >= b);
          if (op == "gt") exit !(a >  b);
          if (op == "le") exit !(a <= b);
          if (op == "lt") exit !(a <  b);
          exit 1;
        }'; then
      printf '%s' "${value}"
      return 0
    fi
    sleep 10
  done
  printf '%s' "${value}"
  return 1
}

# --- alert-sink: ожидание уведомлений ---------------------------------------
_iso_epoch() { # <ISO-8601 с миллисекундами или без> -> unix epoch
  date -u -d "$(printf '%s' "$1" | sed 's/\.[0-9]*Z$/Z/')" +%s
}

_record_alert() { # <name> <firing|resolved> <received_at>
  jq -cn --arg n "$1" --arg s "$2" --arg t "$3" \
    '{name: $n, status: $s, at: $t, source: "alert-sink"}' >>"${DRILL_ALERTS}"
  printf '  ALERT %s: %s (received_at %s)\n' "$1" "$2" "$3"
}

# Первое уведомление нужного статуса, полученное не раньше старта дрилла (с запасом на
# расхождение часов хоста и пода). Запас нужен потому, что /timeline — кольцо на 200
# записей: без фильтра по времени повторный прогон мог бы сослаться на прошлый дрилл.
_timeline_since() { # <alertname> <firing|resolved>
  local name="$1" status="$2" json since
  since=$((DRILL_STARTED_EPOCH - 120))
  json="$(drill_sink_timeline)" || return 1
  printf '%s' "${json}" | jq -r \
    --argjson since "${since}" --arg name "${name}" --arg status "${status}" '
      [ .[]
        | select((.received_at | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) >= $since)
        | .received_at as $t
        | .alerts[]
        | select(.name == $name and .status == $status)
        | $t ]
      | sort
      | .[0] // empty'
}

wait_alert() { # <alertname> <timeout_seconds>
  local name="$1" timeout="$2" at=""
  local deadline=$((SECONDS + timeout))
  info "ожидаю ${name} (firing) в alert-sink, не дольше ${timeout} с"
  while [ "${SECONDS}" -lt "${deadline}" ]; do
    at="$(_timeline_since "${name}" firing || true)"
    if [ -n "${at}" ]; then
      # shellcheck disable=SC2034  # читается дриллом после wait_alert
      WAIT_ALERT_AT="${at}"
      # shellcheck disable=SC2034  # читается дриллом после wait_alert
      WAIT_ALERT_EPOCH="$(_iso_epoch "${at}")"
      _record_alert "${name}" firing "${at}"
      event "alert" "${name} пришёл в alert-sink"
      return 0
    fi
    sleep 10
  done
  _record_assertion "alert_${name}" "firing не позже ${timeout} с" "не пришёл" false
}

wait_resolved() { # <alertname> <timeout_seconds>
  local name="$1" timeout="$2" at=""
  local deadline=$((SECONDS + timeout))
  info "ожидаю resolved для ${name} в alert-sink, не дольше ${timeout} с"
  while [ "${SECONDS}" -lt "${deadline}" ]; do
    at="$(_timeline_since "${name}" resolved || true)"
    if [ -n "${at}" ]; then
      # shellcheck disable=SC2034  # читается дриллом после wait_resolved
      WAIT_RESOLVED_AT="${at}"
      # shellcheck disable=SC2034  # читается дриллом после wait_resolved
      WAIT_RESOLVED_EPOCH="$(_iso_epoch "${at}")"
      _record_alert "${name}" resolved "${at}"
      event "resolved" "${name} закрылся в alert-sink"
      return 0
    fi
    sleep 10
  done
  _record_assertion "alert_${name}_resolved" "resolved не позже ${timeout} с" "не пришёл" false
}

# --- cleanup и evidence -----------------------------------------------------
drill_cleanup_add() { # <описание> <функция> [аргументы...]
  CLEANUP_DESCS+=("$1")
  CLEANUP_FUNCS+=("$2")
  CLEANUP_ARGS+=("${*:3}")
}

_drill_write_evidence() {
  local finished tmp result="passed"
  finished="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [ "${DRILL_FAILED}" -eq 0 ] || result="failed"
  tmp="${DRILL_EVIDENCE}.tmp"
  if ! jq -n \
    --arg schema "drill-evidence/v1" \
    --arg result "${result}" \
    --arg drill "${DRILL_NAME}" \
    --arg cluster "${DRILL_CLUSTER_VERSION}" \
    --arg started "${DRILL_STARTED_AT}" \
    --arg finished "${finished}" \
    --arg image "${DRILL_IMAGE_TAG}" \
    --slurpfile assertions "${DRILL_ASSERTIONS}" \
    --slurpfile timeline "${DRILL_EVENTS}" \
    --slurpfile alerts "${DRILL_ALERTS}" '
      {
        schema: $schema,
        result: $result,
        drill: $drill,
        cluster_version: $cluster,
        started_at: $started,
        finished_at: $finished,
        assertions: $assertions,
        timeline: $timeline,
        alerts: ([ $alerts[] | {name, status, at} ]
                 | group_by(.name)
                 | map({
                     name: .[0].name,
                     fired_at: ([.[] | select(.status == "firing") | .at] | first),
                     resolved_at: ([.[] | select(.status == "resolved") | .at] | last),
                     source: "alert-sink"
                   })),
        images: {demo_api: $image}
      }' >"${tmp}"; then
    warn "не удалось собрать evidence ${DRILL_EVIDENCE}"
    return 1
  fi
  mv "${tmp}" "${DRILL_EVIDENCE}"
  info "evidence: ${DRILL_EVIDENCE#"${PROJECT_ROOT}"/}"
}

drill_cleanup() {
  local code=$?
  [ "${DRILL_CLEANUP_DONE}" -eq 1 ] && return 0
  DRILL_CLEANUP_DONE=1
  trap - EXIT
  set +e
  local i
  if [ "${#CLEANUP_FUNCS[@]}" -gt 0 ]; then
    info "cleanup: снимаю инъекции"
    for (( i = ${#CLEANUP_FUNCS[@]} - 1; i >= 0; i-- )); do
      printf '  - %s\n' "${CLEANUP_DESCS[i]}"
      # shellcheck disable=SC2086  # аргументы шага cleanup собраны drill_cleanup_add
      if ! "${CLEANUP_FUNCS[i]}" ${CLEANUP_ARGS[i]}; then
        warn "шаг cleanup «${CLEANUP_DESCS[i]}» не удался — проверь состояние demo вручную"
        DRILL_FAILED=1
      fi
    done
  fi
  # Порт-форварды: то, что помнит родитель, плюс всё из файла состояния (форварды,
  # поднятые из подстановок). Без второго источника они оставались жить после дрилла.
  local file port pid
  file="$(_pf_state_file)"
  if [ -f "${file}" ]; then
    while read -r port pid _; do
      kill "${pid}" >/dev/null 2>&1
    done <"${file}"
    rm -f "${file}"
  fi
  for port in "${!PF_PIDS[@]}"; do
    kill "${PF_PIDS[${port}]}" >/dev/null 2>&1
  done
  event "cleanup" "инъекции сняты, порт-форварды закрыты"
  # Итог прогона выставляется ДО записи evidence: иначе поле result не увидит провал,
  # из-за которого дрилл завершается с ненулевым кодом.
  [ "${code}" -eq 0 ] || DRILL_FAILED=1
  _drill_write_evidence || DRILL_FAILED=1
  if [ "${DRILL_FAILED}" -eq 0 ]; then
    info "дрилл ${DRILL_NAME}: PASS"
    exit 0
  fi
  warn "дрилл ${DRILL_NAME}: FAIL — см. ${DRILL_EVIDENCE}"
  exit 1
}

# --- старт дрилла -----------------------------------------------------------
drill_evidence_init() { # <drill>
  local name="$1"
  DRILL_NAME="${name}"
  mkdir -p "${EVIDENCE_DIR}" "${DRILL_STATE_DIR}"
  DRILL_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  DRILL_STARTED_EPOCH="$(date -u +%s)"
  DRILL_CONSOLE="${EVIDENCE_DIR}/${name}.console.log"
  DRILL_EVIDENCE="${EVIDENCE_DIR}/$(date -u +%F)-${name}.json"
  DRILL_EVENTS="${DRILL_STATE_DIR}/${name}.events.ndjson"
  DRILL_ASSERTIONS="${DRILL_STATE_DIR}/${name}.assertions.ndjson"
  DRILL_ALERTS="${DRILL_STATE_DIR}/${name}.alerts.ndjson"
  # PID прошлого прогона не должны попасть в cleanup этого: номера переиспользуются.
  rm -f "$(_pf_state_file)"

  # Повторный прогон в тот же день не затирает доказательства: прежний файл и
  # транскрипт уезжают в evidence/attempts/ с суффиксом -attemptN (нашло ревью
  # 2026-11-06: два провальных прогона были затёрты успешными).
  if [ -f "${DRILL_EVIDENCE}" ] || [ -f "${DRILL_CONSOLE}" ]; then
    mkdir -p "${EVIDENCE_DIR}/attempts"
    local attempt=1 stem
    stem="$(basename "${DRILL_EVIDENCE%.json}")"
    while [ -e "${EVIDENCE_DIR}/attempts/${stem}-attempt${attempt}.json" ]; do
      attempt=$((attempt + 1))
    done
    if [ -f "${DRILL_EVIDENCE}" ]; then
      mv "${DRILL_EVIDENCE}" "${EVIDENCE_DIR}/attempts/${stem}-attempt${attempt}.json"
    fi
    if [ -f "${DRILL_CONSOLE}" ]; then
      mv "${DRILL_CONSOLE}" "${EVIDENCE_DIR}/attempts/${name}-attempt${attempt}.console.log"
    fi
    info "прежний прогон ${name} сохранён как attempt${attempt}"
  fi

  : >"${DRILL_CONSOLE}"
  : >"${DRILL_EVENTS}"
  : >"${DRILL_ASSERTIONS}"
  : >"${DRILL_ALERTS}"
  # Транскрипт прогона: каждый шаг, вывод kubectl и значения запросов попадают в файл,
  # чтобы evidence можно было перепроверить, не повторяя дрилл.
  exec > >(tee -a "${DRILL_CONSOLE}") 2>&1
  trap drill_cleanup EXIT
  info "дрилл ${name}: старт ${DRILL_STARTED_AT}"
  event "start" "дрилл ${name} начат"
}

# Предусловия дрилла. Падает (die) до инъекции, а не после: если кластер не в норме,
# дрилл не должен ничего деградировать.
drill_preflight() {
  info "preflight: кластер, поды, цели Prometheus, toxiproxy, alert-sink"
  require_cluster
  need_cmd curl
  need_cmd jq
  DRILL_CLUSTER_VERSION="$(kubectl get nodes -o json \
    | jq -r '.items[0].status.nodeInfo.kubeletVersion // "unknown"')"
  DRILL_IMAGE_TAG="$(kubectl -n "${DEMO_NS}" get deploy demo-api \
    -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/^.*://')"

  local d
  for d in demo-api demo-load alert-sink toxiproxy; do
    kubectl -n "${DEMO_NS}" rollout status "deploy/${d}" --timeout=60s >/dev/null \
      || die "deploy/${d} не перешёл в Ready — дрилл не начинается"
  done

  local up_api up_load up_sink
  up_api="$(drill_prom_value 'count(up{job="demo-api"} == 1)')"
  up_load="$(drill_prom_value 'count(up{job="demo-load"} == 1)')"
  up_sink="$(drill_prom_value 'count(up{job="alert-sink"} == 1)')"
  [ "${up_api:-0}" -ge 2 ] || die "целей demo-api с up==1: ${up_api:-0} из 2"
  [ "${up_load:-0}" -ge 1 ] || die "цель demo-load не up: ${up_load:-0}"
  [ "${up_sink:-0}" -ge 1 ] || die "цель alert-sink не up: ${up_sink:-0}"

  local proxies
  proxies="$(drill_toxi_json GET /proxies)" \
    || die "toxiproxy API не отвечает — инъекция невозможна"
  printf '%s' "${proxies}" \
    | jq -e 'any(.[]; .name == "demo-api" and .enabled == true)' >/dev/null \
    || die "прокси demo-api в toxiproxy отключён или отсутствует: $(printf '%s' "${proxies}" | jq -c '.' 2>/dev/null)"

  local timeline
  timeline="$(drill_sink_timeline)" || die "alert-sink /timeline не отвечает"
  printf '%s' "${timeline}" | jq -e 'type == "array"' >/dev/null \
    || die "alert-sink /timeline вернул не JSON-массив"

  event "preflight" \
    "кластер ${DRILL_CLUSTER_VERSION}, поды Ready, цели up (demo-api ${up_api}, demo-load ${up_load}, alert-sink ${up_sink}), toxiproxy и /timeline отвечают"
}
