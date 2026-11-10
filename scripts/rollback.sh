#!/usr/bin/env bash
# Откат демо-контура: удаляет объекты из того же рендера, что и scripts/deploy.sh.
# Удаление namespace demo уносит поды/сервисы/ServiceMonitor; объекты в monitoring
# (дашборды demo-red, slo-demo, notifications и PrometheusRule demo-*) удаляются отдельно.
# Узкий откат одного дашборда — `kubectl -n monitoring delete cm notifications`.
# Внимание: вместе с правилами уходит и SLO-оповещение, включая SloRulesAbsent.
# Образы в containerd остаются — они безвредны.
# Использование: ./scripts/rollback.sh [--yes]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cd "${PROJECT_ROOT}"
ASSUME_YES=0
for arg in "$@"; do
  case "${arg}" in
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "неизвестный флаг: ${arg} (см. --help)" ;;
  esac
done

require_cluster
need_cmd git

TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD 2>/dev/null)}"
[ -n "${TAG}" ] || die "не удалось определить тег: нет git-репозитория? задай IMAGE_TAG"
RENDERED="$(render_demo_manifests "${TAG}")"

if [ "${ASSUME_YES}" -ne 1 ]; then
  [ -t 0 ] || die "нет интерактивного ввода (stdin не tty): для неинтерактивного запуска используй --yes"
  warn "будут удалены namespace demo (поды/сервисы демо-контура), дашборды demo-red, slo-demo и notifications, PrometheusRule demo-slo/demo-slo-alerts/demo-infra/demo-meta/demo-logs-pipeline в monitoring"
  printf 'Продолжить? [y/N] '
  # || answer="": при EOF read возвращает 1 и под set -e скрипт падал бы без сообщения
  read -r answer || answer=""
  case "${answer}" in
    y|Y|yes|YES) ;;
    *) info "отменено"; exit 0 ;;
  esac
fi

kubectl delete --ignore-not-found -f "${RENDERED}"
# Удаление namespace асинхронно: без ожидания следующий deploy.sh может упереться
# в ещё Terminating namespace. Дашборд удаляется отдельным объектом и ждать не нужно.
# Без ожидания следующий deploy.sh упрётся в ещё Terminating namespace, а его
# ошибка будет выглядеть как «apply не сработал». Поэтому ждём и падаем явно.
kubectl wait --for=delete ns/demo --timeout=120s >/dev/null 2>&1 \
  || die "namespace demo не удалился за 120 с (Terminating?) — проверь kubectl get ns demo"
info "демо-контур, дашборды и правила удалены (образы в containerd остались)"
