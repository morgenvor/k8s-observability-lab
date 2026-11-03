#!/usr/bin/env bash
# Импорт собранных образов в containerd обеих нод k3s (registry в лабе нет).
# Важно: импорт нужен на КАЖДОЙ ноде, иначе под на второй ноде уйдёт в ImagePullBackOff.
# Использование: ./scripts/import-image.sh
# Env: IMAGE_TAG (иначе короткий git SHA), LAB_SSH_CONFIG (иначе ../proxmox-lab/.secrets/ssh_config)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cd "${PROJECT_ROOT}"
need_cmd docker
need_cmd ssh
need_cmd git
require_cluster

TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}"
SSH_CONFIG="${LAB_SSH_CONFIG:-${PROJECT_ROOT}/../proxmox-lab/.secrets/ssh_config}"
[ -f "${SSH_CONFIG}" ] || die "нет ssh-конфига лабы: ${SSH_CONFIG} (задай LAB_SSH_CONFIG; ключи и адреса живут вне репозитория)"

# BatchMode: в неинтерактивном прогоне ssh не должен ждать пароль/пассфразу.
# Массив, а не строка: shellcheck -S warning ругается на неквотированное раскрытие.
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)

# Ноды берём у кластера, а не из списка в скрипте: имена нод не попадают в git,
# а ssh_config лабы знает их как алиасы Host (адреса и ключи живут вне репозитория).
mapfile -t NODES < <(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n')
[ "${#NODES[@]}" -gt 0 ] || die "kubectl не вернул нод — кластер недоступен?"

shopt -s nullglob
DOCKERFILES=(app/*/Dockerfile)
shopt -u nullglob
[ "${#DOCKERFILES[@]}" -gt 0 ] || die "нет app/*/Dockerfile — собирать нечего"

IMAGES=()
for dockerfile in "${DOCKERFILES[@]}"; do
  IMAGES+=("$(basename "$(dirname "${dockerfile}")"):${TAG}")
done

for image in "${IMAGES[@]}"; do
  docker image inspect "${image}" >/dev/null 2>&1 \
    || die "нет локального образа ${image}; сначала ./scripts/build-image.sh"
done

# docker save пишет tar в stdout, ssh отдаёт его в stdin `k3s ctr images import -`.
# Стрим не создаёт временный tarball на диске и не требует места под образ.
import_to_node() {
  local node="$1"
  docker save "${IMAGES[@]}" \
    | ssh -F "${SSH_CONFIG}" "${SSH_OPTS[@]}" "${node}" 'sudo -n k3s ctr images import -' >/dev/null
}

for node in "${NODES[@]}"; do
  info "импорт в ${node}: ${IMAGES[*]}"
  if ! import_to_node "${node}"; then
    # Первый импорт нового образа даёт пик записи на диск, и на control-plane от него
    # перезапускается k3s (embedded etcd теряет лидерство — факт лабы 2026-11-03,
    # `../proxmox-lab/CHANGELOG.md`). Это не ошибка ssh/прав: ждём, пока API ответит,
    # и повторяем один раз — блобы уже в content store, повтор идёт быстро.
    warn "импорт в ${node} не удался; жду кластер и повторяю один раз (см. CHANGELOG лабы)"
    for _ in $(seq 1 30); do
      kubectl get nodes --request-timeout=5s >/dev/null 2>&1 && break
      sleep 2
    done
    import_to_node "${node}" \
      || die "импорт в ${node} не удался и при повторе: проверь ssh-алиас ноды, sudo и состояние k3s на ноде"
  fi
done

# Проверка после импорта: тег виден в containerd на каждой ноде.
# containerd хранит образ с полным именем (docker.io/library/demo-api:тег), поэтому
# сверяем по суффиксу `(^|/)имя:тег$`, а не строкой целиком: `grep -Fx` не совпадает
# никогда, и проверка ложно падала после успешного импорта (нашло ревью 2026-11-03).
for node in "${NODES[@]}"; do
  info "проверка ${node}"
  for image in "${IMAGES[@]}"; do
    ssh -F "${SSH_CONFIG}" "${SSH_OPTS[@]}" "${node}" "sudo -n k3s ctr images ls -q | grep -qE '(^|/)${image}\$'" \
      || die "образ ${image} не найден в containerd на ${node}: импорт не удался"
  done
done

info "образы ${IMAGES[*]} импортированы на ${NODES[*]}"
