package platform

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

// Run serves h until SIGTERM or SIGINT. On a signal it first marks the process as draining so
// /readyz fails and load balancers stop sending traffic, waits for the drain period, then stops
// accepting connections and gives in-flight requests up to shutdownTimeout to finish.
func Run(addr string, h http.Handler, drain *Drain, drainPeriod, shutdownTimeout time.Duration, log *slog.Logger) error {
	srv := &http.Server{
		Addr:              addr,
		Handler:           h,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	errCh := make(chan error, 1)
	go func() {
		log.Info("listening", "addr", addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
		close(errCh)
	}()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	select {
	case err := <-errCh:
		return err
	case s := <-sig:
		log.Info("shutdown requested", "signal", s.String(), "drain_seconds", drainPeriod.Seconds())
	}

	drain.Start()
	time.Sleep(drainPeriod)

	ctx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil {
		return err
	}
	log.Info("stopped")
	return nil
}
