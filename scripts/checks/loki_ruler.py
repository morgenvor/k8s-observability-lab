#!/usr/bin/env python3
"""Ассерты цепочки Loki ruler: конфиг ruler -> том у StatefulSet -> ConfigMap -> правило.

Правило Loki живёт вне Prometheus: его читает ruler внутри пода Loki из каталога,
смонтированного из ConfigMap. Ошибку здесь не видит ни kubeconform (это data
ConfigMap), ни promtool (LogQL он не разбирает), а цена — молчащее правило: неверный
путь тома, потерянный суффикс тенанта или выключенный ruler выглядят как «логов
просто нет».

Использование: loki_ruler.py <helmfile-render> <kustomize-render>
"""

import sys

import yaml

from common import fail, finder, load_docs

ALERTMANAGER_URL = "http://monitoring-kube-prometheus-alertmanager.monitoring.svc:9093"
# Локальное хранилище правил читает <directory>/<tenant>/<файл>, а тенант при
# auth_enabled: false — "fake" (docs Loki, multi-tenancy). Отсюда и путь тома.
RULES_DIR = "/etc/loki/rules"
TENANT_DIR = RULES_DIR + "/fake"
RULE_KEY = "demo-api-5xx.yaml"


def main():
    if len(sys.argv) != 3:
        fail("использование: loki_ruler.py <helmfile-render> <kustomize-render>")
    render_path, kustomize_path = sys.argv[1], sys.argv[2]
    find = finder(load_docs(render_path), "рендере helmfile")
    find_kustomize = finder(load_docs(kustomize_path), "рендере kustomize")

    # 1) Конфиг Loki: ruler включён, смотрит в Alertmanager и читает наш каталог.
    config_map = find("ConfigMap", "loki")
    config = yaml.safe_load((config_map.get("data") or {}).get("config.yaml") or "")
    ruler = (config or {}).get("ruler")
    if not ruler:
        fail(
            "в config.yaml Loki нет блока ruler — ruleConfig из helm/values/loki.yaml"
            " не доехал, правило по логам не загрузится"
        )
    if ruler.get("alertmanager_url") != ALERTMANAGER_URL:
        fail(
            f"ruler.alertmanager_url={ruler.get('alertmanager_url')!r}, ожидался {ALERTMANAGER_URL!r}"
            " (Service релиза monitoring; при другом адресе алерты правила уйдут в никуда)"
        )
    if ruler.get("enable_api") is not True:
        fail(
            "ruler.enable_api не true — GET /prometheus/api/v1/rules не поднимется,"
            " и проверить загрузку правила будет нечем"
        )
    storage = ruler.get("storage") or {}
    if storage.get("type") != "local" or (storage.get("local") or {}).get("directory") != RULES_DIR:
        fail(
            f"ruler.storage={storage!r}, ожидалось type=local, directory={RULES_DIR}"
            " — другой тайп требует объектного хранилища, которого в лабе нет"
        )

    # 2) Том у пода: ConfigMap смонтирован ровно в каталог тенанта, только на чтение.
    sts = find("StatefulSet", "loki")
    pod = sts["spec"]["template"]["spec"]
    mounts = [
        m
        for container in pod["containers"]
        for m in container.get("volumeMounts") or []
        if m.get("name") == "loki-rules"
    ]
    if len(mounts) != 1:
        fail(f"StatefulSet loki: смонтировано томов loki-rules {len(mounts)}, ожидался один")
    mount = mounts[0]
    if mount.get("mountPath") != TENANT_DIR:
        fail(
            f"том loki-rules смонтирован в {mount.get('mountPath')!r}, ожидалось {TENANT_DIR!r}."
            " Локальное хранилище правил ищет файлы в подкаталоге тенанта: плоский"
            " /etc/loki/rules правило не увидит"
        )
    if mount.get("readOnly") is not True:
        fail("том loki-rules смонтирован не readOnly: правила не должны меняться из пода")
    volumes = [v for v in pod.get("volumes") or [] if v.get("name") == "loki-rules"]
    if len(volumes) != 1 or (volumes[0].get("configMap") or {}).get("name") != "loki-rules":
        fail(
            f"том loki-rules={volumes!r}, ожидался configMap loki-rules"
            " (ConfigMap создаёт kustomize из deploy/loki-rules)"
        )

    # 3) ConfigMap из kustomize: тот самый ключ, который ждёт том.
    rules_cm = find_kustomize("ConfigMap", "loki-rules")
    if (rules_cm.get("metadata") or {}).get("namespace") != "monitoring":
        fail("ConfigMap loki-rules не в namespace monitoring — рядом с подом Loki его нет")
    data = rules_cm.get("data") or {}
    if RULE_KEY not in data:
        fail(
            f"в ConfigMap loki-rules ключи {sorted(data)}, ожидался {RULE_KEY}"
            " — смонтированный файл не совпадёт с тем, что читает ruler"
        )
    rule_doc = yaml.safe_load(data[RULE_KEY]) or {}

    # 4) Само правило: структурный разбор (LogQL promtool не проверяет).
    groups = rule_doc.get("groups") or []
    if not groups:
        fail(f"{RULE_KEY}: нет groups — файл правил пуст или это не формат ruler")
    rule = None
    for group in groups:
        for candidate in group.get("rules") or []:
            if candidate.get("alert") == "DemoApi5xxFromLogs":
                rule = candidate
                break
    if rule is None:
        fail(f"{RULE_KEY}: нет правила DemoApi5xxFromLogs")
    expr = rule.get("expr") or ""
    for token in ("count_over_time(", '{namespace="demo", app="demo-api"}', "| json", "status >= 500"):
        if token not in expr:
            fail(f"DemoApi5xxFromLogs: в expr нет {token!r} — правило считает не то, что задумано")
    # Штатный дренаж пода отвечает /ready → 503, и без фильтра правило горит ticket на
    # каждом плановом рестарте с SIGTERM. Проверено на живых данных 2026-11-09: за доступное
    # окно хранения (~46 ч — PVC Loki пересоздан 2026-11-07 11:13 UTC) единственная строка
    # со status >= 500 — именно GET /ready при SIGTERM. Ассерт держит фильтр от удаления.
    if 'route != "/ready"' not in expr:
        fail(
            "DemoApi5xxFromLogs: из expr пропал фильтр 'route != \"/ready\"'. Без него 503"
            " самопроверки готовности при SIGTERM даёт ложный ticket на каждом рестарте пода"
            " (см. комментарий в deploy/loki-rules/demo-api-5xx.yaml)"
        )
    labels = rule.get("labels") or {}
    if labels.get("severity") != "ticket":
        fail(
            f"DemoApi5xxFromLogs: severity={labels.get('severity')!r}, ожидался ticket"
            " — page увёл бы уточнение причины по логам в почту"
        )
    if labels.get("service") != "demo-api":
        fail(f"DemoApi5xxFromLogs: service={labels.get('service')!r}, ожидался demo-api")
    if rule.get("for") != "2m":
        fail(f"DemoApi5xxFromLogs: for={rule.get('for')!r}, ожидалось 2m")
    print("ассерты Loki ruler (конфиг, том, ConfigMap, правило): ok")


main()