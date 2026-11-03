package httpapi

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"medication-tracker/services/api/internal/auth"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type testVerifier map[string]string

func (v testVerifier) Verify(_ context.Context, token string) (string, error) {
	if uid := v[token]; uid != "" {
		return uid, nil
	}
	return "", errors.New("invalid test token")
}
func TestHTTPBoundary(t *testing.T) {
	var logs bytes.Buffer
	handler := NewAPI(func(context.Context) error { return nil }, nil, testVerifier{}, slog.New(slog.NewJSONHandler(&logs, nil)))
	for _, path := range []string{"/v1/me", "/v1/patients/medical-secret/doses?token=hidden"} {
		r := httptest.NewRequest("GET", path, nil)
		r.Header.Set("Authorization", "Bearer secret-token")
		r.Header.Set("X-User-ID", "forged")
		r.Header.Set("X-Request-ID", "medical-secret")
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		if w.Code != 401 || w.Header().Get("X-Request-ID") == "medical-secret" {
			t.Fatal(w.Code, w.Body.String())
		}
	}
	if strings.Contains(logs.String(), "medical-secret") || strings.Contains(logs.String(), "secret-token") || strings.Contains(logs.String(), "hidden") {
		t.Fatal("PII in logs")
	}
	for i := 0; i < 120; i++ {
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, httptest.NewRequest("GET", "/v1/me", nil))
		if i >= 118 && w.Code != 429 {
			t.Fatal("rate limit not enforced", i, w.Code)
		}
	}
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, httptest.NewRequest("GET", "/healthz", nil))
	if w.Code != 200 {
		t.Fatal("probe rate limited")
	}
}
func TestStrictJSON(t *testing.T) {
	for _, tc := range []struct {
		body string
		want int
	}{{`{"actor_id":"forged"}`, 400}, {`null`, 400}, {`[]`, 400}, {`{} {}`, 400}, {strings.Repeat("x", 65537), 413}, {`{"quantity":"0.500","client_operation_id":"x"}`, 200}} {
		w := httptest.NewRecorder()
		r := httptest.NewRequest("POST", "/", strings.NewReader(tc.body))
		r.Header.Set("Content-Type", "application/json")
		var request ReplenishRequest
		if decode(w, r, &request) {
			w.WriteHeader(200)
		}
		if w.Code != tc.want {
			t.Fatal(w.Code, tc.want)
		}
	}
}
func TestLimiterBoundedAndExpiry(t *testing.T) {
	l := &limiter{windows: map[string]rateWindow{}}
	now := time.Now()
	for i := 0; i < 1024; i++ {
		if !l.allow(string(rune(i)), now) {
			t.Fatal(i)
		}
	}
	if l.allow("overflow", now) {
		t.Fatal("unbounded map")
	}
	if !l.allow("overflow", now.Add(time.Minute)) {
		t.Fatal("expired windows retained")
	}
	if len(l.windows) != 1 {
		t.Fatal(len(l.windows))
	}
}
func TestRequestDeadline(t *testing.T) {
	a := &API{}
	h := a.middleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		deadline, ok := r.Context().Deadline()
		if !ok || time.Until(deadline) > 8*time.Second {
			t.Fatal("deadline absent")
		}
		w.WriteHeader(204)
	}))
	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest("GET", "/", nil))
}

func TestHTTPRejectsInvalidFirebaseToken(t *testing.T) {
	credentials := filepath.Join(t.TempDir(), "synthetic-adc.json")
	if err := os.WriteFile(credentials, []byte(`{"type":"authorized_user","client_id":"synthetic","client_secret":"synthetic","refresh_token":"synthetic"}`), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GOOGLE_APPLICATION_CREDENTIALS", credentials)
	t.Setenv("FIREBASE_AUTH_EMULATOR_HOST", "")
	verifier, err := auth.NewFirebase(context.Background(), "demo-medication-test")
	if err != nil {
		t.Fatal(err)
	}
	handler := NewAPI(func(context.Context) error { return nil }, nil, verifier, nil)
	req := httptest.NewRequest("GET", "/v1/me", nil)
	req.Header.Set("Authorization", "Bearer malformed-token")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, req)
	if response.Code != 401 {
		t.Fatal(response.Code)
	}
}
