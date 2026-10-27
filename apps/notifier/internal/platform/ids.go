package platform

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"regexp"
)

var (
	requestIDPattern   = regexp.MustCompile(`^[A-Za-z0-9._-]{1,128}$`)
	traceparentPattern = regexp.MustCompile(`^00-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})$`)
)

// NewUUID returns a random version 4 UUID.
func NewUUID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(fmt.Sprintf("random source unavailable: %v", err))
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// ValidRequestID reports whether an inbound X-Request-Id can be trusted as-is.
func ValidRequestID(id string) bool {
	return requestIDPattern.MatchString(id)
}

func randomHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(fmt.Sprintf("random source unavailable: %v", err))
	}
	return hex.EncodeToString(b)
}

// Trace is the part of a W3C traceparent that is kept between hops.
type Trace struct {
	TraceID string
	Flags   string
}

// ParseTraceparent returns the trace carried by a valid traceparent header.
func ParseTraceparent(header string) (Trace, bool) {
	m := traceparentPattern.FindStringSubmatch(header)
	if m == nil || m[1] == "00000000000000000000000000000000" || m[2] == "0000000000000000" {
		return Trace{}, false
	}
	return Trace{TraceID: m[1], Flags: m[3]}, true
}

// NewTrace starts a trace when the request did not carry one.
func NewTrace() Trace {
	return Trace{TraceID: randomHex(16), Flags: "01"}
}

// Outbound returns the traceparent for a call to another service: the same trace, a new span.
func (t Trace) Outbound() string {
	return fmt.Sprintf("00-%s-%s-%s", t.TraceID, randomHex(8), t.Flags)
}
