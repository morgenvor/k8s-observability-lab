#!/usr/bin/env python3
"""Ассерт покрытия правил юнит-тестами и соглашения о `severity`.

`promtool test rules` проверяет только те правила, для которых есть тест: новый алерт
без теста проходит ворота молча. То же с `severity`: опечатка (`warning` вместо
`ticket`) не ломает ни promtool, ни рендер, но уводит уведомление в catch-all.

Своё соглашение (AGENTS, раздел «Алерты»): `severity ∈ {page, ticket}`, `info` не
ставим — его глушит чартовый `InfoInhibitor` (`source: alertname="InfoInhibitor"` →
`target: severity="info"`, `equal: [namespace]`), поэтому одиночный info не доходит до
alert-sink.

Использование: rule_coverage.py <каталог-rulefiles> <каталог-тестов>
"""

import glob
import os
import sys

from common import fail, load_docs

SEVERITIES = {"page", "ticket"}


def alerts_in_rules(rulefiles_dir):
    alerts = {}
    for path in sorted(glob.glob(os.path.join(rulefiles_dir, "*.yaml"))):
        for doc in load_docs(path):
            for group in doc.get("groups") or []:
                for rule in group.get("rules") or []:
                    name = rule.get("alert")
                    if name:
                        alerts[name] = rule
    return alerts


def alerts_in_tests(tests_dir):
    paths = sorted(glob.glob(os.path.join(tests_dir, "*.test.yaml")))
    if not paths:
        fail(f"{tests_dir}: нет файлов *.test.yaml — promtool test rules нечего проверять")
    tested = set()
    for path in paths:
        for doc in load_docs(path):
            for case in doc.get("tests") or []:
                for entry in case.get("alert_rule_test") or []:
                    if entry.get("alertname"):
                        tested.add(entry["alertname"])
    return tested


def main():
    if len(sys.argv) != 3:
        fail("использование: rule_coverage.py <каталог-rulefiles> <каталог-тестов>")
    rulefiles_dir, tests_dir = sys.argv[1], sys.argv[2]

    alerts = alerts_in_rules(rulefiles_dir)
    if not alerts:
        fail(f"{rulefiles_dir}: не найдено ни одного алерта — проверять нечего")

    for name, rule in sorted(alerts.items()):
        severity = (rule.get("labels") or {}).get("severity")
        if severity not in SEVERITIES:
            fail(
                f"{name}: severity={severity!r}, ожидалось одно из {sorted(SEVERITIES)}."
                " `info` глушится чартовым InfoInhibitor и до alert-sink не доходит"
                " (AGENTS, раздел «Алерты»)"
            )
        if not rule.get("for"):
            fail(f"{name}: не задан `for` — алерт срабатывает мгновенно, без окна на флап")
        annotations = rule.get("annotations") or {}
        for key in ("summary", "runbook_url"):
            if not annotations.get(key):
                fail(f"{name}: пустой annotations.{key} — уведомление без описания или процедуры")

    tested = alerts_in_tests(tests_dir)
    untested = sorted(set(alerts) - tested)
    if untested:
        fail(
            f"алерты без теста в {tests_dir}: {', '.join(untested)} —"
            " promtool проверяет только покрытые, новый алерт прошёл бы молча"
        )
    orphan = sorted(tested - set(alerts))
    if orphan:
        fail(
            f"тесты ссылаются на несуществующие алерты: {', '.join(orphan)} —"
            " переименование правила оставило тест «зелёным»"
        )

    print(
        f"правила: алертов {len(alerts)}, покрыто тестами {len(tested)},"
        " severity ∈ {page, ticket}"
    )


main()