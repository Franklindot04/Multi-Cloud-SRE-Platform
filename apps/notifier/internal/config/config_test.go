package config

import (
	"strings"
	"testing"

	"github.com/Franklindot04/Multi-Cloud-SRE-Platform/apps/notifier/internal/platform"
)

func TestDefaults(t *testing.T) {
	c, err := Load(platform.NewEnvFrom(nil))
	if err != nil {
		t.Fatal(err)
	}
	if c.Port != 8083 || c.LogLevel != "info" || c.MaxBodyBytes != 1<<20 || c.Fault.Enabled {
		t.Fatalf("unexpected defaults: %+v", c)
	}
}

func TestInvalidValuesAreAllReported(t *testing.T) {
	_, err := Load(platform.NewEnvFrom(map[string]string{
		"PORT": "99999", "LOG_LEVEL": "loud", "FAULT_ERROR_RATE": "2", "FAULT_INJECTION_ENABLED": "yes",
	}))
	if err == nil {
		t.Fatal("expected an error")
	}
	for _, key := range []string{"PORT", "LOG_LEVEL", "FAULT_ERROR_RATE", "FAULT_INJECTION_ENABLED"} {
		if !strings.Contains(err.Error(), key) {
			t.Errorf("error should mention %s: %v", key, err)
		}
	}
}

func TestFaultSettings(t *testing.T) {
	c, err := Load(platform.NewEnvFrom(map[string]string{
		"FAULT_INJECTION_ENABLED": "true", "FAULT_LATENCY_MS": "250", "FAULT_ERROR_RATE": "0.25",
	}))
	if err != nil {
		t.Fatal(err)
	}
	if !c.Fault.Enabled || c.Fault.LatencyMs != 250 || c.Fault.ErrorRate != 0.25 {
		t.Fatalf("fault settings not read: %+v", c.Fault)
	}
}
