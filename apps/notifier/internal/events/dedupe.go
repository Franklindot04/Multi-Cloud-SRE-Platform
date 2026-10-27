package events

import (
	"container/list"
	"sync"
)

// Dedupe remembers the IDs of the most recent events so a redelivered message is acknowledged without
// being handled twice. It is bounded: the oldest IDs are forgotten first.
//
// This is in memory on purpose. The notifier only records notifications and has no database, so a
// restart forgets the set and a redelivered event is recorded again under the same notification ID
// (the event ID), which overwrites rather than duplicates. Once real delivery (email, SMS) exists, this
// must become a durable store such as a unique constraint in PostgreSQL.
type Dedupe struct {
	mu    sync.Mutex
	max   int
	order *list.List
	items map[string]*list.Element
}

// NewDedupe creates a set that remembers at most max IDs.
func NewDedupe(max int) *Dedupe {
	return &Dedupe{max: max, order: list.New(), items: make(map[string]*list.Element)}
}

// Begin claims id. It returns false if the event was already handled or is being handled right now; an
// event that is still being handled needs no second copy, because if that attempt fails its own retry follows.
func (d *Dedupe) Begin(id string) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	if _, seen := d.items[id]; seen {
		return false
	}
	d.items[id] = d.order.PushFront(id)
	for d.order.Len() > d.max {
		oldest := d.order.Back()
		d.order.Remove(oldest)
		delete(d.items, oldest.Value.(string))
	}
	return true
}

// Abandon releases the claim after a failure, so a retry of the same event can handle it again.
func (d *Dedupe) Abandon(id string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if el, ok := d.items[id]; ok {
		d.order.Remove(el)
		delete(d.items, id)
	}
}
