// Command notifier records the notifications that would be sent for an order. Nothing is delivered.
package main

import (
	"fmt"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"

	"github.com/Franklindot04/Multi-Cloud-SRE-Platform/apps/notifier/internal/config"
	"github.com/Franklindot04/Multi-Cloud-SRE-Platform/apps/notifier/internal/events"
	"github.com/Franklindot04/Multi-Cloud-SRE-Platform/apps/notifier/internal/notifications"
	"github.com/Franklindot04/Multi-Cloud-SRE-Platform/apps/notifier/internal/platform"
)

const service = "notifier"

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

	drain := &platform.Drain{}
	mux := http.NewServeMux()
	repo := notifications.NewMemoryRepository(cfg.MaxNotifications)

	var checks []platform.Check
	var workers []platform.Worker
	if cfg.Messaging == "rabbitmq" {
		consumer := &events.Consumer{
			Config: cfg.AMQP,
			Log:    log,
			Proc: &events.Processor{
				Repo: repo, Dedupe: events.NewDedupe(cfg.AMQP.DedupeSize), MaxAttempts: cfg.AMQP.MaxAttempts,
				Metrics: events.NewMetrics(reg), Log: log,
			},
		}
		checks = append(checks, consumer.Check()) // required: without the broker nothing is consumed
		workers = append(workers, consumer)
	}
	platform.RegisterOps(mux, drain, reg, 500*time.Millisecond, checks...)
	(&notifications.Handler{Repo: repo}).Register(mux)

	handler := platform.Wrap(mux, platform.Options{
		Service: service, Logger: log, Metrics: metrics, MaxBody: cfg.MaxBodyBytes, Fault: cfg.Fault,
	})

	if cfg.Fault.Enabled {
		log.Warn("fault injection is ENABLED",
			"latency_ms", cfg.Fault.LatencyMs, "error_rate", cfg.Fault.ErrorRate)
	}
	if err := platform.Run(":"+strconv.Itoa(cfg.Port), handler, drain, cfg.DrainPeriod, cfg.ShutdownTimeout, log, workers...); err != nil {
		log.Error("server failed", "error", err.Error())
		os.Exit(1)
	}
}
