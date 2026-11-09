#!/usr/bin/env python3
"""Ассерты метрик Loki/Alloy и хранилища Grafana в рендере чартов.

Правила `rules/pipeline.yaml` держатся на соглашении о метке `job`: у Loki шаблон
чарта переписывает job в "monitoring/<service>", у Alloy job = имя Service. Соглашение
живёт в шаблонах чартов, а не в наших values, поэтому проверяется по рендеру: иначе
обновление чарта молча отключило бы все алерты пайплайна логов.

Использование: loki_metrics.py <helmfile-render> <rules/pipeline.yaml>
"""

import sys

from common import fail, finder, load_docs


def main():
    if len(sys.argv) != 3:
        fail("использование: loki_metrics.py <helmfile-render> <rules/pipeline.yaml>")
    render_path, rules_path = sys.argv[1], sys.argv[2]
    find = finder(load_docs(render_path), "рендере helmfile")

    for sm_name in ("loki", "alloy"):
        sm = find("ServiceMonitor", sm_name)
        labels = (sm.get("metadata") or {}).get("labels") or {}
        if labels.get("release") != "monitoring":
            fail(
                f"ServiceMonitor {sm_name}: нет метки release=monitoring — Prometheus"
                " (serviceMonitorSelector matchLabels) его не подхватит"
            )
        ports = [endpoint.get("port") for endpoint in sm["spec"]["endpoints"]]
        if "http-metrics" not in ports:
            fail(f"ServiceMonitor {sm_name}: ожидался порт http-metrics, в рендере {ports}")

    # Loki: чарт сам переписывает job -> "monitoring/<service>". Если это правило
    # исчезнет, up{job="monitoring/loki"} перестанет существовать, а правила начнут
    # молчать (LokiDown/NotIngesting не увидят цель, TargetMissing — увидит).
    loki_endpoint = find("ServiceMonitor", "loki")["spec"]["endpoints"][0]
    job_relabel = [
        r
        for r in loki_endpoint.get("relabelings") or []
        if r.get("targetLabel") == "job"
    ]
    if not job_relabel:
        fail(
            "ServiceMonitor loki: пропал relabeling job -> monitoring/<service>."
            ' Правила в rules/pipeline.yaml смотрят на job="monitoring/loki"'
        )
    if not str(job_relabel[0].get("replacement", "")).startswith("monitoring/"):
        fail(
            "ServiceMonitor loki: relabeling job больше не даёт префикс monitoring/ —"
            " поправь правила rules/pipeline.yaml и этот ассерт"
        )

    with open(rules_path, encoding="utf-8") as handle:
        rules_text = handle.read()
    for selector in ('job="monitoring/loki"', 'job="alloy"'):
        if selector not in rules_text:
            fail(f"{rules_path}: нет {selector} — правила пайплайна логов разошлись с метками рендера")

    # Grafana: /var/lib/grafana обязан быть на PVC. С emptyDir при каждом рестарте пода
    # теряются user.timezone, starred-дашборды и прочее состояние из grafana.db —
    # ровно то, что дашборды из ConfigMap не восстанавливают.
    grafana = find("Deployment", "monitoring-grafana")
    volumes = grafana["spec"]["template"]["spec"]["volumes"]
    pvc_volumes = [v for v in volumes if "persistentVolumeClaim" in v]
    if not pvc_volumes:
        fail(
            "Deployment monitoring-grafana: /var/lib/grafana снова на emptyDir — настройки"
            " пользователя (timezone, starred) не переживут рестарт"
        )
    claim_name = pvc_volumes[0]["persistentVolumeClaim"]["claimName"]
    claim = find("PersistentVolumeClaim", claim_name)
    if not (claim.get("spec", {}).get("resources", {}).get("requests") or {}).get("storage"):
        fail(f"PVC {claim_name}: не задан размер — чарт не сможет создать claim")
    # Loki: масштабирование в 0 не должно удалять том. Дефолт чарта whenScaled: Delete,
    # и это уже стоило данных: дрилл 2026-11-07 удалил storage-loki-0 вместе с логами.
    loki_sts = find("StatefulSet", "loki")
    policy = loki_sts["spec"].get("persistentVolumeClaimRetentionPolicy") or {}
    if policy.get("whenScaled") != "Retain":
        fail(
            "StatefulSet loki: whenScaled=%r, ожидался Retain — scale в 0 удалит PVC"
            % policy.get("whenScaled")
        )

    strategy = (grafana["spec"].get("strategy") or {}).get("type")
    if strategy != "Recreate":
        fail(
            f"Deployment monitoring-grafana: strategy={strategy}, ожидалась Recreate."
            " RWO-PVC на local-path при RollingUpdate даёт Multi-Attach на второй ноде и"
            " подвисший rollout"
        )
    print("ассерты метрик пайплайна и PVC Grafana: ok")


main()