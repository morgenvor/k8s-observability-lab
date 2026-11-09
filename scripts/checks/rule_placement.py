#!/usr/bin/env python3
"""Ассерт размещения правил: метки под селектор оператора, namespace и членство.

Выгрузка для promtool берёт только `spec.groups` (шаг 5 ворот), поэтому
`metadata.labels` и `metadata.namespace` там не проверяются вообще. Новый файл,
скопированный без метки `release=monitoring`, пройдёт promtool, unit-тесты и проверку
ссылок, а оператор его никогда не загрузит — тишина без ошибки. То же с членством:
ворота обходят `rules/*.yaml` глобом, а применяется только список из
`rules/kustomization.yaml`, и файл, забытый в списке, проверен, но не задеплоен.

Namespace правил равен namespace Prometheus — это соглашение проекта (правила лежат
рядом с оператором; на 2026-11-09 — 6/6), а не требование `ruleNamespaceSelector`:
он пуст, то есть покрывает все namespace.

Использование:
  rule_placement.py <helmfile-render> <kustomize-render> <rules-dir> <rules-kustomization>
"""

import os
import sys

import yaml

from common import fail, find, load_docs, require_api, selector_missing


def main():
    if len(sys.argv) != 5:
        fail(
            "использование: rule_placement.py <helmfile-render> <kustomize-render>"
            " <rules-dir> <rules-kustomization>"
        )
    helmfile_path, kustomize_path, rules_dir, rules_kustomization = sys.argv[1:5]
    render = load_docs(helmfile_path)
    kustomize = load_docs(kustomize_path)

    prometheus = find(render, "Prometheus", where="рендере helmfile")
    prometheus_ns = (prometheus.get("metadata") or {}).get("namespace")
    selector = (prometheus.get("spec") or {}).get("ruleSelector") or {}

    rules = [doc for doc in kustomize if doc.get("kind") == "PrometheusRule"]
    if not rules:
        fail("в рендере kustomize нет ни одного PrometheusRule — правила не доедут до кластера")

    for rule in rules:
        meta = rule.get("metadata") or {}
        name = meta.get("name")
        if not name:
            fail("PrometheusRule без metadata.name в рендере kustomize")
        require_api(rule, "monitoring.coreos.com/v1", f"PrometheusRule {name}")
        missing = selector_missing(meta.get("labels"), selector, f"PrometheusRule {name}")
        if missing:
            fail(
                f"PrometheusRule {name}: метки не удовлетворяют ruleSelector Prometheus"
                f" (нет {', '.join(missing)}) — оператор его не загрузит, правила молча исчезнут"
            )
        if meta.get("namespace") != prometheus_ns:
            fail(
                f"PrometheusRule {name}: namespace={meta.get('namespace')!r}, ожидался"
                f" {prometheus_ns!r} — соглашение проекта: правила лежат рядом с оператором"
            )

    with open(rules_kustomization, encoding="utf-8") as handle:
        kustomization = yaml.safe_load(handle) or {}
    listed = {os.path.basename(str(item)) for item in kustomization.get("resources") or []}
    # Служебный kustomization.yaml в rules/ — не правило; имя переданного файла
    # исключается тоже, чтобы негативный прогон на копии под другим именем не шумел.
    skip = {"kustomization.yaml", os.path.basename(rules_kustomization)}
    on_disk = {
        name
        for name in os.listdir(rules_dir)
        if name.endswith((".yaml", ".yml")) and name not in skip
    }
    not_listed = sorted(on_disk - listed)
    if not_listed:
        fail(
            f"{', '.join(not_listed)}: файл есть в rules/, но не в resources"
            f" {os.path.basename(rules_kustomization)} — ворота его проверят, а kustomize"
            " не применит: правила в кластер не поедут"
        )
    absent = sorted(listed - on_disk)
    if absent:
        fail(
            f"{', '.join(absent)}: есть в resources {os.path.basename(rules_kustomization)},"
            " но не в rules/ — kustomize упадёт на apply"
        )
    for name in sorted(listed):
        path = os.path.join(rules_dir, name)
        with open(path, encoding="utf-8") as handle:
            docs = [doc for doc in yaml.safe_load_all(handle) if isinstance(doc, dict)]
        if not any(doc.get("kind") == "PrometheusRule" for doc in docs):
            fail(
                f"{path}: не PrometheusRule — оператор такой файл не загрузит,"
                " а promtool-выгрузка его молча пропустит"
            )

    print("размещение правил (метки, namespace, членство в kustomization): ok")


main()