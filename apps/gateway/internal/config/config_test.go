package config

import (
	"strings"
	"testing"
	"time"

	"github.com/Franklindot04/Multi-Cloud-SRE-Platform/apps/gateway/internal/platform"
)

func TestDefaults(t *testing.T) {
	c, err := Load(platform.NewEnvFrom(nil))
	if err != nil {
		t.Fatal(err)
	}
	if c.Port != 8080 || c.OrdersURL != "http://orders:8081" || c.PaymentsURL != "http://payments:8082" ||
		c.UpstreamTimeout != 5*time.Second || c.ReadinessTimeout != 500*time.Millisecond || c.Version != "dev" || c.Fault.Enabled {
		t.Fatalf("unexpected defaults: %+v", c)
	}
}

func TestInvalidValuesAreAllReported(t *testing.T) {
	_, err := Load(platform.NewEnvFrom(map[string]string{
		"ORDERS_URL": "orders:8081", "UPSTREAM_TIMEOUT_MS": "1", "FAULT_LATENCY_MS": "-5", "LOG_LEVEL": "loud",
	}))
	if err == nil {
		t.Fatal("expected an error")
	}
	for _, key := range []string{"ORDERS_URL", "UPSTREAM_TIMEOUT_MS", "FAULT_LATENCY_MS", "LOG_LEVEL"} {
		if !strings.Contains(err.Error(), key) {
			t.Errorf("error should mention %s: %v", key, err)
		}
	}
}

func TestURLTrailingSlashTrimmed(t *testing.T) {
	c, err := Load(platform.NewEnvFrom(map[string]string{"ORDERS_URL": "http://o:1/", "PAYMENTS_URL": "https://p:2"}))
	if err != nil || c.OrdersURL != "http://o:1" || c.PaymentsURL != "https://p:2" {
		t.Fatalf("unexpected: %+v %v", c, err)
	}
}
