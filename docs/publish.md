# Публикация: что делает владелец

Проект живёт в публичном репозитории `github.com/morgenvor/k8s-observability-lab`,
ветка `main`. Правки кода, документов и конфигов готовит агент, но **публикация —
действие владельца**: push, поля репозитория, защита ветки и тег остаются за человеком.
Ниже — чек-лист с готовыми командами; пометка `[владелец]` означает шаг, который агент
не выполняет.

## 1. Скриншоты `[владелец]`

README ссылается на три файла, которых в репозитории нет (снять их агент не умеет):

| Файл | Что на нём |
|---|---|
| `docs/images/demo-red.png` | дашборд «demo — RED и латентность» с живым трафиком |
| `docs/images/slo-demo.png` | дашборд «demo — SLI/SLO и burn rate» |
| `docs/images/alert-email.png` | письмо, пришедшее по `page`-алерту (тема и текст, без личных данных) |

Перед добавлением проверь кадр: host в адресной строке — плейсхолдер `*.lab.internal`,
в кадр не попали адреса почты, имена нод и внутренние IP.

## 2. Описание и топики

```bash
gh repo edit morgenvor/k8s-observability-lab \
  --description "Эксплуатация на практике: SLI/SLO и burn-rate алерты, качество алертов, доставка уведомлений, логи Loki, инцидент-дриллы на k3s" \
  --add-topic kubernetes --add-topic observability --add-topic prometheus \
  --add-topic grafana --add-topic loki --add-topic slo --add-topic sre \
  --add-topic alerting --add-topic k3s --add-topic incident-response
```

Профиль репозитория: публичный, без homepage (витрины-сайта у проекта нет),
Issues можно оставить включёнными.

## 3. Защита `main` `[владелец]`

Минимально полезный набор: обязательный зелёный `ci` перед слиянием. Имена проверок —
это имена джобов из `.github/workflows/ci.yml`: `offline checks` и `docker build`.

```bash
cat > /tmp/protection.json <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["offline checks", "docker build"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null
}
JSON
gh api -X PUT repos/morgenvor/k8s-observability-lab/branches/main/protection \
  --input /tmp/protection.json
```

Компромисс: `strict: true` требует, чтобы ветка была актуальна относительно `main` —
для одиночного репозитория это лишний шаг, зато исключает «зелёный на старом коде».
`enforce_admins: false` оставляет владельцу возможность пушить напрямую; если включить
`true`, каждый коммит пойдёт через PR, а «прямой push» перестанет работать.

## 4. Прогон CI `[владелец]`

Workflow `.github/workflows/ci.yml` запускается на push в `main` и на pull request.
Локальный аналог — `./scripts/check.sh --strict`. Разница в окружении: в образе раннера
`shellcheck` и `docker` есть сразу, `yamllint` и `pyyaml` ставит отдельный шаг
(`python3 -m pip install yamllint==1.38.0 pyyaml==6.0.2` — версии пинованы, источник
истины — `.github/workflows/ci.yml`; pyyaml нужен выгрузке `PrometheusRule`),
а инструменты из `bootstrap-tools.sh` скачиваются в CI так же, как локально.

```bash
gh run list --workflow=ci.yml --limit 5
gh run view <run-id> --log-failed     # если красный
```

Ссылку на зелёный прогон нужно вписать в `CHANGELOG.md` (строка «прогон CI подтверждён») —
это требование приёмки версии.

## 5. Тег `v1.1` `[владелец]`

Тег ставится после того, как на HEAD зелёные офлайн-ворота и CI, а живые проверки версии
(доставка `page` в почту, ticket — в приёмник, heartbeat, правило Loki ruler) записаны в
`CHANGELOG.md`.

```bash
git status -sb                  # рабочее дерево чистое, main = origin/main
git tag -a v1.1 -m "v1.1: публичный runbook и README, маршрут алерта по severity с e-mail и catch-all, heartbeat пути уведомлений, Loki ruler, логовый путь без перечитывания старых строк"
git push origin main --tags
```

Аннотированный тег (не lightweight) — чтобы у версии был автор, дата и сообщение: по нему
потом видно, что именно считалось релизом.

## 6. Проверка после публикации

```bash
# ссылки из runbook_url открываются и ведут на существующие заголовки
curl -sI "https://github.com/morgenvor/k8s-observability-lab/blob/main/docs/runbook.md" | head -1

# трекаемый набор не содержит лабораторных идентификаторов
./scripts/check.sh --strict

# README и runbook в индексе, а не только на диске
git ls-files | grep -E '^(README\.md|docs/runbook\.md)$'
```

## Что агент не делает

- не выполняет `git push`, не ставит теги, не меняет поля репозитория и защиту ветки;
- не снимает скриншоты и не добавляет файлы изображений;
- не публикует runbook в другом месте (wiki/Pages) — единственный адрес = файл в `main`.