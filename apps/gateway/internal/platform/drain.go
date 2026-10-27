package platform

import "sync/atomic"

// Drain records that the process has been asked to stop, so /readyz can start failing
// before the listener closes.
type Drain struct{ draining atomic.Bool }

// Start marks the process as draining.
func (d *Drain) Start() { d.draining.Store(true) }

// Draining reports whether Start was called.
func (d *Drain) Draining() bool { return d.draining.Load() }
