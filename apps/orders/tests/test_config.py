import pytest

from orders.config import Config, ConfigError


def test_defaults() -> None:
    c = Config.load({})
    assert c.port == 8081
    assert c.payments_url == "http://payments:8082"
    assert c.payments_timeout_s == 2.0
    assert c.max_body_bytes == 1 << 20
    assert c.fault.enabled is False


def test_every_problem_is_reported_together() -> None:
    with pytest.raises(ConfigError) as err:
        Config.load(
            {
                "PORT": "70000",
                "PAYMENTS_URL": "payments:8082",
                "PAYMENTS_TIMEOUT_MS": "5",
                "FAULT_ERROR_RATE": "1.5",
                "FAULT_INJECTION_ENABLED": "yes",
                "LOG_LEVEL": "loud",
            }
        )
    message = str(err.value)
    for key in (
        "PORT",
        "PAYMENTS_URL",
        "PAYMENTS_TIMEOUT_MS",
        "FAULT_ERROR_RATE",
        "FAULT_INJECTION_ENABLED",
        "LOG_LEVEL",
    ):
        assert key in message


def test_fault_settings_are_read() -> None:
    c = Config.load({"FAULT_INJECTION_ENABLED": "true", "FAULT_LATENCY_MS": "250", "FAULT_ERROR_RATE": "0.25"})
    assert (c.fault.enabled, c.fault.latency_ms, c.fault.error_rate) == (True, 250, 0.25)


def test_urls_are_trimmed_and_blank_values_use_defaults() -> None:
    c = Config.load({"PAYMENTS_URL": "http://p:1/", "NOTIFIER_URL": "  "})
    assert c.payments_url == "http://p:1"
    assert c.notifier_url == "http://notifier:8083"
