#!/usr/bin/env python3
"""Ассерт покрытия правил юнит-тестами и соглашения о `severity`.

`promtool test rules` проверяет только те правила, для которых есть тест, и только тот
сценарий, который в тесте описан: новый алерт без теста проходит ворота молча, а алерт,
у которого есть только кейс «не горит», не проверен на срабатывание вовсе — сломанное
выражение, которое никогда не станет истинным, выглядит как зелёный тест.

Опечатка в `severity` не ломает ни promtool, ни рендер, но уводит уведомление в
catch-all. Соглашение проекта: `severity ∈ {page, ticket}`,
`info` не ставим, потому что чартовый `InfoInhibitor` глушит одиночный info.

Использование: rule_coverage.py <каталог-rulefiles> <каталог-тестов>
"""

import glob
import os
import sys

from common import fail, load_docs

SEVERITIES = {"page", "ticket"}

# Алерты, у которых тест описывает только «не горит». Список пуст: срабатывающие кейсы
# есть у всех, включая medium/slow (7 % ошибок 8 часов и 6 % медленных три дня).
# Механизм оставлен на будущее: новый алерт без срабатывающего кейса валит ворота, а
# когда кейс появится, запись надо убрать (ассерт это проверит).
NEGATIVE_ONLY_ALLOWED = set()


def alert_definitions(rulefiles_dir):
    """Все объявления алертов. Дубль имени — провал: иначе проверяется только последний."""
    definitions = []
    sources = {}
    for path in sorted(glob.glob(os.path.join(rulefiles_dir, "*.yaml"))):
        for doc in load_docs(path):
            for group in doc.get("groups") or []:
                for rule in group.get("rules") or []:
                    name = rule.get("alert")
                    if not name:
                        continue
                    definitions.append((name, rule))
                    sources.setdefault(name, []).append(os.path.basename(path))
    duplicated = {name: files for name, files in sources.items() if len(files) > 1}
    if duplicated:
        detail = "; ".join(f"{name} ({', '.join(files)})" for name, files in sorted(duplicated.items()))
        fail(
            f"алерт объявлен несколько раз под одним именем: {detail} —"
            " проверялось бы только последнее определение, остальные ушли бы в кластер"
        )
    if not definitions:
        fail(f"{rulefiles_dir}: не найдено ни одного алерта — проверять нечего")
    return definitions


def test_cases(tests_dir):
    paths = sorted(glob.glob(os.path.join(tests_dir, "*.test.yaml")))
    if not paths:
        fail(f"{tests_dir}: нет файлов *.test.yaml — promtool test rules нечего проверять")
    cases = {}
    for path in paths:
        for doc in load_docs(path):
            for test in doc.get("tests") or []:
                for entry in test.get("alert_rule_test") or []:
                    name = entry.get("alertname")
                    if not name:
                        continue
                    stats = cases.setdefault(name, {"cases": 0, "firing": 0})
                    stats["cases"] += 1
                    if entry.get("exp_alerts"):
                        stats["firing"] += 1
    return cases


def main():
    if len(sys.argv) != 3:
        fail("использование: rule_coverage.py <каталог-rulefiles> <каталог-тестов>")
    rulefiles_dir, tests_dir = sys.argv[1], sys.argv[2]

    definitions = alert_definitions(rulefiles_dir)
    for name, rule in definitions:
        severity = (rule.get("labels") or {}).get("severity")
        if severity not in SEVERITIES:
            hint = (
                " `info` глушится чартовым InfoInhibitor и до alert-sink не доходит"
                if severity == "info"
                else ""
            )
            fail(
                f"{name}: severity={severity!r}, ожидалось одно из {sorted(SEVERITIES)}."
                f"{hint} (соглашение проекта)"
            )
        if not rule.get("for"):
            fail(f"{name}: не задан `for` — алерт срабатывает мгновенно, без окна на флап")
        annotations = rule.get("annotations") or {}
        # description обязателен: шаблон письма печатает `.Annotations.description`, и
        # новый алерт без него дал бы письмо без оценки масштаба при зелёных воротах.
        for key in ("summary", "description", "runbook_url"):
            if not annotations.get(key):
                fail(f"{name}: пустой annotations.{key} — уведомление без описания или процедуры")

    names = {name for name, _ in definitions}
    cases = test_cases(tests_dir)

    untested = sorted(names - set(cases))
    if untested:
        fail(
            f"алерты без теста в {tests_dir}: {', '.join(untested)} —"
            " promtool проверяет только покрытые, новый алерт прошёл бы молча"
        )
    orphan = sorted(set(cases) - names)
    if orphan:
        fail(
            f"тесты ссылаются на несуществующие алерты: {', '.join(orphan)} —"
            " переименование правила оставило тест «зелёным»"
        )

    silent = sorted(
        name for name in cases if cases[name]["firing"] == 0 and name not in NEGATIVE_ONLY_ALLOWED
    )
    if silent:
        fail(
            f"тесты этих алертов описывают только «не горит»: {', '.join(silent)} —"
            " сломанное выражение, которое никогда не станет истинным, прошло бы проверку."
            " Добавь кейс с непустым exp_alerts"
        )
    stale = sorted(
        name for name in NEGATIVE_ONLY_ALLOWED if cases.get(name, {}).get("firing", 0) > 0
    )
    if stale:
        fail(
            f"запись в NEGATIVE_ONLY_ALLOWED устарела: у {', '.join(stale)} уже есть"
            " срабатывающий кейс — убери имя из списка в rule_coverage.py"
        )

    firing = sum(1 for name in cases if cases[name]["firing"] > 0)
    print(
        f"правила: алертов {len(names)}, покрыто тестами {len(cases)},"
        f" со срабатывающим кейсом {firing}, severity ∈ {{page, ticket}}"
    )


main()