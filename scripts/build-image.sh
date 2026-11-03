#!/usr/bin/env bash
# Сборка образов приложений с тегом = короткий git SHA (или IMAGE_TAG из env).
# Образы сразу собираются под k3s-ноды: тег не меняется, импорт делает scripts/import-image.sh.
# Использование: ./scripts/build-image.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cd "${PROJECT_ROOT}"
need_cmd docker
need_cmd git

TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}"
[ -n "${TAG}" ] || die "пустой тег образа: задай IMAGE_TAG"

shopt -s nullglob
DOCKERFILES=(app/*/Dockerfile)
shopt -u nullglob
[ "${#DOCKERFILES[@]}" -gt 0 ] || die "нет app/*/Dockerfile — собирать нечего"

for dockerfile in "${DOCKERFILES[@]}"; do
  app_dir="$(dirname "${dockerfile}")"
  name="$(basename "${app_dir}")"
  info "docker build ${name}:${TAG}"
  docker build -t "${name}:${TAG}" "${app_dir}"
  printf '%s:%s\n' "${name}" "${TAG}"
done

info "теги образов: ${TAG}; дальше — ./scripts/import-image.sh"
