package config

import (
	"os"
	"path/filepath"
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

func TestMessagingDefaultsToHTTPAndNeedsNoBroker(t *testing.T) {
	c, err := Load(platform.NewEnvFrom(map[string]string{}))
	if err != nil || c.Messaging != "http" {
		t.Fatalf("got %q, %v", c.Messaging, err)
	}
}

func TestRabbitMQNeedsAPasswordAndValidatesTheConsumerSettings(t *testing.T) {
	_, err := Load(platform.NewEnvFrom(map[string]string{"MESSAGING": "rabbitmq", "CONSUMER_PREFETCH": "0", "MESSAGING_TYPO": "x"}))
	if err == nil || !strings.Contains(err.Error(), "AMQP_PASSWORD") || !strings.Contains(err.Error(), "CONSUMER_PREFETCH") {
		t.Fatalf("expected both problems, got %v", err)
	}
	if _, err := Load(platform.NewEnvFrom(map[string]string{"MESSAGING": "kafka"})); err == nil {
		t.Fatal("an unknown MESSAGING value must be rejected")
	}
}

func TestPasswordFromAMountedFileAndNeverInTheString(t *testing.T) {
	path := filepath.Join(t.TempDir(), "amqp-password")
	if err := os.WriteFile(path, []byte("file-secret\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	c, err := Load(platform.NewEnvFrom(map[string]string{"MESSAGING": "rabbitmq", "AMQP_PASSWORD_FILE": path}))
	if err != nil || c.AMQP.Password != "file-secret" {
		t.Fatalf("got %q, %v", c.AMQP.Password, err)
	}
	if strings.Contains(c.AMQP.String(), "file-secret") {
		t.Fatal("the password must not appear in the printable configuration")
	}
	both := map[string]string{"MESSAGING": "rabbitmq", "AMQP_PASSWORD": "x", "AMQP_PASSWORD_FILE": path}
	if _, err := Load(platform.NewEnvFrom(both)); err == nil {
		t.Fatal("value and file together must be rejected")
	}
	missing := map[string]string{"MESSAGING": "rabbitmq", "AMQP_PASSWORD_FILE": path + ".missing"}
	if _, err := Load(platform.NewEnvFrom(missing)); err == nil {
		t.Fatal("an unreadable password file must be rejected")
	}
}
