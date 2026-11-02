package httpapi

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestHealthAndReadiness(t *testing.T) {
	for _, tc := range []struct {
		name, path string
		pingErr    error
		wantCode   int
		wantBody   string
		wantPing   bool
	}{
		{"health independent of database", "/healthz", errors.New("offline"), 200, "{\"status\":\"ok\"}\n", false},
		{"ready", "/readyz", nil, 200, "{\"status\":\"ready\"}\n", true},
		{"database unavailable", "/readyz", errors.New("secret connection details"), 503, "{\"status\":\"not_ready\"}\n", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			called := false
			h := NewHandler(func(ctx context.Context) error {
				called = true
				deadline, ok := ctx.Deadline()
				if !ok || time.Until(deadline) > 2*time.Second {
					t.Error("readiness must bound database check to two seconds")
				}
				return tc.pingErr
			})
			w := httptest.NewRecorder()
			h.ServeHTTP(w, httptest.NewRequest(http.MethodGet, tc.path, nil))
			if w.Code != tc.wantCode || w.Body.String() != tc.wantBody {
				t.Fatalf("got %d %q, want %d %q", w.Code, w.Body.String(), tc.wantCode, tc.wantBody)
			}
			if called != tc.wantPing {
				t.Errorf("ping called=%v", called)
			}
			if w.Header().Get("Content-Type") != "application/json" {
				t.Error("missing JSON content type")
			}
		})
	}
}

func TestRouting(t *testing.T) {
	h := NewHandler(func(context.Context) error { t.Fatal("unexpected database access"); return nil })
	for _, tc := range []struct {
		method, path string
		code         int
	}{{"POST", "/healthz", 405}, {"GET", "/unknown", 404}, {"GET", "/healthz/extra", 404}} {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest(tc.method, tc.path, nil))
		if w.Code != tc.code {
			t.Errorf("%s %s: got %d", tc.method, tc.path, w.Code)
		}
	}
}

func TestReadinessHonorsCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	h := NewHandler(func(ctx context.Context) error { return ctx.Err() })
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("GET", "/readyz", nil).WithContext(ctx))
	if w.Code != 503 {
		t.Fatalf("got %d", w.Code)
	}
}
