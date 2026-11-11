#!/usr/bin/env python3
"""Выгрузка spec.groups из PrometheusRule CRD в файлы для promtool.

`promtool` не умеет читать PrometheusRule («field apiVersion not found in type
rulefmt.RuleGroups»), а правила обязаны быть CRD: оператор находит их по метке
release=monitoring. Поэтому ворота выгружают groups в .tmp и гоняют promtool по ним —
без этого шага ручной promtool не работает вовсе.

Использование: rulefiles.py <каталог-вывода> <файл-правил>...
"""

import os
import sys

import yaml

from common import fail


def main():
    if len(sys.argv) < 3:
        fail("использование: rulefiles.py <каталог-вывода> <файл-правил>...")
    out_dir, paths = sys.argv[1], sys.argv[2:]
    for path in paths:
        with open(path, encoding="utf-8") as handle:
            # safe_load_all: multipart-файл с двумя PrometheusRule иначе потерял бы
            # второй документ — и он молча не поехал бы ни в promtool, ни в кластер.
            docs = list(yaml.safe_load_all(handle))
        rules = [
            doc
            for doc in docs
            if isinstance(doc, dict) and doc.get("kind") == "PrometheusRule"
        ]
        # kustomization.yaml и прочие служебные файлы пропускаем: это не правила.
        if not rules:
            continue
        if len(rules) > 1 and os.path.basename(path) != "kustomization.yaml":
            fail(
                f"{path}: {len(rules)} PrometheusRule в одном файле — выгрузка пишет один"
                " выходной файл на входной и потеряла бы остальные"
            )
        doc = rules[0]
        groups = (doc.get("spec") or {}).get("groups")
        if not groups:
            fail(f"{path}: в PrometheusRule нет spec.groups")
        name = os.path.basename(path)
        with open(os.path.join(out_dir, name), "w", encoding="utf-8") as handle:
            yaml.safe_dump({"groups": groups}, handle, sort_keys=False, allow_unicode=True)
        print(f"  {name}: групп {len(groups)}")


main()