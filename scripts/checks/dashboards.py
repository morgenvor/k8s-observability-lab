#!/usr/bin/env python3
"""Ассерты дашбордов Grafana: всё, на что ссылаются панели, должно существовать.

Дашборд — JSON внутри ConfigMap: его не видит ни kubeconform (схема ConfigMap
безразлична к содержимому), ни jq (только синтаксис). Ошибка в uid datasource, в имени
метрики или в селекторе Loki выглядит как рабочая панель «No data»: отличить «ничего не
происходит» от «панель сломана» по экрану нельзя. Проверяется:

1. `uid` дашборда есть и уникален — дубль означает, что один дашборд затрёт другой, а
   ссылка `dashboard_url` из алерта откроет чужую панель;
2. datasource панели и цели — только существующий uid: `prometheus` (дефолт чарта) или
   uid из `grafana.additionalDataSources` в `helm/values/kps.yaml`;
3. каждое имя метрики в выражении Prometheus разрешается: объявлено в `app/*/src/*.js`,
   является записывающим правилом из `rules/*.yaml` либо входит в явный список встроенных
   (`up`, `ALERTS`, метрики prom-client). Разбор идёт по всему выражению, а не по префиксу:
   проверка «начинается на `alertsink_`» пропускала бы опечатку в самом префиксе;
4. `namespace` в селекторах Loki принадлежит списку, который читает Alloy, а `app` —
   меткам подов демо-контура в `deploy/`. Namespace берётся из ОТРЕНДЕРЕННОГО конфига
   Alloy (его же разбирает `scripts/checks/alloy_config.py`): второй парсер того же факта
   в values разошёлся бы с первым.

Отрицательные матчеры (`!=`, `!~`) не проверяются намеренно: они не сужают поток, поэтому
неверное значение там стоит лишнего чтения, а не пустой панели.

Самопроверка. Ассерт, который сам никто не проверяет, тихо перестаёт ловить свои классы
дефектов (правка регулярки, «умное» исключение). Поэтому каждый прогон дополнительно
мутирует копии проверенных дашбордов (`namespace=~"prod|demo"`, чужое имя метрики,
`app="alert_sink"`, дубль `uid`, неизвестный datasource, цель без `expr`) и требует, чтобы
каждая мутация дала ошибку с ожидаемым текстом. Провал самопроверки — провал шага.

Использование: dashboards.py <корень-проекта> <отрендеренный-конфиг-Alloy>
"""

import copy
import glob
import json
import os
import re
import sys

import yaml

from common import fail

# Дефолтный uid Prometheus-датасорса чарта kube-prometheus-stack: он не наш, поэтому в
# values его нет, а панели на него ссылаются.
CHART_PROMETHEUS_UID = "prometheus"

# Не метрики: функции, агрегаторы, модификаторы группировки и ключевые слова PromQL.
# Выражение разбирается токенами, а не полноценным парсером, поэтому список обязан быть
# полным — иначе функция попадёт в проверку метрик и ассерт начнёт врать.
PROMQL_WORDS = frozenset(
    """
    abs absent absent_over_time acos acosh and asin asinh atan atanh atan2 avg avg_over_time
    bool bottomk by ceil changes clamp clamp_max clamp_min cos cosh count count_over_time
    count_values day_of_month day_of_week day_of_year days_in_month deg delta deriv
    double_exponential_smoothing end exp floor group group_left group_right histogram_avg
    histogram_count histogram_fraction histogram_quantile histogram_stddev histogram_stdvar
    histogram_sum holt_winters hour idelta ignoring increase info irate label_join
    label_replace last_over_time limit_ratio limitk ln log10 log2 mad_over_time max
    max_over_time min min_over_time minute month offset on or pi predict_linear
    present_over_time quantile quantile_over_time rad rate resets round scalar sgn sin sinh
    sort sort_by_label sort_by_label_desc sort_desc sqrt start stddev stddev_over_time
    stdvar stdvar_over_time sum sum_over_time tan tanh time timestamp topk unless vector
    without year
    """.split()
)

# Метрики, которых нет в исходниках приложений, но на которые панели вправе ссылаться.
# Список намеренно точный, а не «любой alertsink_»: иначе опечатка в префиксе проходит
# молча. Пополняется осознанно — снятой с живого /metrics строкой.
BUILTIN_METRICS = frozenset(
    {
        # Сам Prometheus и его записанные состояния.
        "up",
        "ALERTS",
        "ALERTS_FOR_STATE",
        "scrape_duration_seconds",
        # process-collector prom-client: префикс alertsink_ задан collectDefaultMetrics.
        "alertsink_process_start_time_seconds",
        "alertsink_process_cpu_seconds_total",
        "alertsink_process_resident_memory_bytes",
        "alertsink_process_open_fds",
    }
)

# Гистограмма объявлена одним именем, а серии у неё с суффиксами.
HISTOGRAM_SUFFIXES = ("_bucket", "_count", "_sum")

WORKLOAD_KINDS = {"Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob", "ReplicaSet"}

SELECTOR = re.compile(r'\b(namespace|app)\s*(=~|!~|!=|=)\s*"([^"]*)"')


class AssertError(Exception):
    """Нарушение инварианта дашборда. Отдельный тип нужен самопроверке: она ждёт именно его."""


def check(condition, message):
    if not condition:
        raise AssertError(message)


def load_json(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except OSError as exc:
        fail(f"{path}: не читается ({exc})")
    except json.JSONDecodeError as exc:
        fail(f"{path}: не разбирается как JSON ({exc})")


def read_text(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except OSError as exc:
        fail(f"{path}: не читается ({exc})")


def yaml_docs(path):
    try:
        with open(path, encoding="utf-8") as handle:
            docs = list(yaml.safe_load_all(handle))
    except OSError as exc:
        fail(f"{path}: не читается ({exc})")
    except yaml.YAMLError as exc:
        fail(f"{path}: не разбирается как YAML ({exc})")
    return [doc for doc in docs if isinstance(doc, dict)]


def datasource_uid(value, where):
    """uid датасорса из ссылки панели; поддерживаются обе формы Grafana (объект и строка)."""
    if value is None:
        return None
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        uid = value.get("uid")
        check(isinstance(uid, str) and bool(uid), f"{where}: datasource без uid — панель не привязана к источнику данных")
        return uid
    raise AssertError(f"{where}: datasource неожиданного вида: {value!r}")


def iter_panels(panels):
    for panel in panels or []:
        yield panel
        yield from iter_panels(panel.get("panels"))


def allowed_datasources(root):
    values = yaml_docs(os.path.join(root, "helm", "values", "kps.yaml"))
    grafana = (values[0].get("grafana") if values else None) or {}
    uids = {CHART_PROMETHEUS_UID}
    for source in grafana.get("additionalDataSources") or []:
        uid = (source or {}).get("uid")
        if isinstance(uid, str) and uid:
            uids.add(uid)
    return uids


def declared_metrics(root):
    """Имена метрик, объявленных в приложениях: `name: '<метрика>'` в исходниках."""
    names = set()
    for path in glob.glob(os.path.join(root, "app", "*", "src", "*.js")):
        names.update(re.findall(r"name:\s*'([a-z][a-z0-9_]*)'", read_text(path)))
    return names


def recording_rules(root):
    """Имена записывающих правил: панели ссылаются на них как на обычные метрики."""
    names = set()
    for path in glob.glob(os.path.join(root, "rules", "*.yaml")):
        for doc in yaml_docs(path):
            for group in ((doc.get("spec") or {}).get("groups") or []):
                for rule in group.get("rules") or []:
                    record = (rule or {}).get("record")
                    if isinstance(record, str) and record:
                        names.add(record)
    return names


def app_labels(root):
    """Значения метки `app` у подов демо-контура: по ним строятся селекторы Loki."""
    labels = set()
    for path in glob.glob(os.path.join(root, "deploy", "**", "*.yaml"), recursive=True):
        for doc in yaml_docs(path):
            if doc.get("kind") not in WORKLOAD_KINDS:
                continue
            template = (doc.get("spec") or {}).get("template") or {}
            app = ((template.get("metadata") or {}).get("labels") or {}).get("app")
            if isinstance(app, str) and app:
                labels.add(app)
    if not labels:
        fail("deploy/: не найдено ни одной метки app у подов — проверка селекторов без неё бессмысленна")
    return labels


def alloy_namespaces(rendered_path):
    """Namespace, которые реально читает Alloy: `names = [...]` в отрендеренном конфиге."""
    names = set()
    for raw in re.findall(r"\bnames\s*=\s*\[([^\]]*)\]", read_text(rendered_path)):
        names.update(item.strip().strip('"') for item in raw.split(",") if item.strip())
    if not names:
        fail(
            f"{rendered_path}: не найден список names в discovery.kubernetes —"
            " проверять селекторы Loki не по чему"
        )
    return names


def metric_identifiers(expr):
    """Имена метрик из выражения PromQL — без функций, меток и селекторов диапазона."""
    text = re.sub(r'"[^"]*"', '""', expr)
    text = re.sub(r"\{[^}]*\}", "", text)
    text = re.sub(r"\b(by|without|on|ignoring|group_left|group_right)\s*\([^)]*\)", "", text)
    text = re.sub(r"\[[^\]]*\]", "", text)
    # Числа (в том числе экспоненциальные) и длительности не должны давать «метрик»:
    # из `1e-9` иначе получается идентификатор `e`, из `offset 5m` — `m`.
    text = re.sub(r"\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b", " ", text)
    text = re.sub(r"\boffset\s+\S+", " ", text)
    return [token for token in re.findall(r"[A-Za-z_][A-Za-z0-9_:]*", text) if token not in PROMQL_WORDS]


def resolves(name, metrics, recordings):
    if name in metrics or name in recordings or name in BUILTIN_METRICS:
        return True
    return any(name.endswith(suffix) and name[: -len(suffix)] in metrics for suffix in HISTOGRAM_SUFFIXES)


def check_loki_selector(expr, namespaces, apps, where):
    for label, operator, value in SELECTOR.findall(expr):
        if operator in ("!=", "!~"):
            # Не сужает поток: неверное значение стоит объёма чтения, а не пустой панели.
            continue
        allowed = namespaces if label == "namespace" else apps
        if operator == "=":
            check(
                value in allowed,
                f'{where}: селектор {label}="{value}", а доступны только {sorted(allowed)} —'
                " панель будет пуста",
            )
            continue
        # =~ : каждое альтернативное значение должно совпасть хотя бы с одним из доступных.
        for alternative in value.split("|"):
            check(
                any(re.fullmatch(alternative, candidate) for candidate in allowed),
                f'{where}: в селекторе {label}=~"{value}" альтернатива "{alternative}" не'
                f" совпадает ни с одним из {sorted(allowed)} — панель будет пуста",
            )


def validate(dashboards, datasources, metrics, recordings, namespaces, apps):
    """Проверяет пары (метка, дашборд); возвращает статистику, бросает AssertError."""
    seen_uids = {}
    panels_checked = 0
    referenced = set()
    for where_file, dashboard in dashboards:
        uid = dashboard.get("uid")
        check(isinstance(uid, str) and bool(uid), f"{where_file}: нет uid — ссылка dashboard_url ведёт в никуда")
        check(
            uid not in seen_uids,
            f"{where_file}: uid '{uid}' уже занят дашбордом {seen_uids.get(uid)}."
            " Один затрёт другой, и ссылка из алерта откроет чужую панель",
        )
        seen_uids[uid] = where_file

        panels = dashboard.get("panels") or []
        check(bool(panels), f"{where_file}: нет панелей — дашборд пуст")

        for panel in iter_panels(panels):
            panels_checked += 1
            where = f"{where_file}: панель «{panel.get('title')}»"
            panel_uid = datasource_uid(panel.get("datasource"), where)
            check(
                panel_uid is None or panel_uid in datasources,
                f"{where}: datasource uid '{panel_uid}' не объявлен (есть: {sorted(datasources)})"
                " — панель останется без данных",
            )
            for target in panel.get("targets") or []:
                target_uid = datasource_uid(target.get("datasource"), where) or panel_uid
                check(target_uid is not None, f"{where}: у цели нет datasource — неясно, куда идёт запрос")
                check(
                    target_uid in datasources,
                    f"{where}: цель ссылается на datasource uid '{target_uid}', которого нет"
                    f" (есть: {sorted(datasources)})",
                )
                expr = target.get("expr")
                check(
                    isinstance(expr, str) and bool(expr.strip()),
                    f"{where}: у цели нет expr — панель нарисует пустоту",
                )
                if target_uid == CHART_PROMETHEUS_UID:
                    for name in metric_identifiers(expr):
                        check(
                            resolves(name, metrics, recordings),
                            f'{where}: метрики "{name}" нет ни в app/*/src/*.js, ни в'
                            " rules/*.yaml (record), ни в списке встроенных — опечатка"
                            " даёт пустую панель, а не ошибку",
                        )
                        referenced.add(name)
                else:
                    check_loki_selector(expr, namespaces, apps, where)
    return panels_checked, referenced


def self_test(dashboards, datasources, metrics, recordings, namespaces, apps):
    """Мутирует копии и требует, чтобы каждая мутация дала ошибку — иначе ассерт ослеп."""

    def expect(name, mutate, expected):
        mutated = copy.deepcopy(dashboards)
        mutate(mutated)
        try:
            validate(mutated, datasources, metrics, recordings, namespaces, apps)
        except AssertError as exc:
            if expected not in str(exc):
                fail(f'самопроверка «{name}»: ошибка есть, но текст другой: {exc}')
            return
        fail(
            f'самопроверка «{name}»: мутация прошла молча — ассерт перестал ловить этот класс'
            " дефектов (панель показала бы «No data» без единого сообщения)"
        )

    def first_prometheus_target(docs):
        for _, dashboard in docs:
            for panel in iter_panels(dashboard.get("panels") or []):
                for target in panel.get("targets") or []:
                    uid = (target.get("datasource") or {}).get("uid") or (panel.get("datasource") or {}).get("uid")
                    if uid == CHART_PROMETHEUS_UID:
                        return target
        return None

    def first_loki_target(docs):
        for _, dashboard in docs:
            for panel in iter_panels(dashboard.get("panels") or []):
                for target in panel.get("targets") or []:
                    uid = (target.get("datasource") or {}).get("uid") or (panel.get("datasource") or {}).get("uid")
                    if uid and uid != CHART_PROMETHEUS_UID:
                        return target
        return None

    prometheus = first_prometheus_target(dashboards)
    loki = first_loki_target(dashboards)
    check(prometheus is not None, "самопроверка: ни одной цели Prometheus — нечего мутировать")
    check(loki is not None, "самопроверка: ни одной цели Loki — нечего мутировать")

    expect(
        "опечатка в префиксе метрики",
        lambda docs: first_prometheus_target(docs).__setitem__("expr", "sum(alertsnk_nothing_total)"),
        "alertsnk_nothing_total",
    )
    expect(
        "чужое имя метрики",
        lambda docs: first_prometheus_target(docs).__setitem__("expr", "sum(foo_bar_total)"),
        "foo_bar_total",
    )
    expect(
        "несуществующая метрика prom-client",
        lambda docs: first_prometheus_target(docs).__setitem__("expr", "sum(alertsink_nodejs_bogus_bytes)"),
        "alertsink_nodejs_bogus_bytes",
    )
    expect(
        "селектор namespace вне Alloy",
        lambda docs: first_loki_target(docs).__setitem__("expr", '{namespace=~"prod|demo"}'),
        '"prod"',
    )
    expect(
        "селектор app вне меток подов",
        lambda docs: first_loki_target(docs).__setitem__("expr", '{app="alert_sink"}'),
        'app="alert_sink"',
    )
    expect(
        "дубль uid дашборда",
        lambda docs: docs[0][1].__setitem__("uid", docs[1][1].get("uid")) if len(docs) > 1 else docs[0][1].__setitem__("panels", []),
        "uid",
    )
    expect(
        "неизвестный uid datasource",
        lambda docs: docs[0][1]["panels"][0].__setitem__("datasource", {"type": "prometheus", "uid": "nope"}),
        "nope",
    )
    expect(
        "цель без expr",
        lambda docs: first_prometheus_target(docs).pop("expr", None),
        "нет expr",
    )


def main():
    if len(sys.argv) != 3:
        fail("использование: dashboards.py <корень-проекта> <отрендеренный-конфиг-Alloy>")
    root, alloy_rendered = sys.argv[1], sys.argv[2]
    paths = sorted(glob.glob(os.path.join(root, "deploy", "dashboards", "*.json")))
    if not paths:
        fail("deploy/dashboards/*.json: нет ни одного дашборда — проверять нечего")

    dashboards = [(os.path.relpath(path, root), load_json(path)) for path in paths]
    datasources = allowed_datasources(root)
    metrics = declared_metrics(root)
    recordings = recording_rules(root)
    namespaces = alloy_namespaces(alloy_rendered)
    apps = app_labels(root)

    try:
        panels_checked, referenced = validate(dashboards, datasources, metrics, recordings, namespaces, apps)
        self_test(dashboards, datasources, metrics, recordings, namespaces, apps)
    except AssertError as exc:
        fail(str(exc))

    sink_metrics = sorted(name for name in metrics if name.startswith("alertsink_"))
    print(
        f"дашборды: файлов {len(dashboards)}, панелей {panels_checked},"
        f" datasource {sorted(datasources)}, метрик приложений {len(metrics)}"
        f" (alert-sink {len(sink_metrics)}), записей правил {len(recordings)},"
        f" метрик в выражениях {len(referenced)}, самопроверок 8"
    )


main()