#!/usr/bin/env bash
# Локальный smoke фикстуры без кластера: собрать образы, поднять их в отдельной
# docker-сети и проверить контракт (эндпоинты, метрики с бакетом 0.3, рост
# нагрузки, JSON-логи). Контейнеры и сеть убираются всегда, через trap.
# Использование: ./scripts/smoke-local.sh [--keep]
#   --keep  оставить контейнеры после прогона (для ручного разбора)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KEEP=0
for arg in "$@"; do
  case "${arg}" in
    --keep) KEEP=1 ;;
    -h|--help)
      sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "неизвестный флаг: ${arg} (см. --help)" ;;
  esac
done

need_cmd docker
need_cmd curl
need_cmd node
cd "${PROJECT_ROOT}"

SUFFIX="$$"
NETWORK="obs-lab-smoke-${SUFFIX}"
API="demo-api-${SUFFIX}"
LOAD="demo-load-${SUFFIX}"
IMAGE_TAG="smoke-local"

cleanup() {
  if [ "${KEEP}" -eq 1 ]; then
    warn "контейнеры оставлены: ${API}, ${LOAD} (сеть ${NETWORK})"
    return 0
  fi
  docker rm -f "${LOAD}" "${API}" >/dev/null 2>&1 || true
  docker network rm "${NETWORK}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Порт, который docker назначил на хосте для 8080/tcp контейнера.
host_port() {
  docker port "$1" 8080/tcp | awk -F: 'NR==1 {print $NF}'
}

wait_http() { # wait_http <что> <url> [попыток по 0.5 с]
  local what="$1" url="$2" attempts="${3:-40}" i
  for ((i = 1; i <= attempts; i++)); do
    # Первые попытки могут попасть в момент, когда порт ещё не слушается, — это normal.
    if curl -fsS --max-time 2 -o /dev/null "${url}" 2>/dev/null; then
      return 0
    fi
    sleep 0.5
  done
  die "${what} не ответил на ${url} за $((attempts / 2)) с"
}

# Текст ответа с понятной ошибкой: под `set -e` молчаливое падение curl
# превращается в «скрипт умер без сообщения».
fetch_text() { # fetch_text <url> <что>
  local body
  if ! body="$(curl -fsS --max-time 5 "$1")"; then
    die "не удалось получить $2 ($1)"
  fi
  printf '%s' "${body}"
}

assert_contains() { # assert_contains <описание> <текст> <ERE>
  if ! printf '%s' "$2" | grep -Eq "$3"; then
    die "$1: в ответе нет совпадения с /$3/"
  fi
}

# Сумма значений числовых серий по имени (и необязательной подстроке меток).
# Недоступный /metrics даёт 0: вызывающая сторона сама решает, ошибка это или нет.
metric_sum() { # metric_sum <url> <имя_метрики> [подстрока_меток]
  {
    curl -fsS --max-time 5 "$1/metrics" 2>/dev/null || true
  } | node -e '
let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => { input += chunk; });
process.stdin.on("end", () => {
  const [name, labelFilter] = process.argv.slice(1);
  let sum = 0;
  for (const line of input.split("\n")) {
    if (!line.startsWith(name + "{") && !line.startsWith(name + " ")) continue;
    if (labelFilter && !line.includes(labelFilter)) continue;
    const value = Number(line.slice(line.lastIndexOf(" ")).trim());
    if (Number.isFinite(value)) sum += value;
  }
  process.stdout.write(String(sum));
});' "$2" "${3:-}"
}

# Каждая непустая строка лога — JSON-объект с ts/level/msg; событие <msg> есть.
validate_logs() { # validate_logs <контейнер> <ожидаемое msg>
  docker logs "$1" 2>&1 | node -e '
let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => { input += chunk; });
process.stdin.on("end", () => {
  const expected = process.argv[1];
  const fail = (message) => {
    console.error(message);
    process.exit(1);
  };
  const lines = input.split("\n").filter((line) => line.trim() !== "");
  if (lines.length === 0) fail("лог пуст");
  let found = false;
  lines.forEach((line, index) => {
    let entry;
    try {
      entry = JSON.parse(line);
    } catch {
      fail(`строка ${index + 1} не является JSON: ${line}`);
    }
    for (const key of ["ts", "level", "msg"]) {
      if (typeof entry[key] !== "string") fail(`строка ${index + 1}: нет строкового поля ${key}`);
    }
    if (entry.msg === expected) found = true;
    if (entry.msg === "http_request") {
      if (typeof entry.request_id !== "string" || entry.request_id === "") {
        fail("http_request без request_id");
      }
      if (typeof entry.status !== "number") fail("http_request без числового status");
      if (typeof entry.duration_ms !== "number") fail("http_request без duration_ms");
    }
    if (entry.msg === "load_request") {
      if (!["ok", "error", "timeout"].includes(entry.outcome)) {
        fail(`load_request с неожиданным outcome: ${entry.outcome}`);
      }
      if (typeof entry.duration_ms !== "number") fail("load_request без duration_ms");
    }
  });
  if (!found) fail(`в логе нет события ${expected}`);
});' "$2"
}

# --- 1. Сборка образов -------------------------------------------------------
step() { printf '\n==> %s\n' "$*"; }

shopt -s nullglob
DOCKERFILES=(app/*/Dockerfile)
[ "${#DOCKERFILES[@]}" -gt 0 ] || die "нет app/*/Dockerfile — собирать нечего"
for dockerfile in "${DOCKERFILES[@]}"; do
  name="$(basename "$(dirname "${dockerfile}")")"
  step "docker build ${name}:${IMAGE_TAG}"
  docker build -q -t "${name}:${IMAGE_TAG}" "$(dirname "${dockerfile}")" >/dev/null
done

# --- 2. Запуск в изолированной сети -----------------------------------------
step "docker network/run"
docker network create "${NETWORK}" >/dev/null
docker run -d --name "${API}" --network "${NETWORK}" -p 127.0.0.1::8080 \
  "demo-api:${IMAGE_TAG}" >/dev/null
docker run -d --name "${LOAD}" --network "${NETWORK}" -p 127.0.0.1::8080 \
  -e "TARGET_URL=http://${API}:8080/work" "demo-load:${IMAGE_TAG}" >/dev/null

API_URL="http://127.0.0.1:$(host_port "${API}")"
LOAD_URL="http://127.0.0.1:$(host_port "${LOAD}")"

# --- 3. Эндпоинты demo-api ---------------------------------------------------
step "demo-api: /healthz, /ready"
wait_http "demo-api /healthz" "${API_URL}/healthz"
assert_contains "demo-api /ready" "$(fetch_text "${API_URL}/ready" 'готовность demo-api')" '^ready$'
if ! curl -fsS -o /dev/null "${API_URL}/work"; then
  die "demo-api не ответил на /work (${API_URL}/work)"
fi

step "demo-api: /metrics"
API_METRICS="$(fetch_text "${API_URL}/metrics" 'метрики demo-api')"
assert_contains "http_requests_total" "${API_METRICS}" '^http_requests_total\{'
assert_contains "http_request_duration_seconds" "${API_METRICS}" '^http_request_duration_seconds_bucket\{'
assert_contains "бакет le=\"0.3\"" "${API_METRICS}" 'http_request_duration_seconds_bucket\{[^}]*le="0\.3"'
assert_contains "http_inflight_requests" "${API_METRICS}" '^http_inflight_requests'

# --- 4. Нагрузка: /healthz, /metrics и рост счётчика за 10 с -----------------
step "demo-load: /healthz и первые запросы к demo-api"
wait_http "demo-load /healthz" "${LOAD_URL}/healthz"
# /ready — готовность цикла, а не процесса: в кластере на неё смотрит
# readinessProbe, поэтому контракт проверяем и здесь.
assert_contains "demo-load /ready" "$(fetch_text "${LOAD_URL}/ready" 'готовность demo-load')" '^ready$'
# Серия счётчика появляется только после первого завершённого запроса.
for _ in $(seq 1 20); do
  if [ "$(metric_sum "${LOAD_URL}" load_requests_total 'outcome="ok"')" -gt 0 ]; then
    break
  fi
  sleep 0.5
done
BEFORE="$(metric_sum "${LOAD_URL}" load_requests_total 'outcome="ok"')"
if [ "${BEFORE%.*}" -le 0 ]; then
  die "demo-load не выполнил ни одного ok-запроса за 10 с (доступен ли TARGET_URL?)"
fi

step "demo-load: /metrics"
LOAD_METRICS="$(fetch_text "${LOAD_URL}/metrics" 'метрики demo-load')"
assert_contains "load_requests_total" "${LOAD_METRICS}" '^load_requests_total\{'
assert_contains "load_request_duration_seconds" "${LOAD_METRICS}" '^load_request_duration_seconds_bucket\{'
assert_contains "бакет le=\"0.3\" у нагрузки" "${LOAD_METRICS}" 'load_request_duration_seconds_bucket\{[^}]*le="0\.3"'

step "рост load_requests_total{outcome=\"ok\"} за 10 с"
sleep 10
AFTER="$(metric_sum "${LOAD_URL}" load_requests_total 'outcome="ok"')"
printf 'ok-запросов: %s -> %s\n' "${BEFORE}" "${AFTER}"
if [ "${AFTER%.*}" -le "${BEFORE%.*}" ]; then
  die "load_requests_total не растёт (${BEFORE} -> ${AFTER}); демо-нагрузка не работает"
fi

# --- 5. Логи ----------------------------------------------------------------
step "JSON-логи"
validate_logs "${API}" http_request
validate_logs "${LOAD}" load_request

step "SMOKE OK"
printf 'demo-api: %s\ndemo-load: %s\n' "${API_URL}" "${LOAD_URL}"