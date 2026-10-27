package platform

import (
	"math/rand/v2"
	"net/http"
	"time"
)

// FaultConfig controls deliberate failures for resilience testing. It is disabled by default.
type FaultConfig struct {
	Enabled   bool
	LatencyMs int
	ErrorRate float64
}

// operational endpoints are never subject to fault injection.
func operational(path string) bool {
	switch path {
	case "/healthz", "/readyz", "/metrics", "/version":
		return true
	}
	return false
}

// faults delays and fails requests according to cfg, except on operational endpoints.
func faults(cfg FaultConfig, next http.Handler) http.Handler {
	if !cfg.Enabled {
		return next
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if operational(r.URL.Path) {
			next.ServeHTTP(w, r)
			return
		}
		if cfg.LatencyMs > 0 {
			select {
			case <-time.After(time.Duration(cfg.LatencyMs) * time.Millisecond):
			case <-r.Context().Done():
				return
			}
		}
		if cfg.ErrorRate > 0 && rand.Float64() < cfg.ErrorRate {
			WriteError(w, r, http.StatusServiceUnavailable, "fault_injected", "failure injected for testing")
			return
		}
		next.ServeHTTP(w, r)
	})
}
