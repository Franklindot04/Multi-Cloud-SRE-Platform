// Command gateway is the public entry point of the order platform.
package main

import (
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
	cfg, err := config.Load(platform.NewEnv())
	if err != nil {
		fmt.Fprintf(os.Stderr, "invalid configuration:\n%v\n", err)
		os.Exit(2)
	}
	log := platform.NewLogger(os.Stdout, service, cfg.LogLevel)

	reg := prometheus.NewRegistry()
	reg.MustRegister(collectors.NewGoCollector(), collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}))
	metrics := platform.NewMetrics(service, reg)

	upstream := &http.Client{Timeout: cfg.UpstreamTimeout}
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
	if err := platform.Run(":"+strconv.Itoa(cfg.Port), handler, drain, cfg.DrainPeriod, cfg.ShutdownTimeout, log); err != nil {
		log.Error("server failed", "error", err.Error())
		os.Exit(1)
	}
}
