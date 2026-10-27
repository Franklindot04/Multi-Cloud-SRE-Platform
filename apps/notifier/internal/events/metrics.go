package events

import "github.com/prometheus/client_golang/prometheus"

// Results of handling one message. A fixed set keeps the label cardinality bounded.
const (
	ResultProcessed  = "processed"
	ResultDuplicate  = "duplicate"
	ResultRetry      = "retry"
	ResultDeadLetter = "dead_letter"
	ResultError      = "error"
)

// Metrics are the consumer's series.
type Metrics struct {
	Consumed    *prometheus.CounterVec
	DeadLetters prometheus.Counter
	Queue       *prometheus.GaugeVec
	Connected   prometheus.Gauge
}

// NewMetrics registers the metrics on reg.
func NewMetrics(reg prometheus.Registerer) *Metrics {
	m := &Metrics{
		Consumed: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "messages_consumed_total",
			Help: "Messages taken off the queue, by how they were handled.",
		}, []string{"result"}),
		DeadLetters: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "dead_letter_messages_total",
			Help: "Messages moved to the dead-letter queue.",
		}),
		Queue: prometheus.NewGaugeVec(prometheus.GaugeOpts{
			Name: "consumer_queue_messages",
			Help: "Messages waiting in the consumer's queues (queue is main, retry or dead_letter).",
		}, []string{"queue"}),
		Connected: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "amqp_connected",
			Help: "1 while the consumer has a working broker connection.",
		}),
	}
	for _, r := range []string{ResultProcessed, ResultDuplicate, ResultRetry, ResultDeadLetter, ResultError} {
		m.Consumed.WithLabelValues(r)
	}
	for _, q := range []string{"main", "retry", "dead_letter"} {
		m.Queue.WithLabelValues(q)
	}
	reg.MustRegister(m.Consumed, m.DeadLetters, m.Queue, m.Connected)
	return m
}
