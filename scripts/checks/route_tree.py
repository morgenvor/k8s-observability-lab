#!/usr/bin/env python3
"""Ассерты дерева маршрутов уведомлений и подстановки адресов оверлеем.

kubeconform не знает схемы AlertmanagerConfig (`--ignore-missing-schemas`), а
вложенные child-routes в CRD объявлены как preserve-unknown-fields — то есть
структуру маршрута офлайн не проверяет никто, кроме этого файла. Цена ошибки высокая:
кривой конфиг останавливает ВСЮ доставку, включая приёмник, и молчание выглядит как
«всё хорошо». Патч адресов проверяется тремя рендерами: без env (плейсхолдеры),
с env (значения подставлены) и со значением с пробелом/запятой (экранирование).

Использование: route_tree.py <render-plain> <render-filled> <render-quoted> [<render-grafana>]

Четвёртый рендер — с GRAFANA_BASE_URL: хост в ссылках письма и в аннотациях
dashboard_url/logs_url обязан замениться целиком, иначе письмо ведёт на новый хост,
а правила — на лабораторный.
"""

import sys

from common import fail, find, load_docs

PLACEHOLDER = {
    "to": "alerts@example.invalid",
    "from": "alertmanager@example.invalid",
    "smarthost": "smtp.example.invalid:587",
    "authUsername": "alertmanager",
}


def route_spec(path):
    return find(
        load_docs(path), "AlertmanagerConfig", "demo-notifications", where=f"рендере {path}"
    ).get("spec") or {}


def matcher(route, where):
    found = route.get("matchers")
    if not found or len(found) != 1:
        fail(f"{where}: matchers={found!r}, ожидался ровно один матчер по severity")
    only = found[0]
    if only.get("name") != "severity" or only.get("matchType") != "=~":
        fail(f"{where}: матчер {only!r}, ожидался name=severity matchType=~")
    return only.get("value")



GRAFANA_PLACEHOLDER = "http://grafana.lab.internal"


def check_grafana_host(path):
    """GRAFANA_BASE_URL заменяет хост Grafana во всём рендере, а не только в письме."""
    docs = load_docs(path)
    base = None
    for doc in docs:
        annotations = []
        if doc.get("kind") == "PrometheusRule":
            for group in (doc.get("spec") or {}).get("groups") or []:
                for rule in group.get("rules") or []:
                    annotations.append(rule.get("annotations") or {})
        elif doc.get("kind") == "AlertmanagerConfig":
            for receiver in (doc.get("spec") or {}).get("receivers") or []:
                for config in receiver.get("emailConfigs") or []:
                    for field in ("text", "html"):
                        body = config.get(field) or ""
                        if GRAFANA_PLACEHOLDER in body:
                            fail(f"рендер с GRAFANA_BASE_URL: в emailConfigs[0].{field} остался плейсхолдер")
        for item in annotations:
            for name in ("dashboard_url", "logs_url"):
                url = item.get(name)
                if not url:
                    continue
                if not url.startswith("http"):
                    fail(f"аннотация {name}={url!r} не абсолютная")
                base = url.split("/d/")[0]
    if base is None:
        fail("рендер с GRAFANA_BASE_URL: ни одной ссылки на Grafana — проверять нечего")
    if base == GRAFANA_PLACEHOLDER:
        fail(
            "рендер с GRAFANA_BASE_URL: аннотации dashboard_url/logs_url остались на "
            f"плейсхолдере {GRAFANA_PLACEHOLDER}"
        )


def main():
    if len(sys.argv) not in (4, 5):
        fail(
            "использование: route_tree.py <render-plain> <render-filled> <render-quoted>"
            " [<render-grafana>]"
        )

    spec = route_spec(sys.argv[1])
    route = spec.get("route") or {}
    expected = {
        "receiver": "alert-sink",
        "groupBy": ["alertname", "service"],
        "groupWait": "10s",
        "groupInterval": "30s",
        "repeatInterval": "4h",
    }
    for key, value in expected.items():
        if route.get(key) != value:
            fail(f"route.{key}={route.get(key)!r}, ожидалось {value!r}")

    children = route.get("routes") or []
    if len(children) != 4:
        fail(
            f"child-routes родителя: {len(children)}, ожидалось 4"
            " (heartbeat → e-mail, severity page|critical → e-mail, severity для остального,"
            " catch-all)"
        )
    heartbeat_route, email_route, ticket_route, catch_all = children
    # Heartbeat-ветка обязана быть первой: алерты AlertSink* имеют severity ticket, и без
    # почты они остаются только в том sink, поломку которого описывают.
    if heartbeat_route.get("receiver") != "email":
        fail(f"child-routes[0].receiver={heartbeat_route.get('receiver')!r}, ожидался email")
    if heartbeat_route.get("continue") is not True:
        fail(
            "child-routes[0] без continue: true — heartbeat-алерт не доедет до sink,"
            " а /timeline останется без записи о поломке пути"
        )
    hb_matchers = heartbeat_route.get("matchers") or []
    if len(hb_matchers) != 1:
        fail(f"child-routes[0].matchers={hb_matchers!r}, ожидался ровно один матчер по alertname")
    hb_only = hb_matchers[0]
    if (hb_only.get("name"), hb_only.get("matchType"), hb_only.get("value")) != (
        "alertname",
        "=~",
        "AlertSink.*",
    ):
        fail(
            f"child-routes[0]: матчер {hb_only!r},"
            " ожидался alertname=~'AlertSink.*' (имена правил rules/notifications.yaml)"
        )
    if email_route.get("receiver") != "email":
        fail(f"child-routes[1].receiver={email_route.get('receiver')!r}, ожидался email")
    if email_route.get("continue") is not True:
        fail(
            "child-routes[1] без continue: true — Alertmanager остановится на e-mail-ветке,"
            " и остальные ветки для этого алерта не рассматриваются"
        )
    if matcher(email_route, "child-routes[1]") != "page|critical":
        fail(f"child-routes[1]: severity={matcher(email_route, 'child-routes[1]')!r}, ожидалось page|critical")
    if ticket_route.get("receiver") != "alert-sink":
        fail(f"child-routes[2].receiver={ticket_route.get('receiver')!r}, ожидался alert-sink")
    if ticket_route.get("continue"):
        fail("child-routes[2] с continue: true — лишняя ветка ниже получит тот же алерт")
    if matcher(ticket_route, "child-routes[2]") != "ticket|info|warning|none":
        fail(
            "child-routes[2]: severity="
            f"{matcher(ticket_route, 'child-routes[2]')!r}, ожидалось ticket|info|warning|none"
        )
    if catch_all.get("receiver") != "alert-sink":
        fail(f"catch-all.receiver={catch_all.get('receiver')!r}, ожидался alert-sink")
    if catch_all.get("matchers"):
        fail(
            f"catch-all с матчерами {catch_all.get('matchers')!r} — неизвестный severity"
            " уйдёт в null-получатель и исчезнет молча"
        )

    receivers = spec.get("receivers") or []
    names = [r.get("name") for r in receivers]
    if names != ["alert-sink", "email"]:
        fail(
            f"receivers: {names}, ожидалось ['alert-sink', 'email'] —"
            " от индекса 1 зависит патч адресов в scripts/lib.sh"
        )
    configs = receivers[1].get("emailConfigs") or []
    if len(configs) != 1:
        fail(f"receivers[1].emailConfigs: {len(configs)}, ожидался один")
    email = configs[0]
    password = email.get("authPassword") or {}
    if password.get("name") != "alertmanager-smtp" or password.get("key") != "smtp-password":
        fail(
            f"authPassword={password!r}, ожидался Secret alertmanager-smtp ключ smtp-password"
            " (docs/runbook.md, «Маршрут уведомлений»)"
        )
    if email.get("requireTLS") is not True or email.get("sendResolved") is not True:
        fail(
            "emailConfigs[0]: requireTLS/sendResolved не true — письмо уйдёт без STARTTLS"
            " или о закрытии алерта не будет уведомления"
        )
    text = email.get("text") or ""
    html = email.get("html") or ""
    if not html:
        fail(
            "emailConfigs[0].html пуст: письмо собирается как multipart/alternative, и без "
            "своего html клиент покажет дефолтный шаблон Alertmanager (ссылки текстом, "
            "а не гиперссылками)"
        )
    # Проверяем именно ссылки на поля шаблона, а не слова в комментарии: «alertname» есть
    # в любом тексте, а письмо без `.Labels.alertname` бесполезно. Список один на обе
    # части: расхождение состава text и html — это разный набор фактов в одном письме.
    required = (
        ".Labels.alertname",
        ".Labels.severity",
        ".Annotations.summary",
        ".Annotations.description",
        ".Annotations.runbook_url",
        ".Annotations.dashboard_url",
        ".Annotations.logs_url",
        ".StartsAt.UnixMilli",
        "time.window=1800000",
        "from=",
        "to=now",
        'tz "Europe/Moscow"',
    )
    for part, body in (("text", text), ("html", html)):
        missing = [token for token in required if token not in body]
        if missing:
            fail(
                f"emailConfigs[0].{part} без полей {missing} — в письме не будет "
                f"{', '.join(missing)}"
            )
    if "<a\n" not in html and "<a href=" not in html:
        fail("emailConfigs[0].html без гиперссылок <a href=…> — ссылки останутся текстом")
    # Арифметики в шаблонах Alertmanager 0.34.1 нет: `toDuration` не определена, и шаблон
    # с ней падает на рендере, то есть письмо не уходит вовсе (проверено на пине).
    # Окно считается через time/time.window Grafana, а не вычитанием `for` из startsAt.
    for part, body in (("text", text), ("html", html)):
        if "toDuration" in body:
            fail(
                f"emailConfigs[0].{part} использует toDuration: функции нет в Alertmanager "
                "0.34.1, шаблон упадёт и уведомление не будет отправлено"
            )

    for field, value in PLACEHOLDER.items():
        if email.get(field) != value:
            fail(
                f"базовый рендер: emailConfigs[0].{field}={email.get(field)!r},"
                f" ожидался плейсхолдер {value!r} (реальные значения подставляет оверлей)"
            )

    filled_spec = route_spec(sys.argv[2])
    filled = filled_spec["receivers"][1]["emailConfigs"][0]
    if filled.get("to") != "page@example.invalid":
        fail(f"с ALERT_EMAIL_TO рендер дал to={filled.get('to')!r} — патч не доехал до receivers[1]")
    if filled.get("smarthost") != "smtp.example.invalid:587":
        fail(f"с SMTP_SMARTHOST рендер дал smarthost={filled.get('smarthost')!r}, ожидалось smtp.example.invalid:587")
    for field in ("from", "authUsername"):
        if filled.get(field) != PLACEHOLDER[field]:
            fail(
                f"задавали только ALERT_EMAIL_TO и SMTP_SMARTHOST, но {field}="
                f"{filled.get(field)!r} — патч задел то, что не передавали"
            )

    # Значение с пробелом, запятой и угловыми скобками: YAML не должен развалиться, а строка —
    # обрезаться по первому пробелу при сборке патча.
    quoted = route_spec(sys.argv[3])["receivers"][1]["emailConfigs"][0]
    expected_from = "Alert Manager <alertmanager@example.invalid>, ops"
    if quoted.get("from") != expected_from:
        fail(f"адрес с пробелом и запятой отрендерился как {quoted.get('from')!r} — экранирование сломано")
    if len(sys.argv) == 5:
        check_grafana_host(sys.argv[4])

    print("ассерты маршрута уведомлений и подстановки адресов: ok")


main()