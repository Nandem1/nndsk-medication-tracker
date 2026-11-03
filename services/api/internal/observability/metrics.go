package observability

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"sync/atomic"
	"time"
)

type Metrics struct {
	Requests, RequestErrors, LatencyMicroseconds, SyncSuccess, SyncErrors                                           atomic.Uint64
	WorkerCycles, WorkerErrors, PushSent, PushRetry, PushUncertain, PushFailed, PushDeferred, PushDelayMilliseconds atomic.Uint64
}

var Default Metrics

func (m *Metrics) Request(status int, sync bool, elapsed time.Duration) {
	m.Requests.Add(1)
	m.LatencyMicroseconds.Add(uint64(max(elapsed.Microseconds(), 0)))
	if status >= 400 {
		m.RequestErrors.Add(1)
	}
	if sync {
		if status >= 200 && status < 300 {
			m.SyncSuccess.Add(1)
		} else {
			m.SyncErrors.Add(1)
		}
	}
}
func (m *Metrics) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /metrics", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4")
		w.Header().Set("Cache-Control", "no-store")
		values := []struct {
			name  string
			value uint64
		}{{"http_requests_total", m.Requests.Load()}, {"http_errors_total", m.RequestErrors.Load()}, {"http_duration_microseconds_sum", m.LatencyMicroseconds.Load()}, {"sync_success_total", m.SyncSuccess.Load()}, {"sync_errors_total", m.SyncErrors.Load()}, {"worker_cycles_total", m.WorkerCycles.Load()}, {"worker_errors_total", m.WorkerErrors.Load()}, {"push_sent_total", m.PushSent.Load()}, {"push_retry_total", m.PushRetry.Load()}, {"push_uncertain_total", m.PushUncertain.Load()}, {"push_failed_total", m.PushFailed.Load()}, {"push_deferred_or_suppressed_total", m.PushDeferred.Load()}, {"push_delay_milliseconds_sum", m.PushDelayMilliseconds.Load()}}
		for _, v := range values {
			fmt.Fprintf(w, "# TYPE medication_%s counter\nmedication_%s %d\n", v.name, v.name, v.value)
		}
	})
	return mux
}
func (m *Metrics) Serve(ctx context.Context, addr string) error {
	server := &http.Server{Addr: addr, Handler: m.Handler(), ReadHeaderTimeout: 3 * time.Second, ReadTimeout: 5 * time.Second, WriteTimeout: 5 * time.Second, IdleTimeout: 30 * time.Second}
	done := make(chan error, 1)
	go func() { done <- server.ListenAndServe() }()
	select {
	case err := <-done:
		return err
	case <-ctx.Done():
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdown); err != nil {
			_ = server.Close()
			return errors.New("metrics shutdown failed")
		}
		err := <-done
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return errors.New("metrics server failed")
	}
}
