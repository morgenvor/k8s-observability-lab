#!/usr/bin/env bash
# Откат проекта: удаляет ВСЕ объекты из того же рендера, что и scripts/deploy.sh.
# Удаляются: namespace demo целиком (demo-api, demo-load, alert-sink, toxiproxy и их
# Service/ServiceMonitor), три ConfigMap дашбордов, шесть PrometheusRule, AlertmanagerConfig
# demo-notifications (а с ним — весь маршрут уведомлений) и ConfigMap loki-rules (том
# правил Loki). После отката письма page|critical и записи в /timeline прекращаются, а Loki
# не поднимется после рестарта без ConfigMap: восстановление — docs/runbook.md, раздел 3.
# Узкий откат одного дашборда — `kubectl -n monitoring delete cm notifications`.
# Образы в containerd остаются — они безвредны.
# Использование: ./scripts/rollback.sh [--yes]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cd "${PROJECT_ROOT}"
ASSUME_YES=0
for arg in "$@"; do
  case "${arg}" in
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
  warn "будут удалены: namespace demo целиком (4 деплоймента, 3 ServiceMonitor); в monitoring — дашборды demo-red/slo-demo/notifications, ConfigMap loki-rules, AlertmanagerConfig demo-notifications (маршрут уведомлений перестанет работать) и 6 PrometheusRule (demo-slo, demo-slo-alerts, demo-infra, demo-meta, demo-logs-pipeline, demo-alerting-path). Восстановление: kubectl apply -k deploy/loki-rules (вернуть том правил), затем ./scripts/deploy.sh с e-mail env"
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
# `delete -f` идёт по ИМЕНАМ из текущего рендера и молчит про то, чего нет: объект,
# переименованный после деплоя, остался бы в monitoring, а скрипт сказал бы «удалено».
# Поэтому проверяем остатки по метке проекта, а не по списку имён. Ошибка чтения —
# провал: `|| true` превратил бы RBAC/таймаут в «остатков нет».
if ! leftovers="$(kubectl -n monitoring get prometheusrule,configmap,alertmanagerconfig \
      -l app.kubernetes.io/part-of=k8s-observability-lab -o name 2>/dev/null)"; then
  die "не удалось проверить остатки после удаления (kubectl вернул ошибку): доступ к кластеру или таймаут. Остатки нужно проверить вручную: kubectl -n monitoring get prometheusrule,configmap,alertmanagerconfig -l app.kubernetes.io/part-of=k8s-observability-lab"
fi
[ -z "${leftovers}" ] \
  || die "в monitoring остались объекты проекта (переименованы?): ${leftovers//$'\n'/, } — удали их вручную и повтори проверку"
info "демо-контур, дашборды, правила, маршрут уведомлений и ConfigMap правил Loki удалены (образы в containerd остались)"
