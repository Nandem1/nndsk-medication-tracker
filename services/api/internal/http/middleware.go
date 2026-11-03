package httpapi

import (
	"context"
	"medication-tracker/services/api/internal/observability"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"medication-tracker/services/api/internal/domain"
)

type rateWindow struct {
	starts time.Time
	count  int
}
type limiter struct {
	mu      sync.Mutex
	windows map[string]rateWindow
}

func (l *limiter) allow(key string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	window, exists := l.windows[key]
	if !exists || now.Sub(window.starts) >= time.Minute {
		if len(l.windows) >= 1024 {
			for k, v := range l.windows {
				if now.Sub(v.starts) >= time.Minute {
					delete(l.windows, k)
				}
			}
			if len(l.windows) >= 1024 && !exists {
				return false
			}
		}
		window = rateWindow{starts: now}
	}
	if window.count >= 120 {
		return false
	}
	window.count++
	l.windows[key] = window
	return true
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(code int) {
	if w.status == 0 {
		w.status = code
		w.ResponseWriter.WriteHeader(code)
	}
}
func (w *statusWriter) Write(data []byte) (int, error) {
	if w.status == 0 {
		w.WriteHeader(200)
	}
	return w.ResponseWriter.Write(data)
}
func (a *API) middleware(next http.Handler) http.Handler {
	limits := &limiter{windows: map[string]rateWindow{}}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := domain.NewID()
		ctx, cancel := context.WithTimeout(context.WithValue(r.Context(), requestKey, id), 8*time.Second)
		defer cancel()
		r = r.WithContext(ctx)
		w.Header().Set("X-Request-ID", id)
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		sw := &statusWriter{ResponseWriter: w}
		start := time.Now()
		defer func() {
			if recover() != nil {
				fail(sw, r, 500, "internal_error", "Request could not be completed")
			}
			status := sw.status
			if status == 0 {
				status = 200
			}
			observability.Default.Request(status, r.Method == "POST" && (strings.HasSuffix(r.URL.Path, "/events") || strings.HasSuffix(r.URL.Path, "/corrections")), time.Since(start))
			if a.logger != nil {
				a.logger.Info("http request", "request_id", id, "method", r.Method, "status", sw.status, "duration_ms", time.Since(start).Milliseconds())
			}
		}()
		if r.URL.Path != "/healthz" && r.URL.Path != "/readyz" {
			host, _, err := net.SplitHostPort(r.RemoteAddr)
			if err != nil {
				host = r.RemoteAddr
			}
			if !limits.allow(host, start) {
				sw.Header().Set("Retry-After", "60")
				fail(sw, r, 429, "rate_limited", "Request limit exceeded")
				return
			}
		}
		next.ServeHTTP(sw, r)
	})
}
