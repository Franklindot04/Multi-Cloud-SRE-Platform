package platform

import (
	"context"
	"net/http"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Check is a readiness check on a dependency. A failing required check makes /readyz return 503;
// a failing optional check is reported as "degraded" and does not.
type Check struct {
	Name     string
	Required bool
	Fn       func(ctx context.Context) error
}

type status struct {
	Status string            `json:"status"`
	Checks map[string]string `json:"checks,omitempty"`
}

// RegisterOps adds /healthz, /readyz and /metrics.
func RegisterOps(mux *http.ServeMux, drain *Drain, reg *prometheus.Registry, timeout time.Duration, checks ...Check) {
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		WriteJSON(w, http.StatusOK, status{Status: "ok"})
	})

	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, r *http.Request) {
		if drain.Draining() {
			WriteJSON(w, http.StatusServiceUnavailable, status{Status: "draining"})
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), timeout)
		defer cancel()

		results := make([]string, len(checks))
		var wg sync.WaitGroup
		for i, c := range checks {
			wg.Add(1)
			go func() {
				defer wg.Done()
				if err := c.Fn(ctx); err != nil {
					if c.Required {
						results[i] = "fail: " + err.Error()
					} else {
						results[i] = "degraded: " + err.Error()
					}
					return
				}
				results[i] = "ok"
			}()
		}
		wg.Wait()

		out := status{Status: "ready"}
		if len(checks) > 0 {
			out.Checks = make(map[string]string, len(checks))
		}
		code := http.StatusOK
		for i, c := range checks {
			out.Checks[c.Name] = results[i]
			if c.Required && results[i] != "ok" {
				out.Status = "not_ready"
				code = http.StatusServiceUnavailable
			}
		}
		WriteJSON(w, code, out)
	})

	mux.Handle("GET /metrics", promhttp.HandlerFor(reg, promhttp.HandlerOpts{}))
}

// HTTPCheck checks that GET baseURL/readyz answers 200 within the context deadline.
func HTTPCheck(name, baseURL string, client *http.Client, required bool) Check {
	return Check{Name: name, Required: required, Fn: func(ctx context.Context) error {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+"/readyz", nil)
		if err != nil {
			return err
		}
		resp, err := client.Do(req)
		if err != nil {
			return err
		}
		defer func() { _ = resp.Body.Close() }()
		if resp.StatusCode != http.StatusOK {
			return &StatusError{Code: resp.StatusCode}
		}
		return nil
	}}
}

// StatusError reports an unexpected HTTP status from a dependency.
type StatusError struct{ Code int }

func (e *StatusError) Error() string { return "unexpected status " + http.StatusText(e.Code) }
