package platform

import (
	"github.com/prometheus/client_golang/prometheus"
)

// Buckets are shared by every service so that latency can be compared across them.
var Buckets = []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10}

// Metrics holds the HTTP metrics every service exposes under the same names.
type Metrics struct {
	Requests *prometheus.CounterVec
	Duration *prometheus.HistogramVec
	InFlight prometheus.Gauge
}

// NewMetrics registers the metrics on reg.
func NewMetrics(service string, reg prometheus.Registerer) *Metrics {
	m := &Metrics{
		Requests: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "Total HTTP requests handled.",
		}, []string{"service", "method", "route", "status"}),
		Duration: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Name:    "http_request_duration_seconds",
			Help:    "HTTP request latency in seconds.",
			Buckets: Buckets,
		}, []string{"service", "method", "route"}),
		InFlight: prometheus.NewGauge(prometheus.GaugeOpts{
			Name:        "http_requests_in_flight",
			Help:        "HTTP requests currently being handled.",
			ConstLabels: prometheus.Labels{"service": service},
		}),
	}
	reg.MustRegister(m.Requests, m.Duration, m.InFlight)
	return m
}
