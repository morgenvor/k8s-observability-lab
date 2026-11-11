# k8s-observability-lab

[![CI](https://github.com/morgenvor/k8s-observability-lab/actions/workflows/ci.yml/badge.svg)](https://github.com/morgenvor/k8s-observability-lab/actions/workflows/ci.yml)

[Русский](README.ru.md) | **English**

**Monitoring that proves it works.**

A pet project about operating a Kubernetes service: SLOs measured from the client's
side, alerts that are proven to arrive, logs tied to the incident window, and incident
drills that leave machine-readable evidence.

Most monitoring demos show that metrics are being collected. This project answers a
different question: **does the alert fire, does it reach the receiver, and is recovery
confirmed — and what exactly proves it?**

`k3s` · `Prometheus` · `Alertmanager` · `Grafana` · `Loki` · `Grafana Alloy` ·
`Toxiproxy` · `Node.js` · `Helmfile` · `Kustomize` · `GitHub Actions`

> **State: v1.1.** Six `PrometheusRule` objects, 11 groups, 49 rules (29 alerts:
> 25 `ticket`, 4 `page`; plus 20 recording rules), one Loki ruler rule, three
> dashboards and four drills. The offline gates need no cluster, and every live claim
> carries a date and its limits in [docs/verification.md](docs/verification.md). The
> runbook, the evidence reports and the alert e-mail are in Russian.

## What this proves

- **SLOs are measured from the client's side.** Load goes through Toxiproxy and the
  client records the outcome, so latency and resets injected on the proxy appear
  exactly as a user would feel them — the service's own metrics cannot see them.
  Availability is 99 %, latency (share of requests under 300 ms) is 95 %, over a
  three-day window.
- **An alert is a delivery, not a `firing` state.** Routes are keyed by `severity`:
  `page` and `critical` go to e-mail, everything else to a webhook sink that keeps a
  journal. The mail branch does not exclude the sink, the `AlertSink.*` branch is
  evaluated first with `continue: true`, and an explicit catch-all keeps an unknown
  severity from disappearing silently.
- **Logs are a second class of evidence.** Loki collects pod stdout through Alloy,
  Grafana shows logs next to metrics, and one Loki ruler rule raises an alert from log
  content. A `page` e-mail links the runbook, the dashboard and the logs of exactly the
  incident window (±15 minutes).
- **Drills instead of promises.** Four scenarios run against the live stand and write a
  JSON timeline: events, reaction time, `firing`/`resolved` and the delivery record from
  the sink. An alert that Prometheus fired but never delivered fails the drill.
- **Gates fail on drift.** One command runs linters, application tests, chart rendering
  with schema validation, `promtool check/test rules`, link and e-mail-template checks,
  plus secret and address scans. The assertions test themselves with mutations, and CI
  runs the same gates.

## Architecture

Everything runs on two k3s nodes in two namespaces, `demo` and `monitoring`: the demo
apps and the alert sink in the first, the monitoring stack and the alert route in the
second.

<p align="center">
  <img src="docs/architecture.svg" width="100%" alt="Architecture: demo-load sends five requests per second through Toxiproxy to demo-api; Prometheus scrapes demo-api metrics, Alloy reads its JSON logs through the Kubernetes API into Loki; Grafana queries both stores; Prometheus and the Loki ruler send alerts to Alertmanager, which routes page and critical to e-mail and everything else to alert-sink; the sink's own logs and metrics return to Alloy and Prometheus.">
</p>

| Layer | What runs there |
|---|---|
| Orchestration | k3s, two nodes, Traefik ingress built in |
| Metrics and alerts | Prometheus and Alertmanager from kube-prometheus-stack `92.14.1` |
| Visualisation | Grafana, three dashboards provisioned from ConfigMaps |
| Logs | Loki `3.6.11` (single binary, 5 GiB PVC) and Grafana Alloy `1.21.3` as a DaemonSet |
| Fault injection | Toxiproxy between the generator and the service |
| Demo services | Node.js: `demo-api`, `demo-load`, `alert-sink` |
| Delivery | Helmfile for third-party charts, Kustomize for the project's own manifests |
| Checks | GitHub Actions plus the project's own assertions |

`demo-load` keeps 5 rps through `toxiproxy`; `demo-api` answers `/work`, exposes
`/metrics` and writes one JSON line per request. Prometheus records 20 SLI and burn-rate
series, Alloy reads pod logs through the Kubernetes API (no hostPath, no root) and
writes them to Loki, Grafana queries both stores. Alerts go to Alertmanager, which
routes them as described below. The sink sits inside the loop: its stdout is collected
like any pod's and its metrics are scraped like any app's.

Four choices shape the numbers, and none of them can be read from a single YAML file:

- **Only `page` and `ticket`.** The chart ships an `InfoInhibitor`, which silences any
  single `info` alert in a namespace, so an `info` rule would look healthy by staying
  quiet. Every project rule is `page` or `ticket`, and rules that seem informational
  are `ticket` on purpose.
- **Alloy drops lines older than 50 minutes** before writing to Loki: after a pod
  restart logs are re-read from the beginning, and Loki rejects chunks older than one
  hour. Losses are counted in `AlloyDroppedLogs` and `AlloyOldLogsDropped` instead of
  disappearing.
- **No arithmetic in Alertmanager templates.** The log link is built from
  `time` + `time.window`, because `toDuration` does not exist in the template engine;
  the ±15-minute incident window is therefore computed by Grafana.
- **`up == 0` and `absent(up)` are separate rules.** A target that stopped answering
  and a target that was never discovered are different failures with different fixes.

## Alert path

<p align="center">
  <img src="docs/alert-path.svg" width="100%" alt="Alert route: Prometheus and the Loki ruler send alerts to Alertmanager, which evaluates four child routes in order — AlertSink alerts and page or critical severity go to e-mail with continue true, ticket, info, warning or none go to alert-sink, and a catch-all without matchers sends anything else to alert-sink. Three heartbeat rules and two group guards watch the route itself.">
</p>

| # | Matcher | Receiver | Why |
|---|---|---|---|
| 1 | `alertname =~ "AlertSink.*"` | e-mail | evaluated first with `continue: true`: news about a broken route must not travel only through the broken route |
| 2 | `severity =~ "page\|critical"` | e-mail | `continue: true`, so the sink also gets the event — two recipients for different purposes, not a duplicate |
| 3 | `severity =~ "ticket\|info\|warning\|none"` | alert-sink | the working-hours journal: `/timeline` and the `alertsink_*` metrics |
| 4 | *no matchers* | alert-sink | catch-all: a new, misspelled or missing severity cannot fall into a null receiver |

Three `ticket` rules watch the path itself, because the chart has no rule that would
notice a silent route: route silent for 5.5 hours, sink up with zero events, and the
sink's scrape target gone. Two more rules guard the guard groups: `AlertPathRulesAbsent` and
`LogsPipelineRulesAbsent` fire if their rule groups vanish — a `PrometheusRule` that
was not applied or lost its `release` label otherwise looks like "no problem".

Delivery is gated at deploy time as well. `scripts/deploy.sh` renders an overlay with
real addresses and refuses to apply placeholder `example.invalid` values over live ones
unless explicitly allowed, and it checks the whole route tree in the active
Alertmanager configuration — addresses without a tree are only half the truth.

## How it looks

The screenshots come from the live stand. The `demo-red` frame was taken within an hour
of the `errors` drill: the error spike, the recovery and the latency SLO are visible,
the error budget is on the second frame.

![Dashboard demo — RED and latency](docs/images/demo-red.png)

*RPS, error ratio, p95 and the latency SLO as seen by the client and by the server;
below, live namespace logs from Loki.*

![Dashboard demo — SLI/SLO and burn rate](docs/images/slo-demo.png)

*Remaining error budget, current SLI over three days, burn rate by window and the
per-SLO breakdown.*

![E-mail for a page alert](docs/images/alert-email.png)

*A `page` e-mail: status, severity, links to the runbook, the dashboard, the incident
log window and Alertmanager, time in MSK and UTC. The frame is from a training probe.*

## Quick start

No cluster is needed to see the project check itself. You need `git`, `python3` with
PyYAML and `npm`; `--smoke` also needs Docker.

```bash
git clone https://github.com/morgenvor/k8s-observability-lab.git
cd k8s-observability-lab
./scripts/bootstrap-tools.sh   # kubectl, helm, helmfile, kubeconform, promtool, alloy
./scripts/check.sh --strict    # linters, tests, render, promtool, scans
```

`./scripts/check.sh --smoke` also builds the images and runs the three services in
Docker. The live stand, deployment, rollback and diagnostics are in the
[runbook](docs/runbook.md).

## Quality gates

`./scripts/check.sh` is the single set of offline gates, and it is the same job CI runs
(`ci.yml`, with `--strict --smoke`). What it actually checks:

- both render paths — Helmfile releases and Kustomize resources — validated with
  `kubeconform`, plus semantic assertions on Loki, Alloy, ingress and PVC settings;
- the alert route as a tree, the `AlertmanagerConfig` wiring, the Loki ruler path and
  rule placement (labels, namespace, kustomization membership);
- `promtool check rules` and `promtool test rules`: five fixture sets, every one of the
  29 alerts has a case that fires, and the medium/slow burn cases assert that exactly
  one alert fires;
- the e-mail template rendered with the Go standard library engine and a re-created
  Alertmanager `FuncMap`: required fields, the incident window, exactly one stand link;
- dashboards: JSON validity, panel queries matched against application sources and
  recording rules, and self-checks that fail when the checker itself is mutated;
- ServiceMonitor selectors, the deploy overlay parity, `shellcheck`, drill signal
  tests, and scans for secrets and personal addresses (all hits are
  `example.invalid`/`example.com`).

What the gates do not do: they cannot see a screenshot, they do not prove that a
notification reached a mailbox, and under `--strict` any skipped step is a failure
rather than a silent pass.

## Drills and evidence

| Drill | Injection | Expected signal | Measured reaction |
|---|---|---|---|
| `errors` | `reset_peer` on the Toxiproxy proxy: every connection is dropped | availability SLI collapses, `SloDemoAvailabilityBurnFast` (`page`) | 11.5 min to `page` |
| `latency` | 400 ± 50 ms of network latency on the proxy | p95 above 300 ms while requests still succeed, `SloDemoLatencyBurnFast` (`page`) | 26 min to `page` |
| `readiness` | readiness probe pointed at `/nope`, pods recreated | zero ready endpoints, availability `page` | 19.3 min to `page` |
| `oomkill` | a 200 MiB write inside a `192Mi` container | `KubePodOOMKilled` (`ticket`) and the event in `/timeline` | 102 s |

Each run writes `evidence/<date>-<drill>.json` in the `drill-evidence/v1` schema and a
console transcript. A rerun does not overwrite proof: the previous file is moved to
`evidence/attempts/` with an `-attemptN` suffix first. The scenarios, preconditions and
cleanup are described in [docs/drills.md](docs/drills.md).

## Repository layout

| Path | Purpose |
|---|---|
| [`helmfile.yaml`](helmfile.yaml), [`helm/values/`](helm/values) | third-party charts with pinned versions and the project's values |
| [`kustomization.yaml`](kustomization.yaml), [`deploy/`](deploy) | own manifests: apps, Toxiproxy, ServiceMonitors, dashboards, Loki rules, `AlertmanagerConfig` |
| [`rules/`](rules) | six `PrometheusRule` objects and `promtool` fixtures in [`rules/tests/`](rules/tests) |
| [`app/`](app) | `demo-api`, `demo-load`, `alert-sink` — Node.js with unit tests |
| [`drills/`](drills), [`evidence/`](evidence) | four drill scripts with shared library, and their JSON transcripts |
| [`scripts/`](scripts) | `check.sh` and its assertions in `scripts/checks/`, plus bootstrap, deploy, rollback, image import and smoke |
| [`docs/`](docs) | runbook, drills, verification, and the SVG diagrams used above |
| [`.github/workflows/ci.yml`](.github/workflows/ci.yml) | offline gates in CI |

## What is not verified

- **Offline only:** the slow-burn alert (1x over three days), 5.5 hours of route
  silence, a failing ruler evaluation, and a real 5xx line from `demo-api` — the only
  source of 5xx is `/ready` draining on shutdown, which the rule excludes on purpose.
  The missing-scrape-target guard was confirmed live on 2026-11-10; the other two
  heartbeat rules are covered by `promtool` tests only.
- **The lab is not production.** There is no registry (images are imported on each node
  and tagged with the short git SHA), no TLS, Prometheus and Alertmanager are open
  without authentication, Grafana requires a login, and UI hosts are `*.lab.internal`
  placeholders that you map in `/etc/hosts`.
- **E-mail depends on SMTP egress.** If the port is closed the configuration stays
  valid and the mail simply does not leave the stand.
- **Screenshots are not checked by gates.** They are from the live stand, and the
  e-mail frame is a training probe rather than an incident.

## Requirements

- Local: `git`, `python3` with PyYAML, `npm`; Docker for `--smoke`; x86_64 only — the
  bootstrap script installs amd64 binaries. The e-mail template check uses the Go
  toolchain when it is installed and is skipped (a failure under `--strict`) otherwise.
- Live stand: two k3s nodes with a default StorageClass and Traefik (built into k3s), an
  environment overlay for alert addresses, SMTP host and `GRAFANA_BASE_URL`, and a
  Secret that holds the SMTP password.

## Documentation

| File | What it covers |
|---|---|
| [docs/runbook.md](docs/runbook.md) | procedures: tools, images, deploy/rollback, UI access, logs, the notification route, reaction to each alert |
| [docs/drills.md](docs/drills.md) | the four drills: injection, what a user should see, evidence schema, typical failures |
| [docs/verification.md](docs/verification.md) | what is proven, with date, command and result; what is still only covered offline |
| [evidence/](evidence) | drill JSON timelines and console transcripts |
| [README.ru.md](README.ru.md) | the Russian version of this file |

## References

- [Alerting on SLOs](https://sre.google/workbook/alerting-on-slos/) — multi-window,
  multi-burn-rate alerts
- [Prometheus alerting rules](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/)
- [Alertmanager configuration](https://prometheus.io/docs/alerting/latest/configuration/)
- [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Grafana Loki](https://grafana.com/docs/loki/latest/) · [Grafana Alloy](https://grafana.com/docs/alloy/latest/)
- [Toxiproxy](https://github.com/Shopify/toxiproxy) · [Helmfile](https://helmfile.readthedocs.io/) · [k3s](https://docs.k3s.io/)

## License

MIT — see [LICENSE](LICENSE). The code and configuration can be reused; a link back is
welcome but not required.

## Feedback

Open an issue in
[morgenvor/k8s-observability-lab](https://github.com/morgenvor/k8s-observability-lab/issues).