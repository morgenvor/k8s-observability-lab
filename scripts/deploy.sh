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
need_cmd git

TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}"
WAIT_TARGETS="${WAIT_TARGETS:-180}"

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

info "ожидание, пока оба ServiceMonitor попадут в Prometheus (до ${WAIT_TARGETS} с)"
deadline=$((SECONDS + WAIT_TARGETS))
total=""; healthy=""
while [ "${SECONDS}" -lt "${deadline}" ]; do
  total="$(prom_scalar 'count(up{job=~"demo-.*"})')"
  healthy="$(prom_scalar 'count(up{job=~"demo-.*"} == 1)')"
  if [ "${total:-0}" -ge 2 ] && [ "${total}" = "${healthy}" ]; then
    break
  fi
  sleep 5
done

if [ "${total:-0}" -lt 2 ] || [ "${total}" != "${healthy}" ]; then
  kubectl -n demo get pods -o wide >&2 || true
  die "не все цели demo подняты: up==1 ${healthy:-?} из ${total:-?}; проверь ServiceMonitor (метка release=monitoring) и поды"
fi
info "все цели demo живы: up==1 ${healthy} из ${total}"

info "headroom нод"
kubectl top nodes || warn "kubectl top недоступен (metrics-server?), проверь вручную"
