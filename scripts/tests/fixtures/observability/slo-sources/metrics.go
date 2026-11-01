package fixture

// Names and buckets as the sample services define them (a copy of what the SLO rules use, for the contract check).

var Buckets = []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10}

var names = []string{
	"http_requests_total",
	"http_request_duration_seconds",
	"messages_consumed_total",
	"amqp_connected",
	"outbox_oldest_unpublished_age_seconds",
}
