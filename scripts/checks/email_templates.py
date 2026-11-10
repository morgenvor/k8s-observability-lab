#!/usr/bin/env python3
"""Выгружает text и html письма из рендера AlertmanagerConfig в отдельные файлы.

Зачем отдельный шаг: шаблон письма — обычный текст внутри YAML, и его ошибки не видит ни
kubeconform, ни promtool. Проверяются они рендером (scripts/checks/email_template.go), а
Go-часть не должна уметь читать YAML: PyYAML в проекте уже есть, а сторонние модули в
воротах не появляются.

Использование: email_templates.py <render.yaml> <каталог для выгрузки>
"""

import sys

from common import fail, find, load_docs


def main():
    if len(sys.argv) != 3:
        fail("использование: email_templates.py <render.yaml> <каталог для выгрузки>")
    render, out_dir = sys.argv[1], sys.argv[2]

    spec = find(
        load_docs(render), "AlertmanagerConfig", "demo-notifications", where=f"рендере {render}"
    ).get("spec") or {}
    receivers = spec.get("receivers") or []
    if len(receivers) < 2 or not receivers[1].get("emailConfigs"):
        fail(f"в {render} у receivers[1] нет emailConfigs — выгружать нечего")
    email = receivers[1]["emailConfigs"][0]

    # Пустой шаблон — не «нет письма», а сломанный конфиг: без него шаг ниже зеленел бы.
    for field in ("text", "html"):
        body = email.get(field) or ""
        if not body.strip():
            fail(f"в {render} emailConfigs[0].{field} пуст")
        path = f"{out_dir}/email-{field}.tpl"
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(body)
        print(f"  {field}: {len(body)} символов -> {path}")


main()