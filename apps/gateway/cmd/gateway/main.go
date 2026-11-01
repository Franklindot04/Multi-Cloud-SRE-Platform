// Command gateway is the public entry point of the order platform.
package main

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"strconv"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"

	"github.com/Franklindot04/Multi-Cloud-SRE-Platform/apps/gateway/internal/config"
	"github.com/Franklindot04/Multi-Cloud-SRE-Platform/apps/gateway/internal/platform"
	"github.com/Franklindot04/Multi-Cloud-SRE-Platform/apps/gateway/internal/proxy"
)

const service = "gateway"

func main() {
	env := platform.NewEnv()
	cfg, err := config.Load(env)
	if err != nil {
		fmt.Fprintf(os.Stderr, "invalid configuration:\n%v\n", err)
		os.Exit(2)
	}
	log := platform.NewLogger(os.Stdout, service, cfg.LogLevel)

	// Tracing is off unless OTEL_EXPORTER_OTLP_ENDPOINT is set, and a failure here never stops the service.
	flushTracing, err := platform.InitTracing(context.Background(), env, service, cfg.Version, log)
	if err != nil {
		log.Warn("tracing is disabled", "error", err.Error())
	}

	reg := prometheus.NewRegistry()
	reg.MustRegister(collectors.NewGoCollector(), collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}))
	metrics := platform.NewMetrics(service, reg)

	upstream := &http.Client{Timeout: cfg.UpstreamTimeout, Transport: platform.NewTracedTransport(nil, nil, nil)}
	probe := &http.Client{Timeout: cfg.ReadinessTimeout}
	drain := &platform.Drain{}

	mux := http.NewServeMux()
	platform.RegisterOps(mux, drain, reg, cfg.ReadinessTimeout,
		platform.HTTPCheck("orders", cfg.OrdersURL, probe, true),
		platform.HTTPCheck("payments", cfg.PaymentsURL, probe, true),
	)
	(&proxy.Gateway{
		OrdersURL: cfg.OrdersURL, PaymentsURL: cfg.PaymentsURL, Client: upstream,
		Version: cfg.Version, Commit: cfg.Commit,
	}).Register(mux)

	handler := platform.Wrap(mux, platform.Options{
		Service: service, Logger: log, Metrics: metrics, MaxBody: cfg.MaxBodyBytes, Fault: cfg.Fault,
	})

	if cfg.Fault.Enabled {
		log.Warn("fault injection is ENABLED",
			"latency_ms", cfg.Fault.LatencyMs, "error_rate", cfg.Fault.ErrorRate)
	}
	err = platform.Run(":"+strconv.Itoa(cfg.Port), handler, drain, cfg.DrainPeriod, cfg.ShutdownTimeout, log)
	flushCtx, cancel := context.WithTimeout(context.Background(), platform.TracingFlushTimeout)
	if ferr := flushTracing(flushCtx); ferr != nil {
		log.Warn("could not flush traces", "error", ferr.Error())
	}
	cancel()
	if err != nil {
		log.Error("server failed", "error", err.Error())
		os.Exit(1)
	}
}
