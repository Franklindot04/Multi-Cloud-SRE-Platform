// Package config reads the notifier's settings from environment variables.
package config

import (
	"time"

	"github.com/Franklindot04/Multi-Cloud-SRE-Platform/apps/notifier/internal/platform"
)

// Config is the validated configuration of the notifier.
type Config struct {
	Port             int
	LogLevel         string
	MaxBodyBytes     int64
	MaxNotifications int
	DrainPeriod      time.Duration
	ShutdownTimeout  time.Duration
	Fault            platform.FaultConfig
}

// Load validates the environment. Every problem is reported together.
func Load(env *platform.Env) (Config, error) {
	c := Config{
		Port:             env.Int("PORT", 8083, 1, 65535),
		LogLevel:         env.OneOf("LOG_LEVEL", "info", "debug", "info", "warn", "error"),
		MaxBodyBytes:     int64(env.Int("MAX_BODY_BYTES", 1<<20, 1, 64<<20)),
		MaxNotifications: env.Int("MAX_NOTIFICATIONS", 100000, 1, 10000000),
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
