#!/usr/bin/env bash
# Импорт собранных образов в containerd обеих нод k3s (registry в лабе нет).
# Важно: импорт нужен на КАЖДОЙ ноде, иначе под на второй ноде уйдёт в ImagePullBackOff.
# Использование: ./scripts/import-image.sh
# Env: IMAGE_TAG (иначе короткий git SHA), LAB_SSH_CONFIG (иначе ../proxmox-lab/.secrets/ssh_config),
#      IMPORT_IMAGES="img:tag img2:tag" — импортировать эти образы вместо app/* (например Loki/Alloy:
#      ноды лабы не всегда успевают скачать их из docker.io, см. CHANGELOG фазы 5)
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

IMAGES=()
if [ -n "${IMPORT_IMAGES:-}" ]; then
  # Явный список: сторонние образы (Loki, Alloy) тоже приходят в containerd импортом,
  # когда нода не может скачать их из docker.io. Проверка «нет app/*/Dockerfile» ниже
  # в этом режиме не нужна — тегов приложений тут нет.
  read -r -a IMAGES <<<"${IMPORT_IMAGES}"
else
  [ "${#DOCKERFILES[@]}" -gt 0 ] || die "нет app/*/Dockerfile — собирать нечего (или задай IMPORT_IMAGES)"
  for dockerfile in "${DOCKERFILES[@]}"; do
    IMAGES+=("$(basename "$(dirname "${dockerfile}")"):${TAG}")
  done
fi
[ "${#IMAGES[@]}" -gt 0 ] || die "пустой список образов: проверь IMPORT_IMAGES"

for image in "${IMAGES[@]}"; do
  docker image inspect "${image}" >/dev/null 2>&1 \
    || die "нет локального образа ${image}; сначала ./scripts/build-image.sh (или docker pull для стороннего)"
done

# docker save пишет tar в stdout, ssh отдаёт его в stdin `k3s ctr images import -`.
# Стрим не создаёт временный tarball на диске и не требует места под образ.
import_to_node() {
  local node="$1"
  if [ -n "${IMPORT_IMAGES:-}" ]; then
    # Крупный сторонний образ стримом не гнать: пока 700 МБ (alloy) текут по ssh,
    # containerd на control-plane пишет их на диск десятки секунд, API starve-ится,
    # k3s теряет lease etcd и уходит в рестарт (`leaderelection lost`, факт 2026-11-04).
    # Файл на ноде + импорт из локального пути укладываются в ~10 с и API не задевают;
    # образ остаётся неупакованным — CRI распакует его при первом запуске пода.
    local tar
    tar="$(mktemp "${TMPDIR:-/tmp}/import-images.XXXXXX.tar")"
    docker save -o "${tar}" "${IMAGES[@]}"
    scp -q -F "${SSH_CONFIG}" "${SSH_OPTS[@]}" "${tar}" "${node}:/tmp/import-images.tar"
    rm -f "${tar}"
    ssh -F "${SSH_CONFIG}" "${SSH_OPTS[@]}" "${node}" \
      'sudo -n k3s ctr images import --no-unpack /tmp/import-images.tar; rc=$?; rm -f /tmp/import-images.tar; exit $rc' >/dev/null
  else
    # Свои образы малы: стрим без временного tarball на диске.
    docker save "${IMAGES[@]}" \
      | ssh -F "${SSH_CONFIG}" "${SSH_OPTS[@]}" "${node}" 'sudo -n k3s ctr images import -' >/dev/null
  fi
}

for node in "${NODES[@]}"; do
  info "импорт в ${node}: ${IMAGES[*]}"
  if ! import_to_node "${node}"; then
    # Первый импорт нового образа даёт пик записи на диск, и на control-plane от него
    # перезапускается k3s (embedded etcd теряет лидерство — факт лабы 2026-11-03,
    # `../proxmox-lab/CHANGELOG.md`). Это не ошибка ssh/прав: ждём, пока поднимется
    # и API, и containerd ноды (одного API мало — `ctr` в этот момент отвечает
    # «connection refused», так и провалилась первая попытка на control-plane в фазе 5),
    # и повторяем один раз — блобы уже в content store, повтор идёт быстро.
    warn "импорт в ${node} не удался; жду API и containerd ноды, повторяю один раз (см. CHANGELOG лабы)"
    ready=0
    for _ in $(seq 1 60); do
      if kubectl get nodes --request-timeout=5s >/dev/null 2>&1 \
        && ssh -F "${SSH_CONFIG}" "${SSH_OPTS[@]}" "${node}" 'sudo -n k3s ctr version >/dev/null 2>&1'; then
        ready=1
        break
      fi
      sleep 2
    done
    [ "${ready}" -eq 1 ] \
      || die "нода ${node} не вернулась в строй (API/containerd) — проверь k3s на ноде вручную"
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
