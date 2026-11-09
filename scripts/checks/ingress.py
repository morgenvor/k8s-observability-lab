#!/usr/bin/env python3
"""Ассерты доступа к UI без port-forward: Ingress и внешние URL в рендере.

Публикация UI держится на двух фактах, и оба живут в шаблонах чарта, а не в наших
values: (1) Ingress-объекты с классом traefik и host'ами, (2) внешние URL в CR
Prometheus/Alertmanager и `server.domain` у Grafana, которые чарт выводит из этих
host'ов. Без (2) рабочая страница ссылается на внутренние имена кластера, поэтому
проверяется не «Ingress есть», а согласованность пары.

Использование: ingress.py <helmfile-render>
"""

import sys

from common import fail, finder, load_docs


def main():
    if len(sys.argv) != 2:
        fail("использование: ingress.py <helmfile-render>")
    find = finder(load_docs(sys.argv[1]), "рендере helmfile")

    # host -> (Ingress, backend Service, port). Имена — из ingress-блоков
    # helm/values/kps.yaml; /etc/hosts на рабочей машине должен указывать на ноду,
    # иначе Traefik отвечает 404 (host-based routing без Host не срабатывает).
    expected = {
        "monitoring-grafana": ("grafana.lab.internal", "monitoring-grafana", 80),
        "monitoring-kube-prometheus-prometheus": (
            "prometheus.lab.internal",
            "monitoring-kube-prometheus-prometheus",
            9090,
        ),
        "monitoring-kube-prometheus-alertmanager": (
            "alertmanager.lab.internal",
            "monitoring-kube-prometheus-alertmanager",
            9093,
        ),
    }
    for ing_name, (host, svc_name, svc_port) in expected.items():
        ing = find("Ingress", ing_name)
        if ing["spec"].get("ingressClassName") != "traefik":
            fail(
                f"Ingress {ing_name}: ingressClassName="
                f"{ing['spec'].get('ingressClassName')!r}, ожидался traefik"
                " — в k3s контроллер встроенный и его класс default"
            )
        hosts = [r.get("host") for r in ing["spec"].get("rules") or []]
        if host not in hosts:
            fail(f"Ingress {ing_name}: host'ы {hosts}, ожидался {host}")
        backend = ((ing["spec"]["rules"][0].get("http") or {}).get("paths") or [{}])[0].get(
            "backend", {}
        )
        service = backend.get("service") or {}
        if service.get("name") != svc_name or (service.get("port") or {}).get("number") != svc_port:
            fail(
                f"Ingress {ing_name}: backend {service}, ожидался {svc_name}:{svc_port}"
            )

    # CR — источник внешнего URL: чарт подставляет первый host Ingress. Если связь
    # порвётся (обновление чарта, ручной host без ingress), UI и ссылки уведут на
    # in-cluster адреса, недоступные из браузера.
    for kind, name, host in (
        ("Prometheus", "monitoring-kube-prometheus-prometheus", "prometheus.lab.internal"),
        ("Alertmanager", "monitoring-kube-prometheus-alertmanager", "alertmanager.lab.internal"),
    ):
        cr = find(kind, name)
        external_url = cr["spec"].get("externalUrl") or ""
        if host not in external_url:
            fail(
                f"{kind} {name}: externalUrl={external_url!r} не содержит {host} —"
                " чарт перестал выводить внешний URL из ingress host, ссылки UI уйдут"
                " на внутренние имена"
            )

    grafana_ini = (find("ConfigMap", "monitoring-grafana")["data"] or {}).get("grafana.ini", "")
    if "domain = grafana.lab.internal" not in grafana_ini:
        fail(
            "ConfigMap monitoring-grafana: в grafana.ini нет domain = grafana.lab.internal"
            " — чарт выводит server.domain из ingress host; без него root_url и ссылки"
            " Grafana считаются от localhost"
        )
    print("ассерты доступа к UI (Ingress + externalUrl/domain): ok")


main()