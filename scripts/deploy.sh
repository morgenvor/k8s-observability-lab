#!/usr/bin/env bash
# Доставка демо-контура в k3s лабы: рендер kustomize с тегами образов и один apply.
# Живое действие: создаёт namespace demo и объекты в monitoring (дашборды).
# Использование: ./scripts/deploy.sh
# Env: IMAGE_TAG (иначе короткий git SHA), KUBECONFIG (иначе kubeconfig лабы),
#      WAIT_TARGETS (секунды ожидания targets, по умолчанию 180)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cd "${PROJECT_ROOT}"
require_cluster
need_cmd curl
need_cmd docker
need_cmd git

TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}"
WAIT_TARGETS="${WAIT_TARGETS:-180}"
case "${WAIT_TARGETS}" in
  ''|*[!0-9]*) die "WAIT_TARGETS='${WAIT_TARGETS}' не число секунд (ожидается целое, например 180)" ;;
esac

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

info "kubectl apply (namespace demo + демо-объекты + дашборд в monitoring)"
kubectl apply -f "${RENDERED}"

info "ожидание rollout"
kubectl -n demo rollout status deploy/demo-api --timeout=180s
kubectl -n demo rollout status deploy/demo-load --timeout=180s
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

# Гейт проверяет три вещи по отдельности, а не «сколько-то целей живы»:
#  1) оба эндпоинта demo-api (2 реплики) скрейпятся;
#  2) demo-load скрейпится (иначе пропажа его ServiceMonitor прошла бы незамеченной);
#  3) нагрузка реально доходит до demo-api — up=1 ничего не говорит о работоспособности
#     пути demo-load → toxiproxy → demo-api (инцидент с конфигом toxiproxy 2026-11-03
#     давал up=1 при 100 % ошибок у клиента).
info "ожидание целей и живого трафика (до ${WAIT_TARGETS} с)"
deadline=$((SECONDS + WAIT_TARGETS))
api_up=""; load_up=""; ok_rate=""
while [ "${SECONDS}" -lt "${deadline}" ]; do
  api_up="$(prom_scalar 'count(up{job="demo-api"} == 1)')"
  load_up="$(prom_scalar 'count(up{job="demo-load"} == 1)')"
  ok_rate="$(prom_scalar 'sum(rate(load_requests_total{outcome="ok"}[2m]))')"
  if [ "${api_up:-0}" -ge 2 ] && [ "${load_up:-0}" -ge 1 ] \
      && awk "BEGIN{exit !(${ok_rate:-0} > 0)}"; then
    break
  fi
  sleep 5
done

[ "${api_up:-0}" -ge 2 ] || die "demo-api: up==1 у ${api_up:-0} эндпоинтов (нужно 2); проверь поды и ServiceMonitor (метка release=monitoring)"
[ "${load_up:-0}" -ge 1 ] || die "demo-load: up==1 у ${load_up:-0} целей (нужно 1); проверь ServiceMonitor/demo-load"
awk "BEGIN{exit !(${ok_rate:-0} > 0)}" \
  || die "нагрузка не доходит до demo-api: rate(load_requests_total{outcome=\"ok\"}) = ${ok_rate:-0}; проверь toxiproxy (прокси demo-api:12001 → demo-api:8080) и TARGET_URL"
info "цели живы (demo-api ${api_up}, demo-load ${load_up}), ok-трафик ${ok_rate} rps"

info "headroom нод"
kubectl top nodes || warn "kubectl top недоступен (metrics-server?), проверь вручную"
