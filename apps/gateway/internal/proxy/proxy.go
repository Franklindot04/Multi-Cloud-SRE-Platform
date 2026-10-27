// Package proxy forwards the public API to the orders and payments services.
package proxy

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"

	"github.com/Franklindot04/Multi-Cloud-SRE-Platform/apps/gateway/internal/platform"
)

const maxResponseBytes = 4 << 20

// forwardedRequestHeaders are the only client headers passed upstream.
var forwardedRequestHeaders = []string{"Content-Type", "Accept", "Idempotency-Key"}

// Gateway forwards requests to the upstream services with an explicit timeout.
type Gateway struct {
	OrdersURL   string
	PaymentsURL string
	Client      *http.Client
	Version     string
	Commit      string
}

// Register adds the routes to mux.
func (g *Gateway) Register(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/orders", func(w http.ResponseWriter, r *http.Request) {
		g.forward(w, r, g.OrdersURL, "/orders")
	})
	mux.HandleFunc("GET /api/orders", func(w http.ResponseWriter, r *http.Request) {
		g.forward(w, r, g.OrdersURL, "/orders")
	})
	mux.HandleFunc("GET /api/orders/{id}", func(w http.ResponseWriter, r *http.Request) {
		g.forward(w, r, g.OrdersURL, "/orders/"+url.PathEscape(r.PathValue("id")))
	})
	mux.HandleFunc("GET /api/payments/{id}", func(w http.ResponseWriter, r *http.Request) {
		g.forward(w, r, g.PaymentsURL, "/payments/"+url.PathEscape(r.PathValue("id")))
	})
	mux.HandleFunc("GET /version", func(w http.ResponseWriter, _ *http.Request) {
		platform.WriteJSON(w, http.StatusOK, map[string]string{"service": "gateway", "version": g.Version, "commit": g.Commit})
	})
}

func (g *Gateway) forward(w http.ResponseWriter, r *http.Request, base, path string) {
	var body io.Reader
	if r.Method == http.MethodPost || r.Method == http.MethodPut {
		data, err := io.ReadAll(r.Body)
		if err != nil {
			var tooLarge *http.MaxBytesError
			if errors.As(err, &tooLarge) {
				platform.WriteError(w, r, http.StatusRequestEntityTooLarge, "payload_too_large", "request body is too large")
				return
			}
			platform.WriteError(w, r, http.StatusBadRequest, "invalid_body", "could not read the request body")
			return
		}
		body = bytes.NewReader(data)
	}

	target := base + path
	if r.URL.RawQuery != "" {
		target += "?" + r.URL.RawQuery
	}
	req, err := http.NewRequestWithContext(r.Context(), r.Method, target, body)
	if err != nil {
		platform.WriteError(w, r, http.StatusInternalServerError, "internal_error", "could not build the upstream request")
		return
	}
	for _, h := range forwardedRequestHeaders {
		if v := r.Header.Get(h); v != "" {
			req.Header.Set(h, v)
		}
	}
	platform.Propagate(r.Context(), req.Header)

	resp, err := g.Client.Do(req)
	if err != nil {
		if isTimeout(err) {
			platform.WriteError(w, r, http.StatusGatewayTimeout, "upstream_timeout", "the upstream service did not answer in time")
			return
		}
		platform.WriteError(w, r, http.StatusBadGateway, "upstream_unavailable", "the upstream service is unavailable")
		return
	}
	defer func() { _ = resp.Body.Close() }()

	if ct := resp.Header.Get("Content-Type"); ct != "" {
		w.Header().Set("Content-Type", ct)
	}
	w.WriteHeader(resp.StatusCode)
	_, _ = io.Copy(w, io.LimitReader(resp.Body, maxResponseBytes))
}

func isTimeout(err error) bool {
	if errors.Is(err, context.DeadlineExceeded) {
		return true
	}
	var ne net.Error
	return errors.As(err, &ne) && ne.Timeout()
}
