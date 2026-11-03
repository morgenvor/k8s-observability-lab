#!/usr/bin/env bash
# Откат демо-контура: удаляет объекты из того же рендера, что и scripts/deploy.sh.
# Удаление namespace demo уносит поды/сервисы/ServiceMonitor; дашборд в monitoring
# удаляется отдельным объектом. Образы в containerd остаются — они безвредны.
# Использование: ./scripts/rollback.sh [--yes]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cd "${PROJECT_ROOT}"
ASSUME_YES=0
for arg in "$@"; do
  case "${arg}" in
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "неизвестный флаг: ${arg} (см. --help)" ;;
  esac
done

require_cluster
need_cmd git

TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}"
RENDERED="$(render_demo_manifests "${TAG}")"

if [ "${ASSUME_YES}" -ne 1 ]; then
  warn "будут удалены namespace demo (все поды/сервисы демо-контура) и дашборд demo-red в monitoring"
  printf 'Продолжить? [y/N] '
  read -r answer
  case "${answer}" in
    y|Y|yes|YES) ;;
    *) info "отменено"; exit 0 ;;
  esac
fi

kubectl delete --ignore-not-found -f "${RENDERED}"
info "демо-контур удалён (образы в containerd остались, кластер monitoring не тронут)"
