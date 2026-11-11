#!/usr/bin/env bash
# Импорт собранных образов в containerd обеих нод k3s (registry в лабе нет).
# Важно: импорт нужен на КАЖДОЙ ноде, иначе под на второй ноде уйдёт в ImagePullBackOff.
# Использование: ./scripts/import-image.sh
# Env: IMAGE_TAG (иначе короткий git SHA), LAB_SSH_CONFIG (иначе .secrets/ssh_config),
#      IMPORT_IMAGES="img:tag img2:tag" — импортировать эти образы вместо app/* (например Loki/Alloy:
#      ноды лабы не всегда успевают скачать их из docker.io)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cd "${PROJECT_ROOT}"
need_cmd docker
need_cmd ssh
need_cmd git
require_cluster

# В режиме IMPORT_IMAGES теги заданы явно: git может быть недоступен (образ
# привезли из другого каталога), и вычислять тег незачем.
TAG=""
if [ -z "${IMPORT_IMAGES:-}" ]; then
  TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD 2>/dev/null)}"
  [ -n "${TAG}" ] || die "не удалось определить тег: нет git-репозитория? задай IMAGE_TAG"
fi
SSH_CONFIG="${LAB_SSH_CONFIG:-${PROJECT_ROOT}/.secrets/ssh_config}"
[ -f "${SSH_CONFIG}" ] || die "нет ssh-конфига: ${SSH_CONFIG} (задай LAB_SSH_CONFIG или положи файл в .secrets/ssh_config; каталог вне git, адреса и ключи в репозиторий не попадают)"

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
  [ "${#DOCKERFILES[@]}" -gt 0 ] || die "нет app/*/Dockerfile — импортировать нечего (или задай IMPORT_IMAGES)"
  for dockerfile in "${DOCKERFILES[@]}"; do
    IMAGES+=("$(basename "$(dirname "${dockerfile}")"):${TAG}")
  done
fi
[ "${#IMAGES[@]}" -gt 0 ] || die "пустой список образов: проверь IMPORT_IMAGES"

for image in "${IMAGES[@]}"; do
  docker image inspect "${image}" >/dev/null 2>&1 \
    || die "нет локального образа ${image}; сначала ./scripts/build-image.sh (или docker pull для стороннего)"
done

# Свои образы малы, их можно гнать стримом (tar в stdout → stdin `k3s ctr images
# import -`): временный файл на диске не нужен. Крупные сторонние образы — см. ниже.
import_to_node() {
  local node="$1"
  if [ -n "${IMPORT_IMAGES:-}" ]; then
    # Крупный сторонний образ стримом не гнать: пока 700 МБ (alloy) текут по ssh,
    # containerd на control-plane пишет их на диск десятки секунд, API starve-ится,
    # k3s теряет lease etcd и уходит в рестарт (`leaderelection lost`, факт 2026-11-04).
    # Файл на ноде + импорт из локального пути укладываются в ~10 с и API не задевают;
    # образ остаётся неупакованным — CRI распакует его при первом запуске пода.
    # tar в /tmp весит как образ (до ~700 МБ), поэтому удаляется в каждой ветке —
    # и при сбое `docker save`/`scp` тоже. Имя на ноде уникально по PID процесса:
    # два параллельных прогона не затрут друг друга.
    local tar remote_tar
    tar="$(mktemp "${TMPDIR:-/tmp}/import-images.XXXXXX.tar")"
    remote_tar="/tmp/import-images.$$.tar"
    if ! docker save -o "${tar}" "${IMAGES[@]}"; then
      rm -f "${tar}"
      return 1
    fi
    if ! scp -q -F "${SSH_CONFIG}" "${SSH_OPTS[@]}" "${tar}" "${node}:${remote_tar}"; then
      rm -f "${tar}"
      return 1
    fi
    rm -f "${tar}"
    ssh -F "${SSH_CONFIG}" "${SSH_OPTS[@]}" "${node}" \
      "sudo -n k3s ctr images import --no-unpack ${remote_tar}; rc=\$?; rm -f ${remote_tar}; exit \$rc" >/dev/null
  else
    docker save "${IMAGES[@]}" \
      | ssh -F "${SSH_CONFIG}" "${SSH_OPTS[@]}" "${node}" 'sudo -n k3s ctr images import -' >/dev/null
  fi
}

for node in "${NODES[@]}"; do
  info "импорт в ${node}: ${IMAGES[*]}"
  if ! import_to_node "${node}"; then
    # Первый импорт нового образа даёт пик записи на диск, и на control-plane от него
    # перезапускается k3s (embedded etcd теряет лидерство — факт лабы 2026-11-03,
    # записан в истории эксплуатации стенда). Это не ошибка ssh/прав: ждём, пока поднимется
    # и API, и containerd ноды (одного API мало — `ctr` в этот момент отвечает
    # «connection refused», так и провалилась первая попытка на control-plane),
    # и повторяем один раз. Повтор дешевле только для стрима (блобы уже в content
    # store); в файловом режиме он снова делает `docker save` и `scp` — но это один
    # раз и осознанно, чтобы не оставлять образ без импорта.
    warn "импорт в ${node} не удался; жду API и containerd ноды, повторяю один раз"
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
# containerd хранит образ с полным именем (docker.io/library/demo-api:тег,
# docker.io/grafana/loki:тег), поэтому сверяем по суффиксу. Сравнение — glob в `case`,
# а не regex: точки в теге (3.6.11) не должны превращаться в «любой символ», а кавычки
# в имени не должны ломать удалённую команду (нашло ревью).
for node in "${NODES[@]}"; do
  info "проверка ${node}"
  mapfile -t NODE_IMAGES < <(ssh -F "${SSH_CONFIG}" "${SSH_OPTS[@]}" "${node}" 'sudo -n k3s ctr images ls -q')
  for image in "${IMAGES[@]}"; do
    found=0
    for ref in "${NODE_IMAGES[@]}"; do
      case "${ref}" in
        "${image}" | */"${image}") found=1 ;;
      esac
      [ "${found}" -eq 1 ] && break
    done
    [ "${found}" -eq 1 ] || die "образ ${image} не найден в containerd на ${node}: импорт не удался"
  done
done

info "образы ${IMAGES[*]} импортированы на ${NODES[*]}"
