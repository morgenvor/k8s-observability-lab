"""Общие помощники офлайн-ассертов ворот (scripts/check.sh).

Ассерт — отдельный файл, который запускают как `python3 scripts/checks/<имя>.py <аргументы>`.
При успехе печатает одну строку «ok», при нарушении инварианта падает с понятным
сообщением (код 1, текст в stderr) — `check.sh` под `set -e` превращает это в
провал шага. Вынос из heredoc'ов даёт то, чего не было раньше: файл можно запустить
руками на мутированной копии рендера и покрыть тестами.

Зависимость только PyYAML: он уже требуется остальным шагам ворот.
"""

import sys

import yaml


def fail(message):
    sys.exit(message)


def load_docs(path):
    """Все YAML-документы файла; не-словари (пустые `---`, скаляры) отбрасываются."""
    try:
        with open(path, encoding="utf-8") as handle:
            docs = list(yaml.safe_load_all(handle))
    except OSError as exc:
        fail(f"{path}: не читается ({exc})")
    except yaml.YAMLError as exc:
        fail(f"{path}: не разбирается как YAML ({exc})")
    return [doc for doc in docs if isinstance(doc, dict)]


def find_all(docs, kind, name=None):
    return [
        doc
        for doc in docs
        if doc.get("kind") == kind
        and (name is None or (doc.get("metadata") or {}).get("name") == name)
    ]


def find(docs, kind, name=None, where="рендере"):
    """Ровно один объект kind[/name]; иначе провал с указанием, где искали."""
    found = find_all(docs, kind, name)
    target = kind if name is None else f"{kind} {name}"
    if not found:
        fail(f"{target}: нет в {where} (проверь values, версию чарта и список resources)")
    if len(found) > 1:
        names = ", ".join(str((doc.get("metadata") or {}).get("name")) for doc in found)
        fail(f"{kind}: в {where} найдено {len(found)} объектов ({names}), ожидался один")
    return found[0]


def finder(docs, where="рендере"):
    """Функция find(kind, name) для конкретного рендера — вместо копии поиска в файле."""

    def find_one(kind, name=None):
        return find(docs, kind, name, where=where)

    return find_one


def require_api(doc, expected, where):
    """apiVersion не проверяет kubeconform (--ignore-missing-schemas), но apply его видит."""
    actual = doc.get("apiVersion")
    if actual != expected:
        name = (doc.get("metadata") or {}).get("name")
        fail(
            f"{where}: {doc.get('kind')} {name} apiVersion={actual!r}, ожидался {expected!r}"
            " — неверная версия CRD провалится только на apply"
        )


def selector_missing(labels, selector, where):
    """Список невыполненных matchLabels; matchExpressions — явный провал, не молчание."""
    selector = selector or {}
    if "matchExpressions" in selector:
        fail(
            f"{where}: matchExpressions не поддерживаются ассертами —"
            " расширь scripts/checks/common.py, а не пропускай селектор"
        )
    return [
        f"{key}={value}"
        for key, value in (selector.get("matchLabels") or {}).items()
        if (labels or {}).get(key) != value
    ]