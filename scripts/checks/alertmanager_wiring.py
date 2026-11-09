#!/usr/bin/env python3
"""Ассерт связки «Alertmanager действительно читает наш AlertmanagerConfig».

kubeconform идёт с `--ignore-missing-schemas`, а селекторы и matcherStrategy — поля
CR, которых офлайн не проверяет никто. Цена ошибки: неверная strategy отрезает
AlertmanagerConfig из monitoring, алерты из demo не доходят ни до alert-sink, ни до
почты, а остальные проверки (маршрут валиден, правила загружены) остаются зелёными.

Использование: alertmanager_wiring.py <helmfile-render> <kustomize-render>
"""

import sys

from common import fail, find, load_docs, require_api

MATCHER_HINT = (
    "дефолт operator v0.94.2 — OnNamespace: на конфиг из monitoring навешивается"
    ' матчер namespace="monitoring", и алерты из demo не доходят ни до alert-sink,'
    " ни до почты (helm/values/kps.yaml)"
)


def reject_nonempty_selector(spec, key, where):
    selector = spec.get(key)
    if selector:
        fail(
            f"{where}: {key}={selector!r}, ожидался пустой селектор (MatchAll)."
            " Непустой селектор матчит метки namespace, офлайн их не проверить:"
            " если так и задумано — правь ассерт осознанно"
        )


def main():
    if len(sys.argv) != 3:
        fail("использование: alertmanager_wiring.py <helmfile-render> <kustomize-render>")
    helmfile_path, kustomize_path = sys.argv[1], sys.argv[2]
    render = load_docs(helmfile_path)
    kustomize = load_docs(kustomize_path)

    alertmanager = find(render, "Alertmanager", where="рендере helmfile")
    require_api(alertmanager, "monitoring.coreos.com/v1", "Alertmanager")
    spec = alertmanager.get("spec") or {}

    strategy = spec.get("alertmanagerConfigMatcherStrategy") or {}
    if strategy.get("type") != "None":
        fail(
            "Alertmanager: alertmanagerConfigMatcherStrategy.type="
            f"{strategy.get('type')!r}, ожидалось 'None' — {MATCHER_HINT}"
        )
    reject_nonempty_selector(spec, "alertmanagerConfigSelector", "Alertmanager")
    reject_nonempty_selector(spec, "alertmanagerConfigNamespaceSelector", "Alertmanager")

    config = find(
        kustomize, "AlertmanagerConfig", "demo-notifications", where="рендере kustomize"
    )
    require_api(
        config, "monitoring.coreos.com/v1alpha1", "AlertmanagerConfig demo-notifications"
    )
    namespace = (config.get("metadata") or {}).get("namespace")
    if namespace != "monitoring":
        fail(
            f"AlertmanagerConfig demo-notifications: namespace={namespace!r}, ожидался"
            " monitoring — в другом namespace оператор его не увидит рядом с Alertmanager"
        )
    if not (config.get("spec") or {}).get("route"):
        fail("AlertmanagerConfig demo-notifications: нет spec.route — маршрут не задан")

    print("связка Alertmanager и AlertmanagerConfig: ok")


main()