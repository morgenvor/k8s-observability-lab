#!/usr/bin/env python3
"""Ассерт паритета двух путей деплоя: `kubectl apply -k .` и `scripts/deploy.sh`.

`deploy.sh` рендерит оверлей через `render_demo_manifests` (`scripts/lib.sh`), и список
каталогов там задан руками. Сам `kustomization.yaml` правится легко, второй список —
забывается: `kubectl apply -k .` применит новый каталог, а `deploy.sh` нет. Поэтому
сравниваются наборы `kind/name` в обоих рендерах, а не тексты файлов.

Генерируемые имена ConfigMap сравниваются как есть: оба рендера идут одним и тем же
kustomize, суффиксы хешей совпадают. Если появятся `configMapGenerator` с разным
поведением, ассерт честно упадёт и потребует решения — это лучше, чем пропустить
расхождение.

Использование: overlay_parity.py <kustomize-render> <overlay-render>
"""

import sys

from common import fail, load_docs


def objects(path):
    found = set()
    for doc in load_docs(path):
        kind = doc.get("kind")
        name = (doc.get("metadata") or {}).get("name")
        if kind and name:
            found.add((kind, name))
    return found


def describe(items):
    return ", ".join(f"{kind}/{name}" for kind, name in items)


def main():
    if len(sys.argv) != 3:
        fail("использование: overlay_parity.py <kustomize-render> <overlay-render>")
    base_path, overlay_path = sys.argv[1], sys.argv[2]
    base = objects(base_path)
    overlay = objects(overlay_path)

    if not base:
        fail(f"{base_path}: рендер пуст — сравнивать нечего")
    only_base = sorted(base - overlay)
    only_overlay = sorted(overlay - base)
    if not only_base and not only_overlay:
        print(f"паритет оверлея деплоя и kustomization: {len(base)} объектов")
        return

    message = [
        f"паритет деплоя нарушен: {base_path} и {overlay_path} разошлись",
    ]
    if only_base:
        message.append(f"только в kustomization.yaml: {describe(only_base)}")
    if only_overlay:
        message.append(f"только в оверлее deploy.sh: {describe(only_overlay)}")
    message.append(
        "проверь список resources в scripts/lib.sh (render_demo_manifests) — он должен"
        " совпадать с kustomization.yaml, иначе два пути деплоя применяют разное"
    )
    fail("\n".join(message))


main()