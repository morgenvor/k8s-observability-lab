#!/usr/bin/env python3
"""Ассерты ссылок в алертах: runbook_url и dashboard_url должны резолвиться.

Ссылка в аннотации — единственный путь от уведомления к процедуре, и её не проверяет
ни promtool (синтаксис выражения), ни kubeconform (схема CRD). Анкор считается по
правилам GitHub: заголовки `##`/`###` вне код-фенсов, пунктуация вырезается, повторный
заголовок получает суффикс `-1`. Ноль проверенных ссылок — провал, а не «всё хорошо».

Использование: alert_links.py <каталог-rulefiles> <корень-проекта>
"""

import glob
import json
import os
import re
import sys

import yaml

RUNBOOK = "https://github.com/morgenvor/k8s-observability-lab/blob/main/docs/runbook.md#"
DASHBOARD = "http://grafana.lab.internal/d/"


def slug(heading):
    # Алгоритм GitHub: нижний регистр, пунктуация вырезается, пробелы -> дефис.
    text = heading.strip().lower()
    text = re.sub(r"[^\w\- ]", "", text, flags=re.UNICODE)
    return text.replace(" ", "-")


def collect_anchors(path):
    anchors = {}
    suffix_seen = {}
    in_fence = False
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            # Заголовки внутри код-фенсов GitHub анкорами не считает: без этого
            # "<<## ...>>" в примере дал бы анкор, который в реальности не резолвится.
            if line.lstrip().startswith("```"):
                in_fence = not in_fence
                continue
            if in_fence:
                continue
            match = re.match(r"#{2,3} +(.+?)\s*$", line)
            if not match:
                continue
            base = slug(match.group(1))
            # Повторный заголовок GitHub делает "slug-1", "slug-2": без этого ссылка
            # на второй такой заголовок выглядела бы мёртвой, хотя она работает.
            if base in anchors:
                suffix_seen[base] = suffix_seen.get(base, 1) + 1
                anchors[f"{base}-{suffix_seen[base] - 1}"] = match.group(1)
            else:
                anchors[base] = match.group(1)
    return anchors


def main():
    if len(sys.argv) != 3:
        sys.exit("использование: alert_links.py <каталог-rulefiles> <корень-проекта>")
    rulefiles_dir, root = sys.argv[1], sys.argv[2]

    anchors = collect_anchors(os.path.join(root, "docs", "runbook.md"))
    if not anchors:
        sys.exit("в docs/runbook.md не найдено ни одного заголовка ##/###")

    uids = {}
    for path in glob.glob(os.path.join(root, "deploy", "dashboards", "*.json")):
        with open(path, encoding="utf-8") as handle:
            uid = json.load(handle).get("uid")
        if uid:
            uids[uid] = path
    if not uids:
        sys.exit("в deploy/dashboards/*.json нет ни одного uid")

    errors = []
    checked = {"runbook": 0, "dashboard": 0}
    # Источники алертов: правила Prometheus (выгруженные из CRD groups) и правила Loki ruler
    # (свой формат, CRD нет). Второй источник добавлен в фазе 5 v1.1: иначе единственный
    # алерт, чья ссылка ведёт к человеку, никем бы не проверялся.
    sources = [
        (path, os.path.join("rules", os.path.basename(path)))
        for path in sorted(glob.glob(os.path.join(rulefiles_dir, "*.yaml")))
    ]
    sources += [
        (path, path)
        for path in sorted(glob.glob(os.path.join(root, "deploy", "loki-rules", "*.yaml")))
    ]
    for path, source in sources:
        with open(path, encoding="utf-8") as handle:
            doc = yaml.safe_load(handle)
        for group in (doc or {}).get("groups") or []:
            for rule in group.get("rules") or []:
                if "alert" not in rule:
                    continue
                annotations = rule.get("annotations") or {}
                where = f"{source}: {rule['alert']}"
                runbook = annotations.get("runbook_url")
                if not runbook:
                    errors.append(f"{where}: нет runbook_url — уведомление не ведёт в процедуру")
                elif not runbook.startswith(RUNBOOK):
                    errors.append(f"{where}: runbook_url не абсолютный или мимо файла: {runbook}")
                else:
                    anchor = runbook[len(RUNBOOK):]
                    if anchor not in anchors:
                        errors.append(
                            f"{where}: анкора #{anchor} нет в docs/runbook.md"
                            f" (ближайшие заголовки: {', '.join(sorted(anchors)[:8])})"
                        )
                    checked["runbook"] += 1
                dashboard = annotations.get("dashboard_url")
                if dashboard:
                    if not dashboard.startswith(DASHBOARD):
                        errors.append(f"{where}: dashboard_url не http://grafana.lab.internal/d/<uid>: {dashboard}")
                    elif dashboard[len(DASHBOARD):] not in uids:
                        errors.append(
                            f"{where}: uid '{dashboard[len(DASHBOARD):]}' нет в deploy/dashboards/*.json"
                            f" (есть: {', '.join(sorted(uids))})"
                        )
                    else:
                        checked["dashboard"] += 1
    if errors:
        for error in errors:
            print(f"  {error}", file=sys.stderr)
        sys.exit(f"ссылки в алертах: ошибок {len(errors)}")
    # Ноль проверенных ссылок — не «всё хорошо», а «проверять было нечего»: файл правил
    # без groups прошёл бы через glob молча.
    if not sum(checked.values()):
        sys.exit(f"в {rulefiles_dir} не найдено ни одного алерта со ссылками — проверять нечего")
    print(
        f"проверено ссылок: runbook_url {checked['runbook']},"
        f" dashboard_url {checked['dashboard']}; анкоров в runbook {len(anchors)}"
    )


main()