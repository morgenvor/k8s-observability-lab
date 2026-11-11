#!/usr/bin/env python3
"""Ассерты своих ServiceMonitor: метка release и совпадение селектора с метками подов.

Почему отдельный шаг. `ServiceMonitor` — CRD: kubeconform схему не знает и молчит, а
`release: monitoring` в метке объекта — то, по чему оператор ищет мониторы
(`serviceMonitorSelector` в values чарта). Пропажа метки или рассинхрон
`selector.matchLabels` с метками pod template не ломают ни рендер, ни apply: цели просто
не появляются в Prometheus, `up`-серий нет, и алерты молчат. Живой гейт `deploy.sh` это
ловит только после деплоя, поэтому проверка дублируется офлайн.

Проверяется:
1. в рендере ровно три ServiceMonitor проекта (`demo-api`, `demo-load`, `alert-sink`);
2. у каждого метка `release: monitoring` и порт эндпоинта `http`;
3. `selector.matchLabels` — непустое подмножество меток pod template своего Deployment.

Использование: servicemonitors.py <рендер kustomize>
"""

import sys

from common import fail, find_all, load_docs

OWN = ("demo-api", "demo-load", "alert-sink")


def pod_labels(docs):
    """Метки pod template каждого Deployment рендера."""
    labels = {}
    for doc in find_all(docs, "Deployment"):
        name = (doc.get("metadata") or {}).get("name")
        template = (doc.get("spec") or {}).get("template") or {}
        labels[name] = ((template.get("metadata") or {}).get("labels")) or {}
    return labels


def main():
    if len(sys.argv) != 2:
        fail("использование: servicemonitors.py <рендер kustomize>")
    docs = load_docs(sys.argv[1])

    monitors = {}
    for doc in find_all(docs, "ServiceMonitor"):
        name = (doc.get("metadata") or {}).get("name")
        monitors[name] = doc
    if set(monitors) != set(OWN):
        fail(
            f"ServiceMonitor в рендере: {sorted(monitors)}, ожидались {sorted(OWN)} —"
            " новый сервис без монитора не скрейпится, а удалённый оставит цель без метрик"
        )

    pods = pod_labels(docs)
    for name in OWN:
        monitor = monitors[name]
        labels = (monitor.get("metadata") or {}).get("labels") or {}
        if labels.get("release") != "monitoring":
            fail(
                f"ServiceMonitor {name}: нет метки release=monitoring —"
                " оператор его не найдёт, и цели не будет в Prometheus"
            )
        endpoints = (monitor.get("spec") or {}).get("endpoints") or []
        if not endpoints or endpoints[0].get("port") != "http":
            fail(f"ServiceMonitor {name}: первый эндпоинт не указывает порт 'http' ({endpoints!r})")
        selector = ((monitor.get("spec") or {}).get("selector") or {}).get("matchLabels") or {}
        if not selector:
            fail(f"ServiceMonitor {name}: пустой selector.matchLabels — монитор не выберет ни один Service")
        if name not in pods:
            fail(f"ServiceMonitor {name}: в рендере нет Deployment {name} — селектор не с чем сверить")
        extra = {
            key: value
            for key, value in selector.items()
            if pods[name].get(key) != value
        }
        if extra:
            fail(
                f"ServiceMonitor {name}: selector.matchLabels {extra!r} не совпадает с метками"
                f" pod template ({pods[name]!r}) — цель не появится, а алерты промолчат"
            )

    print(
        "ServiceMonitor'ы: 3 объекта, release=monitoring,"
        " селекторы совпадают с метками подов — ok"
    )


main()