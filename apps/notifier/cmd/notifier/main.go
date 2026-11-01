// Command notifier records the notifications that would be sent for an order. Nothing is delivered.
package main

import (
	"context"
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
	// Run returns after the consumer has finished its messages, so their spans are queued by now.
	err = platform.Run(":"+strconv.Itoa(cfg.Port), handler, drain, cfg.DrainPeriod, cfg.ShutdownTimeout, log, workers...)
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
