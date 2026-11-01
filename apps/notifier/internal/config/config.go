// Package config reads the notifier's settings from environment variables.
package config

import (
	"fmt"
	"time"

	"github.com/Franklindot04/Multi-Cloud-SRE-Platform/apps/notifier/internal/platform"
)

// Config is the validated configuration of the notifier.
type Config struct {
	Port             int
	LogLevel         string
	MaxBodyBytes     int64
	MaxNotifications int
	Version          string
	DrainPeriod      time.Duration
	ShutdownTimeout  time.Duration
	Fault            platform.FaultConfig

	// Messaging selects how events arrive: "http" (the POST /notifications endpoint only, the default)
	// or "rabbitmq" (the same endpoint plus a RabbitMQ consumer).
	Messaging string
	AMQP      AMQP
}

// AMQP holds the broker and consumer settings, read only when MESSAGING=rabbitmq.
type AMQP struct {
	Host           string
	Port           int
	User           string
	Password       string
	VHost          string
	ConnectTimeout time.Duration
	MaxBackoff     time.Duration
	Prefetch       int
	MaxAttempts    int
	RetryDelay     time.Duration
	DedupeSize     int
}

// String hides the password so a logged configuration never contains it.
func (a AMQP) String() string {
	return fmt.Sprintf("{Host:%s Port:%d User:%s VHost:%s Prefetch:%d MaxAttempts:%d}", a.Host, a.Port, a.User, a.VHost, a.Prefetch, a.MaxAttempts)
}

// Load validates the environment. Every problem is reported together.
func Load(env *platform.Env) (Config, error) {
	c := Config{
		Port:             env.Int("PORT", 8083, 1, 65535),
		LogLevel:         env.OneOf("LOG_LEVEL", "info", "debug", "info", "warn", "error"),
		MaxBodyBytes:     int64(env.Int("MAX_BODY_BYTES", 1<<20, 1, 64<<20)),
		MaxNotifications: env.Int("MAX_NOTIFICATIONS", 100000, 1, 10000000),
		Version:          env.String("APP_VERSION", "dev"),
		DrainPeriod:      time.Duration(env.Int("SHUTDOWN_DRAIN_SECONDS", 5, 0, 300)) * time.Second,
		ShutdownTimeout:  time.Duration(env.Int("SHUTDOWN_TIMEOUT_SECONDS", 20, 1, 600)) * time.Second,
		Fault: platform.FaultConfig{
			Enabled:   env.Bool("FAULT_INJECTION_ENABLED", false),
			LatencyMs: env.Int("FAULT_LATENCY_MS", 0, 0, 60000),
			ErrorRate: env.Float("FAULT_ERROR_RATE", 0, 0, 1),
		},
	}
	c.Messaging = env.OneOf("MESSAGING", "http", "http", "rabbitmq")
	if c.Messaging == "rabbitmq" {
		c.AMQP = AMQP{
			Host:           env.String("AMQP_HOST", "rabbitmq"),
			Port:           env.Int("AMQP_PORT", 5672, 1, 65535),
			User:           env.String("AMQP_USER", "platform"),
			Password:       env.Secret("AMQP_PASSWORD", true),
			VHost:          env.String("AMQP_VHOST", "/"),
			ConnectTimeout: time.Duration(env.Int("AMQP_CONNECT_TIMEOUT_MS", 3000, 100, 60000)) * time.Millisecond,
			MaxBackoff:     time.Duration(env.Int("AMQP_RECONNECT_MAX_BACKOFF_SECONDS", 30, 1, 600)) * time.Second,
			Prefetch:       env.Int("CONSUMER_PREFETCH", 10, 1, 1000),
			MaxAttempts:    env.Int("CONSUMER_MAX_ATTEMPTS", 3, 1, 20),
			RetryDelay:     time.Duration(env.Int("CONSUMER_RETRY_DELAY_MS", 5000, 100, 3600000)) * time.Millisecond,
			DedupeSize:     env.Int("CONSUMER_DEDUPE_SIZE", 10000, 100, 10000000),
		}
	}
	return c, env.Err()
}
