package notifications

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/Franklindot04/Multi-Cloud-SRE-Platform/apps/notifier/internal/platform"
)

// Request is the body of POST /notifications.
type Request struct {
	OrderID string `json:"order_id"`
	Channel string `json:"channel"`
	Message string `json:"message"`
}

// Validate checks the request against the API contract.
func (r Request) Validate() error {
	switch {
	case strings.TrimSpace(r.OrderID) == "" || len(r.OrderID) > 64:
		return errors.New("order_id must be 1-64 characters")
	case !Channels[r.Channel]:
		return errors.New("channel must be one of email, sms, webhook")
	case strings.TrimSpace(r.Message) == "" || len(r.Message) > 1000:
		return errors.New("message must be 1-1000 characters")
	}
	return nil
}

// Handler serves the notification endpoints.
type Handler struct {
	Repo Repository
	Now  func() time.Time
}

// Register adds the routes to mux.
func (h *Handler) Register(mux *http.ServeMux) {
	mux.HandleFunc("POST /notifications", h.create)
	mux.HandleFunc("GET /notifications/{id}", h.get)
}

func (h *Handler) create(w http.ResponseWriter, r *http.Request) {
	var req Request
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			platform.WriteError(w, r, http.StatusRequestEntityTooLarge, "payload_too_large", "request body is too large")
			return
		}
		platform.WriteError(w, r, http.StatusBadRequest, "invalid_json", "request body is not valid JSON for this endpoint")
		return
	}
	if err := req.Validate(); err != nil {
		platform.WriteError(w, r, http.StatusUnprocessableEntity, "validation_error", err.Error())
		return
	}
	n := Notification{
		ID:        platform.NewUUID(),
		OrderID:   req.OrderID,
		Channel:   req.Channel,
		Message:   req.Message,
		Status:    "recorded",
		CreatedAt: h.now(),
	}
	if err := h.Repo.Create(r.Context(), n); err != nil {
		platform.WriteError(w, r, http.StatusServiceUnavailable, "storage_unavailable", "could not store the notification")
		return
	}
	platform.WriteJSON(w, http.StatusCreated, n)
}

func (h *Handler) get(w http.ResponseWriter, r *http.Request) {
	n, ok, err := h.Repo.Get(r.Context(), r.PathValue("id"))
	if err != nil {
		platform.WriteError(w, r, http.StatusServiceUnavailable, "storage_unavailable", "could not read the notification")
		return
	}
	if !ok {
		platform.WriteError(w, r, http.StatusNotFound, "not_found", "notification not found")
		return
	}
	platform.WriteJSON(w, http.StatusOK, n)
}

func (h *Handler) now() time.Time {
	if h.Now != nil {
		return h.Now().UTC()
	}
	return time.Now().UTC()
}
