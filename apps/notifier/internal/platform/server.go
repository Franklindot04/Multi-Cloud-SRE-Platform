package platform

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"
)

// Worker is a background task that runs beside the HTTP server, such as a message consumer. Run must
// return once ctx is cancelled, after finishing the work it has in flight.
type Worker interface {
	Run(ctx context.Context) error
}

// Run serves h until SIGTERM or SIGINT. On a signal it first marks the process as draining so
// /readyz fails and load balancers stop sending traffic, waits for the drain period, then stops
// accepting connections and gives in-flight requests up to shutdownTimeout to finish.
//
// Workers start with the server. They are stopped after the drain period, at the same time as the HTTP
// server, and get the shutdown timeout to finish what they are doing.
func Run(addr string, h http.Handler, drain *Drain, drainPeriod, shutdownTimeout time.Duration, log *slog.Logger, workers ...Worker) error {
	srv := &http.Server{
		Addr:              addr,
		Handler:           h,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	workerCtx, stopWorkers := context.WithCancel(context.Background())
	defer stopWorkers()
	workersDone := make(chan struct{})
	var running sync.WaitGroup
	for _, w := range workers {
		running.Add(1)
		go func() {
			defer running.Done()
			if err := w.Run(workerCtx); err != nil {
				log.Error("worker stopped with an error", "error", err.Error())
			}
		}()
	}
	go func() {
		running.Wait()
		close(workersDone)
	}()

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
	stopWorkers()
	if err := srv.Shutdown(ctx); err != nil {
		return err
	}
	select {
	case <-workersDone:
	case <-ctx.Done():
		log.Warn("workers did not finish before the shutdown timeout")
	}
	log.Info("stopped")
	return nil
}
