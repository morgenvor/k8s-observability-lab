#!/usr/bin/env python3
"""Выгрузка config.alloy из рендера чарта в файл.

В манифесте конфиг лежит блоком с отступом, поэтому якорь `^loki.process` там не
сработал бы, а grep по подстроке проходит даже на закомментированном компоненте
(ревью 2026-11-09: конфиг ссылался на несуществующий drop_old, Alloy не стартовал,
сбор логов вставал целиком). По выгруженному файлу дальше идут grep-ассерты и
`alloy validate`.

Использование: alloy_config.py <helmfile-render> <куда-писать>
"""

import sys

from common import fail, find, load_docs


def main():
    if len(sys.argv) != 3:
        fail("использование: alloy_config.py <helmfile-render> <куда-писать>")
    render_path, out_path = sys.argv[1], sys.argv[2]
    config_map = find(load_docs(render_path), "ConfigMap", "alloy", where="рендере helmfile")
    config = (config_map.get("data") or {}).get("config.alloy")
    if not config:
        fail("ConfigMap alloy: нет ключа config.alloy — чарт сменил раскладку ключей")
    with open(out_path, "w", encoding="utf-8") as handle:
        handle.write(config)
    print(f"конфиг Alloy выгружен: {len(config.splitlines())} строк")


main()