#!/usr/bin/env python3
"""Скан личных адресов в публикуемом наборе: допустимы только example.invalid/example.com.

Правило 4 AGENTS: реальный адрес получателя — такой же секрет, как IP стенда. Домены
example.* зарезервированы RFC 2606 и намеренно остаются в файлах как плейсхолдеры.
Строки с адресами не печатаются — только файл:строка.

Использование: address_scan.py <файл>...
"""

import re
import sys

from common import fail

# Адрес: local-part@домен с хотя бы одной точкой. Домен без точки (scoped-пакет,
# digest @sha256) адресом не считается.
ADDRESS = re.compile(r"[A-Za-z0-9._%+-]+[@][A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+")
ALLOWED = re.compile(r"[@](?:example[.]invalid|example[.]com)$", re.IGNORECASE)


def main():
    bad = []
    seen = 0
    for path in sys.argv[1:]:
        try:
            with open(path, encoding="utf-8", errors="replace") as handle:
                text = handle.read()
        except OSError as exc:
            # Пропустить нечитаемый файл — значит дать воротам зелёный результат с
            # дырой: файл в индексе есть, а скан его не видел.
            fail(f"{path}: не читается ({exc})")
        # Бинарные файлы (изображения в docs/images) текстом не разбираем: там случайные
        # байты, а секретов в картинке скан всё равно не найдёт — её проверяет человек.
        if "\x00" in text:
            continue
        for number, line in enumerate(text.splitlines(), 1):
            for match in ADDRESS.finditer(line):
                seen += 1
                if not ALLOWED.search(match.group(0)):
                    bad.append(f"{path}:{number}")
    if bad:
        for where in bad:
            print(f"  {where}", file=sys.stderr)
        sys.exit(
            f"найдено адресов вне example.invalid/example.com: {len(bad)}"
            " (файл:строка выше; реальный адрес подставляет окружение, в git только плейсхолдер)"
        )
    print(f"адреса в публикуемом наборе: {seen}, все в example.invalid/example.com")


main()