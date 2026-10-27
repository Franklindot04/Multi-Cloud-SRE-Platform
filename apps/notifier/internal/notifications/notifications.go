// Package notifications records the notifications that would be sent. Nothing is delivered.
package notifications

import (
	"context"
	"sync"
	"time"
)

// Channels a notification can use.
var Channels = map[string]bool{"email": true, "sms": true, "webhook": true}

// Notification is a recorded notification.
type Notification struct {
	ID        string    `json:"id"`
	OrderID   string    `json:"order_id"`
	Channel   string    `json:"channel"`
	Message   string    `json:"message"`
	Status    string    `json:"status"`
	CreatedAt time.Time `json:"created_at"`
}

// Repository stores notifications. The in-memory implementation can be replaced by a database
// without changing the handlers.
type Repository interface {
	Create(ctx context.Context, n Notification) error
	Get(ctx context.Context, id string) (Notification, bool, error)
}

// MemoryRepository is a thread-safe in-memory Repository that keeps at most max entries,
// dropping the oldest first so memory stays bounded.
type MemoryRepository struct {
	mu    sync.RWMutex
	max   int
	order []string
	byID  map[string]Notification
}

// NewMemoryRepository creates a repository holding at most max notifications.
func NewMemoryRepository(max int) *MemoryRepository {
	return &MemoryRepository{max: max, byID: make(map[string]Notification)}
}

// Create stores n.
func (m *MemoryRepository) Create(_ context.Context, n Notification) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, exists := m.byID[n.ID]; !exists {
		m.order = append(m.order, n.ID)
	}
	m.byID[n.ID] = n
	for len(m.order) > m.max {
		delete(m.byID, m.order[0])
		m.order = m.order[1:]
	}
	return nil
}

// Get returns the notification with the given ID.
func (m *MemoryRepository) Get(_ context.Context, id string) (Notification, bool, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	n, ok := m.byID[id]
	return n, ok, nil
}
