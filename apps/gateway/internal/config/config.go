// Package config reads the gateway's settings from environment variables.
package config

import (
	"time"

	"github.com/Franklindot04/Multi-Cloud-SRE-Platform/apps/gateway/internal/platform"
)

// Config is the validated configuration of the gateway.
type Config struct {
	Port             int
	LogLevel         string
	MaxBodyBytes     int64
	OrdersURL        string
	PaymentsURL      string
	UpstreamTimeout  time.Duration
	ReadinessTimeout time.Duration
	Version          string
	Commit           string
	DrainPeriod      time.Duration
	ShutdownTimeout  time.Duration
	Fault            platform.FaultConfig
}

// Load validates the environment. Every problem is reported together.
func Load(env *platform.Env) (Config, error) {
	c := Config{
		Port:             env.Int("PORT", 8080, 1, 65535),
		LogLevel:         env.OneOf("LOG_LEVEL", "info", "debug", "info", "warn", "error"),
		MaxBodyBytes:     int64(env.Int("MAX_BODY_BYTES", 1<<20, 1, 64<<20)),
		OrdersURL:        env.URL("ORDERS_URL", "http://orders:8081"),
		PaymentsURL:      env.URL("PAYMENTS_URL", "http://payments:8082"),
		UpstreamTimeout:  time.Duration(env.Int("UPSTREAM_TIMEOUT_MS", 5000, 100, 120000)) * time.Millisecond,
		ReadinessTimeout: time.Duration(env.Int("READINESS_TIMEOUT_MS", 500, 50, 10000)) * time.Millisecond,
		Version:          env.String("APP_VERSION", "dev"),
		Commit:           env.String("APP_COMMIT", "unknown"),
		DrainPeriod:      time.Duration(env.Int("SHUTDOWN_DRAIN_SECONDS", 5, 0, 300)) * time.Second,
		ShutdownTimeout:  time.Duration(env.Int("SHUTDOWN_TIMEOUT_SECONDS", 20, 1, 600)) * time.Second,
		Fault: platform.FaultConfig{
			Enabled:   env.Bool("FAULT_INJECTION_ENABLED", false),
			LatencyMs: env.Int("FAULT_LATENCY_MS", 0, 0, 60000),
			ErrorRate: env.Float("FAULT_ERROR_RATE", 0, 0, 1),
		},
	}
	return c, env.Err()
}
