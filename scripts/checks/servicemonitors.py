#!/usr/bin/env python3
"""Ассерты своих ServiceMonitor: метка release, выбор Service и его порта.

Почему отдельный шаг. `ServiceMonitor` — CRD: kubeconform схему не знает и молчит, а
`release: monitoring` в метке объекта — то, по чему оператор ищет мониторы
(`serviceMonitorSelector` в values чарта). Ошибка в любом звене цепочки не ломает ни
рендер, ни apply: цель просто не появляется в Prometheus, `up`-серий нет, и алерты
молчат. Живой гейт `deploy.sh` это ловит только после деплоя, поэтому проверка
дублируется офлайн.

Цепочка, которую проверяем по рендеру kustomize:
  ServiceMonitor.spec.selector.matchLabels  ⊆  Service.metadata.labels
  ServiceMonitor.spec.endpoints[].port      =  Service.spec.ports[].name
  Service.spec.selector                     ⊆  Deployment.spec.template.metadata.labels
  namespace у всех трёх объектов совпадает

Именно Service, а не под: ServiceMonitor выбирает Service, и пропавшая метка у Service
(при живой метке у пода) даёт ноль целей при зелёных воротах.

Использование: servicemonitors.py <рендер kustomize>
"""

import sys

from common import fail, find_all, load_docs

OWN = ("demo-api", "demo-load", "alert-sink")


def by_name(docs, kind, where, allow_extra=False):
    objects = {}
    for doc in find_all(docs, kind):
        name = (doc.get("metadata") or {}).get("name")
        objects[name] = doc
    missing = set(OWN) - set(objects)
    if missing or (not allow_extra and set(objects) != set(OWN)):
        fail(
            f"{kind} в {where}: {sorted(objects)}, ожидались {sorted(OWN)} —"
            " без любого из трёх объектов цель не скрейпится молча"
        )
    return objects


def namespace(document):
    return (document.get("metadata") or {}).get("namespace")


def pod_labels(deployment):
    template = (deployment.get("spec") or {}).get("template") or {}
    return ((template.get("metadata") or {}).get("labels")) or {}


def main():
    if len(sys.argv) != 2:
        fail("использование: servicemonitors.py <рендер kustomize>")
    docs = load_docs(sys.argv[1])

    monitors = by_name(docs, "ServiceMonitor", "рендере")
    # В рендере есть и Service/Deployment toxiproxy — он не цель Prometheus, поэтому
    # для этих видов требуем наличие трёх своих объектов, но не запрещаем лишние.
    services = by_name(docs, "Service", "рендере", allow_extra=True)
    deployments = by_name(docs, "Deployment", "рендере", allow_extra=True)

    for name in OWN:
        monitor, service, deployment = monitors[name], services[name], deployments[name]

        labels = (monitor.get("metadata") or {}).get("labels") or {}
        if labels.get("release") != "monitoring":
            fail(
                f"ServiceMonitor {name}: нет метки release=monitoring —"
                " оператор его не найдёт, и цели не будет в Prometheus"
            )

        endpoints = (monitor.get("spec") or {}).get("endpoints") or []
        if not endpoints:
            fail(f"ServiceMonitor {name}: нет endpoints — монитор ничего не скрейпит")
        endpoint = endpoints[0]
        port = endpoint.get("port")
        if endpoint.get("path") != "/metrics":
            fail(f"ServiceMonitor {name}: path={endpoint.get('path')!r}, ожидался /metrics")

        selector = ((monitor.get("spec") or {}).get("selector") or {}).get("matchLabels") or {}
        if not selector:
            fail(f"ServiceMonitor {name}: пустой selector.matchLabels — монитор не выберет ни один Service")
        service_labels = (service.get("metadata") or {}).get("labels") or {}
        missed = {key: value for key, value in selector.items() if service_labels.get(key) != value}
        if missed:
            fail(
                f"ServiceMonitor {name}: selector.matchLabels {missed!r} не совпадает с метками"
                f" Service ({service_labels!r}) — цель не появится, а алерты промолчат"
            )

        ports = (service.get("spec") or {}).get("ports") or []
        if not any(item.get("name") == port for item in ports):
            fail(
                f"Service {name}: порта с именем {port!r} нет в {[item.get('name') for item in ports]!r} —"
                " endpoint ServiceMonitor ссылается на несуществующий порт"
            )

        service_selector = (service.get("spec") or {}).get("selector") or {}
        if not service_selector:
            fail(f"Service {name}: пустой spec.selector — endpoints у Service не будет")
        unmatched = {
            key: value
            for key, value in service_selector.items()
            if pod_labels(deployment).get(key) != value
        }
        if unmatched:
            fail(
                f"Service {name}: spec.selector {unmatched!r} не совпадает с метками pod template"
                f" ({pod_labels(deployment)!r}) — endpoints пусты, цель не появится"
            )

        namespaces = {namespace(monitor), namespace(service), namespace(deployment)}
        if len(namespaces) != 1:
            fail(
                f"{name}: ServiceMonitor, Service и Deployment в разных namespace {sorted(map(str, namespaces))}"
                " — оператор ищет Service только в своём namespace"
            )

    print(
        "ServiceMonitor'ы: 3 объекта, release=monitoring, Service выбран по меткам,"
        " порт совпадает, selector Service ⊆ меток подов — ok"
    )


main()