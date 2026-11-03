package observability

import (
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestMetricsContainOnlyAggregateValues(t *testing.T) {
	var m Metrics
	m.Request(200, true, 10*time.Millisecond)
	m.Request(409, true, 20*time.Millisecond)
	m.Request(404, false, time.Millisecond)
	w := httptest.NewRecorder()
	m.Handler().ServeHTTP(w, httptest.NewRequest("GET", "/metrics", nil))
	body := w.Body.String()
	for _, want := range []string{"medication_http_requests_total 3", "medication_sync_success_total 1", "medication_sync_errors_total 1", "medication_http_duration_microseconds_sum 31000"} {
		if !strings.Contains(body, want) {
			t.Fatal(body)
		}
	}
	if strings.ContainsAny(body, "{}") || strings.Contains(body, "patient") || strings.Contains(body, "token") {
		t.Fatal("metrics contain labels or sensitive fields", body)
	}
}
