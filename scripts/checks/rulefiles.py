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
            doc = yaml.safe_load(handle)
        # kustomization.yaml и прочие служебные файлы пропускаем: это не правила.
        if not isinstance(doc, dict) or doc.get("kind") != "PrometheusRule":
            continue
        groups = (doc.get("spec") or {}).get("groups")
        if not groups:
            fail(f"{path}: в PrometheusRule нет spec.groups")
        name = os.path.basename(path)
        with open(os.path.join(out_dir, name), "w", encoding="utf-8") as handle:
            yaml.safe_dump({"groups": groups}, handle, sort_keys=False, allow_unicode=True)
        print(f"  {name}: групп {len(groups)}")


main()