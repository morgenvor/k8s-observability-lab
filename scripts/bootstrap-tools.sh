#!/usr/bin/env bash
# Скачивает пиннутые инструменты проекта в .tools/bin. sudo не нужен.
# Версии и sha256 зафиксированы здесь; обновление версии — осознанная правка + запись
# в CHANGELOG.md. Повторный запуск ничего не качает, если версия уже стоит.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELM_VERSION="v3.19.0"
HELMFILE_VERSION="v1.8.2"
KUBECTL_VERSION="v1.37.2"
KUBECONFORM_VERSION="v0.8.0"
PROMETHEUS_VERSION="v3.15.1"   # = версия Prometheus в кластере (kube-prometheus-stack 92.14.1)
# Alloy нужен только воротам: `alloy validate` разбирает конфиг из рендера чарта
# (grep синтаксис не проверяет). Версия обязана совпадать с образом в кластере
# (helm/values/alloy.yaml, alloy.image.tag), иначе ворота валидируют чужой парсер.
ALLOY_VERSION="v1.21.3"
HELM_DIFF_VERSION="v3.15.15"

HELM_SHA256="a7f81ce08007091b86d8bd696eb4d86b8d0f2e1b9f6c714be62f82f96a594496"
HELMFILE_SHA256="f179485c5bb9f8e20fbd8ea16d8807915988aba4d60131ee864fb3232452716e"
KUBECTL_SHA256="c04487523e7aa7d1493f7808174c899db93d7a9cf57531420cd76b9bd415f8f4"
KUBECONFORM_SHA256="9bc2bffbf71f261128533edaf912153948b7ff238f9a531ae6d34466ec287883"
PROMETHEUS_SHA256="6a726885328ad9efebbf36e876ce2fb6225468a71fd1e7ce3ba666d5f4d97a84"
# Из SHA256SUMS релиза v1.21.3 (assets: alloy-linux-amd64.zip, 169 МБ).
ALLOY_SHA256="50d23af2d0f98c00beac6ce9a365693e60f87fb76b6cad6fe1d161e80588af6d"
HELM_DIFF_SHA256="504e99410611daa70702362e1b10dc74929df8a912cb3f6b5d21d1ee9d0cb7d9"

ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64|amd64) ARCH=amd64 ;;
  *) die "поддерживается только x86_64/amd64, здесь ${ARCH}" ;;
esac

need_cmd curl
need_cmd tar
need_cmd sha256sum
use_tools

DOWNLOAD_DIR="${TOOLS_DIR}/download"
mkdir -p "${TOOLS_BIN}" "${DOWNLOAD_DIR}"

# fetch <url> <sha256> <имя файла в .tools/download>
fetch() {
  local url="$1" sha="$2" name="$3"
  local out="${DOWNLOAD_DIR}/${name}"
  if [ -f "${out}" ] && printf '%s  %s\n' "${sha}" "${out}" | sha256sum -c --status -; then
    info "уже скачано: ${name}"
    return 0
  fi
  info "скачиваю ${name}"
  if ! curl -fL --retry 3 --connect-timeout 15 -o "${out}.part" "${url}"; then
    rm -f "${out}.part"
    die "не удалось скачать ${url}"
  fi
  if ! printf '%s  %s\n' "${sha}" "${out}.part" | sha256sum -c --status -; then
    rm -f "${out}.part"
    die "sha256 не совпал: ${name} (ожидали ${sha})"
  fi
  mv "${out}.part" "${out}"
}

# have <бинарник> <ожидаемая версия> <команда проверки...>
have() {
  local bin="$1" expected="$2" out=""
  shift 2
  [ -x "${TOOLS_BIN}/${bin}" ] || return 1
  # Без `head`: под pipefail SIGPIPE от вовремя закрытого grep делал бы проверку
  # ложноположительной/ложноотрицательной в зависимости от порядка команд.
  out="$("$@" 2>/dev/null || true)"
  grep -q -- "${expected}" <<<"${out}"
}

extract_bin() { # <архив> <путь внутри архива> <имя в .tools/bin> <сколько компонентов пути срезать>
  local archive="$1" member="$2" name="$3" strip="$4" tmp
  tmp="$(mktemp -d "${DOWNLOAD_DIR}/extract.XXXXXX")"
  tar -xzf "${archive}" -C "${tmp}" --strip-components="${strip}" "${member}"
  install -m 0755 "${tmp}/$(basename "${member}")" "${TOOLS_BIN}/${name}"
  rm -rf "${tmp}"
}

if have helm "${HELM_VERSION}" helm version --template '{{.Version}}'; then
  info "helm ${HELM_VERSION} уже установлен"
else
  fetch "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" \
    "${HELM_SHA256}" "helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
  extract_bin "${DOWNLOAD_DIR}/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" \
    "linux-${ARCH}/helm" helm 1
  info "установлен helm ${HELM_VERSION}"
fi

if have helmfile "${HELMFILE_VERSION#v}" helmfile --version; then
  info "helmfile ${HELMFILE_VERSION} уже установлен"
else
  fetch "https://github.com/helmfile/helmfile/releases/download/${HELMFILE_VERSION}/helmfile_${HELMFILE_VERSION#v}_linux_${ARCH}.tar.gz" \
    "${HELMFILE_SHA256}" "helmfile_${HELMFILE_VERSION#v}_linux_${ARCH}.tar.gz"
  extract_bin "${DOWNLOAD_DIR}/helmfile_${HELMFILE_VERSION#v}_linux_${ARCH}.tar.gz" helmfile helmfile 0
  info "установлен helmfile ${HELMFILE_VERSION}"
fi

if have kubectl "${KUBECTL_VERSION}" kubectl version --client; then
  info "kubectl ${KUBECTL_VERSION} уже установлен"
else
  fetch "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" \
    "${KUBECTL_SHA256}" "kubectl-${KUBECTL_VERSION}"
  install -m 0755 "${DOWNLOAD_DIR}/kubectl-${KUBECTL_VERSION}" "${TOOLS_BIN}/kubectl"
  info "установлен kubectl ${KUBECTL_VERSION}"
fi

if have kubeconform "${KUBECONFORM_VERSION#v}" kubeconform -v; then
  info "kubeconform ${KUBECONFORM_VERSION} уже установлен"
else
  fetch "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-linux-${ARCH}.tar.gz" \
    "${KUBECONFORM_SHA256}" "kubeconform-linux-${ARCH}.tar.gz"
  extract_bin "${DOWNLOAD_DIR}/kubeconform-linux-${ARCH}.tar.gz" kubeconform kubeconform 0
  info "установлен kubeconform ${KUBECONFORM_VERSION}"
fi

if have promtool "${PROMETHEUS_VERSION#v}" promtool --version; then
  info "promtool ${PROMETHEUS_VERSION} уже установлен"
else
  fetch "https://github.com/prometheus/prometheus/releases/download/${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION#v}.linux-${ARCH}.tar.gz" \
    "${PROMETHEUS_SHA256}" "prometheus-${PROMETHEUS_VERSION#v}.linux-${ARCH}.tar.gz"
  extract_bin "${DOWNLOAD_DIR}/prometheus-${PROMETHEUS_VERSION#v}.linux-${ARCH}.tar.gz" \
    "prometheus-${PROMETHEUS_VERSION#v}.linux-${ARCH}/promtool" promtool 1
  info "установлен promtool ${PROMETHEUS_VERSION}"
fi

# `alloy validate` нужен шагу ворот «конфиг Alloy: alloy validate»: он ловит синтаксис,
# неизвестные свойства и несуществующие компоненты, которых grep не видит.
# Архив с бинарём — zip (tar-архива в релизах нет), поэтому распаковываем python3.
if have alloy "${ALLOY_VERSION#v}" alloy --version; then
  info "alloy ${ALLOY_VERSION} уже установлен"
else
  need_cmd python3
  fetch "https://github.com/grafana/alloy/releases/download/${ALLOY_VERSION}/alloy-linux-${ARCH}.zip" \
    "${ALLOY_SHA256}" "alloy-linux-${ARCH}.zip"
  tmp_dir="$(mktemp -d "${DOWNLOAD_DIR}/extract.XXXXXX")"
  python3 -m zipfile -e "${DOWNLOAD_DIR}/alloy-linux-${ARCH}.zip" "${tmp_dir}"
  install -m 0755 "${tmp_dir}/alloy-linux-${ARCH}" "${TOOLS_BIN}/alloy"
  rm -rf "${tmp_dir}"
  info "установлен alloy ${ALLOY_VERSION}"
fi

# helm-diff нужен для `helmfile diff/apply`; helmfile template работает и без него.
# Ставим распаковкой проверенного архива: helm plugin install не принимает локальный .tgz.
PLUGINS_DIR="${HELM_DATA_HOME}/plugins"
mkdir -p "${PLUGINS_DIR}"
if [ -f "${PLUGINS_DIR}/diff/plugin.yaml" ]; then
  info "плагин helm-diff уже установлен"
else
  fetch "https://github.com/databus23/helm-diff/releases/download/${HELM_DIFF_VERSION}/diff-${HELM_DIFF_VERSION#v}-linux-${ARCH}.tgz" \
    "${HELM_DIFF_SHA256}" "diff-${HELM_DIFF_VERSION#v}-linux-${ARCH}.tgz"
  tar -xzf "${DOWNLOAD_DIR}/diff-${HELM_DIFF_VERSION#v}-linux-${ARCH}.tgz" -C "${PLUGINS_DIR}"
  chmod +x "${PLUGINS_DIR}/diff/bin/diff" \
    || die "не удалось сделать исполняемым ${PLUGINS_DIR}/diff/bin/diff (плагин helm-diff не заработает)"
  info "установлен плагин helm-diff ${HELM_DIFF_VERSION}"
fi

info "готово. Версии:"
"${TOOLS_BIN}/helm" version --template '  helm {{.Version}}'
printf '\n'
"${TOOLS_BIN}/helmfile" --version | sed 's/^/  /'
"${TOOLS_BIN}/kubectl" version --client 2>/dev/null | sed -n '1p' | sed 's/^/  /'
"${TOOLS_BIN}/kubeconform" -v | sed 's/^/  /'
"${TOOLS_BIN}/promtool" --version | sed -n '1p' | sed 's/^/  /'
"${TOOLS_BIN}/alloy" --version | sed -n '1p' | sed 's/^/  /'
"${TOOLS_BIN}/helm" plugin list | sed 's/^/  /'

info "инструменты в ${TOOLS_BIN} (каталог .tools/ вне git); PATH и HELM_*_HOME выставляет scripts/lib.sh:use_tools"
