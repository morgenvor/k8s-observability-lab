// Рендер шаблона письма без кластера: ловит то, что не видят ни kubeconform, ни promtool.
//
// Зачем: ошибка выполнения шаблона не «портит письмо», а отменяет уведомление целиком
// (Alertmanager считает доставку неуспешной и ретраит её). Ошибку синтаксиса поймает
// reload конфига, а ошибку выполнения — только счётчик notifications_failed_total
// на живом стенде, то есть уже после того, как page-алерт потерян.
//
// Что проверяется: обе части письма рендерятся без ошибок с page-алертом, ссылки на
// ранбук/дашборд/логи/Alertmanager на месте, окно `time`+`time.window` и `from`+`to`
// содержат epoch-миллисекунды startsAt, у чартового critical без logs_url ссылок на
// демо-дашборд нет, пустых href не бывает.
//
// Границы (shortcut): функции шаблонов Alertmanager (toUpper/date/tz/join/…) повторены
// здесь вручную — так ворота не зависят от скачивания модулей; расхождение с реальным
// движком ловится живой пробой (docs/runbook.md, «Проверка» в e-mail-разделе). Улучшать
// здесь стоит только при появлении функции, которой нет в map ниже.
//
// Использование: go run email_template.go <каталог с email-text.tpl и email-html.tpl>
package main

import (
	"fmt"
	"html/template"
	"os"
	"path/filepath"
	"strings"
	tmpltext "text/template"
	"time"
)

// Alert — подмножество template.Alert из Alertmanager: остальные поля шаблон не читает.
type Alert struct {
	Status       string
	Labels       map[string]string
	Annotations  map[string]string
	StartsAt     time.Time
	EndsAt       time.Time
	GeneratorURL string
}

// Data — подмножество template.Data; $.ExternalURL нужен вне range .Alerts.
type Data struct {
	Status      string
	Alerts      []Alert
	ExternalURL string
}

var funcs = template.FuncMap{
	"toUpper": strings.ToUpper,
	"toLower": strings.ToLower,
	"trimSpace": strings.TrimSpace,
	"title": func(s string) string {
		if s == "" {
			return s
		}
		return strings.ToUpper(s[:1]) + s[1:]
	},
	"join": func(sep string, items []string) string {
		return strings.Join(items, sep)
	},
	"safeHtml": func(s string) template.HTML { return template.HTML(s) },
	"safeUrl":  func(s string) template.URL { return template.URL(s) },
	"urlquery": func(s string) string { return template.URLQueryEscaper(s) },
	"date": func(layout string, t time.Time) string {
		return t.Format(layout)
	},
	// tz повторяет Alertmanager: ошибка загрузки зоны — ошибка рендера, а не молчание.
	"tz": func(name string, t time.Time) (time.Time, error) {
		loc, err := time.LoadLocation(name)
		if err != nil {
			return time.Time{}, err
		}
		return t.In(loc), nil
	},
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}

func mustRead(path string) string {
	raw, err := os.ReadFile(path)
	if err != nil {
		fail("не читается %s: %v", path, err)
	}
	return string(raw)
}

func pageData() Data {
	start := time.Date(2026, 11, 10, 11, 26, 33, 0, time.UTC)
	return Data{
		Status: "firing",
		Alerts: []Alert{{
			Status: "firing",
			Labels: map[string]string{
				"alertname": "SloDemoAvailabilityBurnFast",
				"severity":  "page",
				"namespace": "demo",
				"service":   "demo-api",
			},
			Annotations: map[string]string{
				"summary":       "demo-api: быстрый расход бюджета доступности (SLO 99 %)",
				"description":   "Доступность demo-api тратит бюджет ошибок со скоростью 20.1x.",
				"runbook_url":   "https://github.com/morgenvor/k8s-observability-lab/blob/main/docs/runbook.md#slodemoavailabilityburnfast",
				"dashboard_url": "http://grafana.example.com/d/demo-slo",
				"logs_url":      "http://grafana.example.com/d/demo-red?viewPanel=5",
			},
			StartsAt:     start,
			GeneratorURL: "http://prometheus.example.com/graph?g0.expr=up",
		}},
		ExternalURL: "http://alertmanager.example.com",
	}
}

func chartData() Data {
	data := pageData()
	data.Alerts[0].Labels = map[string]string{
		"alertname": "NodeFilesystemAlmostOutOfSpace",
		"severity":  "critical",
	}
	data.Alerts[0].Annotations = map[string]string{
		"summary":     "Filesystem has less than 3% space left.",
		"description": "Node filesystem almost out of space.",
	}
	return data
}

func resolvedData() Data {
	data := pageData()
	data.Status = "resolved"
	data.Alerts[0].Status = "resolved"
	data.Alerts[0].EndsAt = data.Alerts[0].StartsAt.Add(5 * time.Minute)
	return data
}

func renderText(tpl string, data Data) (string, error) {
	t, err := tmpltext.New("text").Option("missingkey=zero").Funcs(funcs).Parse(tpl)
	if err != nil {
		return "", fmt.Errorf("шаблон не разбирается: %w", err)
	}
	var out strings.Builder
	if err := t.Execute(&out, data); err != nil {
		return "", fmt.Errorf("ошибка выполнения (письмо не уйдёт): %w", err)
	}
	return out.String(), nil
}

func renderHTML(tpl string, data Data) (string, error) {
	t, err := template.New("html").Option("missingkey=zero").Funcs(funcs).Parse(tpl)
	if err != nil {
		return "", fmt.Errorf("шаблон не разбирается: %w", err)
	}
	var out strings.Builder
	if err := t.Execute(&out, data); err != nil {
		return "", fmt.Errorf("ошибка выполнения (письмо не уйдёт): %w", err)
	}
	return out.String(), nil
}

func mustRender(part, tpl string, data Data) string {
	var (
		out string
		err error
	)
	if part == "html" {
		out, err = renderHTML(tpl, data)
	} else {
		out, err = renderText(tpl, data)
	}
	if err != nil {
		fail("%s: %v", part, err)
	}
	return out
}

// selfCheck: рендерер обязан падать на заведомо битом шаблоне. Иначе «зелёный» шаг
// ничего не доказывает: пустой или всегда-успешный рендер пропустил бы и toDuration,
// которой нет в Alertmanager 0.34.1.
func selfCheck() {
	cases := []struct {
		name string
		tpl  string
	}{
		{"несуществующая функция (toDuration)", `{{ toDuration "-15m" }}`},
		{"поле, которого нет у алерта", `{{ range .Alerts }}{{ .Nope.Field }}{{ end }}`},
	}
	for _, tc := range cases {
		if _, err := renderText(tc.tpl, pageData()); err == nil {
			fail("самопроверка «%s»: рендер прошёл молча", tc.name)
		}
		if _, err := renderHTML(tc.tpl, pageData()); err == nil {
			fail("самопроверка «%s»: html-рендер прошёл молча", tc.name)
		}
	}
}

func requireContains(part, body string, tokens ...string) {
	for _, token := range tokens {
		if !strings.Contains(body, token) {
			fail("%s: нет %q — в письме не будет этого факта или ссылки", part, token)
		}
	}
}

func requireAbsent(part, body string, tokens ...string) {
	for _, token := range tokens {
		if strings.Contains(body, token) {
			fail("%s: лишнее %q — шаблон показывает то, чего у алерта нет", part, token)
		}
	}
}

func main() {
	if len(os.Args) != 2 {
		fail("использование: go run email_template.go <каталог с email-*.tpl>")
	}
	dir := os.Args[1]
	textTpl := mustRead(filepath.Join(dir, "email-text.tpl"))
	htmlTpl := mustRead(filepath.Join(dir, "email-html.tpl"))

	const windowMS = "time=1794309993000&time.window=1800000"
	const nowMS = "from=1794309993000&to=now"

	// 1. Page-алерт: полный набор фактов и ссылок в обеих частях.
	selfCheck()

	pageText := mustRender("text", textTpl, pageData())
	requireContains("text (page)", pageText,
		"FIRING [page] SloDemoAvailabilityBurnFast",
		"Сервис: demo-api",
		"demo-api: быстрый расход бюджета доступности",
		"Ранбук: https://github.com/morgenvor/k8s-observability-lab",
		"#slodemoavailabilityburnfast",
		"Дашборд: http://grafana.example.com/d/demo-slo",
		windowMS,
		nowMS,
		"10.11.2026 14:26:33 MSK",
		"2026-11-10 11:26:33 UTC",
		"Стенд: http://alertmanager.example.com",
	)
	requireAbsent("text (page)", pageText, "{{", "}}")

	pageHTML := mustRender("html", htmlTpl, pageData())
	requireContains("html (page)", pageHTML,
		"FIRING [page] SloDemoAvailabilityBurnFast",
		`href="https://github.com/morgenvor/k8s-observability-lab`,
		"#slodemoavailabilityburnfast",
		`href="http://grafana.example.com/d/demo-slo"`,
		`href="http://grafana.example.com/d/demo-red?viewPanel=5&amp;time=1794309993000`,
		"&amp;time.window=1800000",
		"&amp;from=1794309993000&amp;to=now",
		`href="http://prometheus.example.com/graph`,
		`href="http://alertmanager.example.com"`,
		"10.11.2026 14:26:33 MSK",
	)
	requireAbsent("html (page)", pageHTML, `href=""`, "{{", "}}")

	// 2. Чартовый critical без наших аннотаций: ссылки на демо-дашборд и пустые href
	//    не появляются — иначе письмо вело бы на чужой дашборд.
	chartHTML := mustRender("html", htmlTpl, chartData())
	requireContains("html (critical)", chartHTML,
		"FIRING [critical] NodeFilesystemAlmostOutOfSpace",
		`href="http://prometheus.example.com/graph`,
	)
	requireAbsent("html (critical)", chartHTML,
		"viewPanel", "demo-slo", "Ранбук", "Дашборд", "href=\"\"", "{{",
	)
	chartText := mustRender("text", textTpl, chartData())
	requireAbsent("text (critical)", chartText, "Ранбук:", "Дашборд:", "viewPanel")

	// 3. Resolved: та же вёрстка, но статус RESOLVED (ветка sendResolved).
	resolvedHTML := mustRender("html", htmlTpl, resolvedData())
	requireContains("html (resolved)", resolvedHTML, "RESOLVED", `href="http://alertmanager.example.com"`)

	fmt.Printf(
		"шаблон письма: text %d символов, html %d символов; page/firing, critical, resolved — ok\n",
		len(pageText), len(pageHTML),
	)
}