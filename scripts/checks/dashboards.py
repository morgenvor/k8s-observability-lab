#!/usr/bin/env python3
"""Ассерты дашбордов Grafana: всё, на что ссылаются панели, должно существовать.

Дашборд — JSON внутри ConfigMap, поэтому его не видит ни kubeconform (схема ConfigMap
безразлична к содержимому), ни jq (только синтаксис). Ошибка в имени метрики, в uid
datasource или в селекторе Loki выглядит как рабочая панель «No data»: отличить «ничего
не происходит» от «панель сломана» по экрану нельзя. Ассерт проверяет то, что реально
ломается при правке дашборда:

1. `uid` есть и уникален — иначе Grafana перезапишет один дашборд другим, а ссылки
   `dashboard_url` из алертов начнут открывать чужую панель;
2. datasource панели и цели — только существующий uid: `prometheus` (дефолт чарта) или
   uid из `grafana.additionalDataSources` в `helm/values/kps.yaml`;
3. каждая метрика `alertsink_*` в выражении Prometheus объявлена в `sink.js` (либо это
   дефолтная процессная метрика prom-client с тем же префиксом);
4. `namespace` в селекторах Loki входит в список, который читает Alloy (`helm/values/alloy.yaml`):
   иначе панель пуста при живых правилах и метриках.

Использование: dashboards.py <корень-проекта>
"""

import glob
import json
import os
import re
import sys

import yaml

from common import fail

# Дефолтный uid Prometheus-датасорса чарта kube-prometheus-stack: он не наш, поэтому
# в values его нет, а панели на него ссылаются.
CHART_PROMETHEUS_UID = "prometheus"
# prom-client добавляет свои метрики с нашим префиксом (collectDefaultMetrics в
# sink.js): их имён в исходнике нет, но панелям они доступны.
DEFAULT_METRIC_PREFIXES = ("alertsink_process_", "alertsink_nodejs_")


def load_json(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except OSError as exc:
        fail(f"{path}: не читается ({exc})")
    except json.JSONDecodeError as exc:
        fail(f"{path}: не разбирается как JSON ({exc})")


def read_text(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except OSError as exc:
        fail(f"{path}: не читается ({exc})")


def datasource_uid(value, where):
    """uid датасорса из ссылки панели; поддерживаются обе формы Grafana (объект и строка)."""
    if value is None:
        return None
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        uid = value.get("uid")
        if not isinstance(uid, str) or not uid:
            fail(f"{where}: datasource без uid — панель не привязана к источнику данных")
        return uid
    fail(f"{where}: datasource неожиданного вида: {value!r}")


def iter_panels(panels):
    for panel in panels or []:
        yield panel
        yield from iter_panels(panel.get("panels"))


def allowed_datasources(root):
    values_path = os.path.join(root, "helm", "values", "kps.yaml")
    try:
        values = yaml.safe_load(read_text(values_path)) or {}
    except yaml.YAMLError as exc:
        fail(f"{values_path}: не разбирается как YAML ({exc})")
    grafana = (values.get("grafana") or {})
    uids = {CHART_PROMETHEUS_UID}
    for source in grafana.get("additionalDataSources") or []:
        uid = (source or {}).get("uid")
        if isinstance(uid, str) and uid:
            uids.add(uid)
    return uids


def declared_metrics(root):
    """Имена метрик, объявленных в приложениях: `name: '<метрика>'` в исходниках."""
    names = set()
    for path in glob.glob(os.path.join(root, "app", "*", "src", "*.js")):
        names.update(re.findall(r"name:\s*'([a-z][a-z0-9_]*)'", read_text(path)))
    return names


def alloy_namespaces(root):
    """Namespace, которые реально читает Alloy: `names = [...]` в HCL-конфиге."""
    text = read_text(os.path.join(root, "helm", "values", "alloy.yaml"))
    names = set()
    for raw in re.findall(r"\bnames\s*=\s*\[([^\]]*)\]", text):
        names.update(item.strip().strip('"') for item in raw.split(",") if item.strip())
    if not names:
        fail(
            "helm/values/alloy.yaml: не найден список names в discovery.kubernetes —"
            " проверка селекторов Loki без него бессмысленна"
        )
    return names


def main():
    if len(sys.argv) != 2:
        fail("использование: dashboards.py <корень-проекта>")
    root = sys.argv[1]
    paths = sorted(glob.glob(os.path.join(root, "deploy", "dashboards", "*.json")))
    if not paths:
        fail("deploy/dashboards/*.json: нет ни одного дашборда — проверять нечего")

    datasources = allowed_datasources(root)
    metrics = declared_metrics(root)
    namespaces = alloy_namespaces(root)

    seen_uids = {}
    panels_checked = 0
    for path in paths:
        where_file = os.path.relpath(path, root)
        dashboard = load_json(path)
        uid = dashboard.get("uid")
        if not isinstance(uid, str) or not uid:
            fail(f"{where_file}: нет uid — ссылка dashboard_url ведёт в никуда")
        if uid in seen_uids:
            fail(
                f"{where_file}: uid '{uid}' уже занят дашбордом {seen_uids[uid]}."
                " Один затрёт другой, и ссылка из алерта откроет чужую панель"
            )
        seen_uids[uid] = where_file

        panels = dashboard.get("panels") or []
        if not panels:
            fail(f"{where_file}: нет панелей — дашборд пуст")

        for panel in iter_panels(panels):
            panels_checked += 1
            where = f"{where_file}: панель «{panel.get('title')}»"
            panel_uid = datasource_uid(panel.get("datasource"), where)
            if panel_uid is not None and panel_uid not in datasources:
                fail(
                    f"{where}: datasource uid '{panel_uid}' не объявлен (есть:"
                    f" {sorted(datasources)}) — панель останется без данных"
                )
            for target in panel.get("targets") or []:
                target_uid = datasource_uid(target.get("datasource"), where) or panel_uid
                if target_uid is None:
                    fail(f"{where}: у цели нет datasource — неясно, куда идёт запрос")
                if target_uid not in datasources:
                    fail(
                        f"{where}: цель ссылается на datasource uid '{target_uid}',"
                        f" которого нет (есть: {sorted(datasources)})"
                    )
                expr = target.get("expr")
                if not isinstance(expr, str) or not expr.strip():
                    fail(f"{where}: у цели нет expr — панель нарисует пустоту")
                if target_uid == CHART_PROMETHEUS_UID:
                    for metric in re.findall(r"\b(alertsink_[a-z0-9_]+)\b", expr):
                        if metric in metrics or metric.startswith(DEFAULT_METRIC_PREFIXES):
                            continue
                        fail(
                            f"{where}: метрики '{metric}' нет в исходнике app/*/src/*.js —"
                            " опечатка даёт пустую панель, а не ошибку"
                        )
                else:
                    # Селектор Loki по namespace: собирает только то, что читает Alloy.
                    for namespace in re.findall(r'namespace\s*=\s*"([^"]+)"', expr):
                        if namespace not in namespaces:
                            fail(
                                f"{where}: селектор по namespace=\"{namespace}\", а Alloy"
                                f" читает только {sorted(namespaces)} — панель будет пуста"
                            )

    print(
        f"дашборды: проверено {len(paths)} файлов, панелей {panels_checked},"
        f" datasource {sorted(datasources)}, метрик {len(metrics)}"
    )


main()