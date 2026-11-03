package push

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v4"
	"golang.org/x/oauth2"
)

func testKey(t *testing.T) *ecdsa.PrivateKey {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return key
}
func testMessage(platform string) Message {
	token := strings.Repeat("ab", 32)
	if platform == "android" {
		token = "synthetic-fcm-token"
	}
	return Message{ID: "00000000-0000-4000-8000-000000000001", Platform: platform, Token: token, ExpiresAt: time.Now().Add(time.Hour)}
}
func testTransport(t *testing.T, server *httptest.Server) *transport {
	return &transport{client: server.Client(), now: time.Now, apns: &apnsConfig{endpoint: server.URL, topic: "cl.example.synthetic", teamID: "synthetic-team", keyID: "synthetic-key", key: testKey(t)}, fcm: &fcmConfig{endpoint: server.URL, tokens: oauth2.StaticTokenSource(&oauth2.Token{AccessToken: "synthetic-access-token"})}}
}
func TestAPNsHTTP2PayloadAndHeaders(t *testing.T) {
	key := testKey(t)
	message := testMessage("ios")
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.ProtoMajor != 2 || r.Method != http.MethodPost || r.URL.Path != "/3/device/"+message.Token {
			t.Error("incorrect protocol or route")
		}
		for name, want := range map[string]string{"Apns-Topic": "cl.example.synthetic", "Apns-Push-Type": "alert", "Apns-Priority": "5", "Apns-Collapse-Id": message.ID} {
			if r.Header.Get(name) != want {
				t.Errorf("header %s mismatch", name)
			}
		}
		token, err := jwt.Parse(strings.TrimPrefix(r.Header.Get("Authorization"), "bearer "), func(token *jwt.Token) (any, error) { return &key.PublicKey, nil }, jwt.WithValidMethods([]string{"ES256"}))
		if err != nil || !token.Valid || token.Header["kid"] != "synthetic-key" {
			t.Error("invalid provider JWT")
		}
		body, _ := io.ReadAll(r.Body)
		var payload map[string]any
		if json.Unmarshal(body, &payload) != nil || len(payload) != 1 || payload["aps"] == nil {
			t.Error("unexpected payload fields")
		}
		if strings.Contains(string(body), message.ID) || strings.Contains(string(body), message.Token) || !strings.Contains(string(body), notificationBody) {
			t.Error("incorrect private payload")
		}
		w.WriteHeader(200)
	}))
	server.EnableHTTP2 = true
	server.StartTLS()
	defer server.Close()
	s := testTransport(t, server)
	s.apns.key = key
	if got := s.Send(context.Background(), message); got.Outcome != Accepted {
		t.Fatal(got)
	}
}
func TestFCMPayloadAndHeaders(t *testing.T) {
	message := testMessage("android")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.Header.Get("Authorization") != "Bearer synthetic-access-token" {
			t.Error("invalid FCM request")
		}
		var payload struct {
			Message struct {
				Token        string            `json:"token"`
				Notification map[string]string `json:"notification"`
				Android      struct {
					CollapseKey  string            `json:"collapse_key"`
					Notification map[string]string `json:"notification"`
					TTL          string            `json:"ttl"`
				} `json:"android"`
				Data map[string]string `json:"data"`
			} `json:"message"`
		}
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Error(err)
		}
		if payload.Message.Token != message.Token || payload.Message.Android.CollapseKey != message.ID || payload.Message.Android.Notification["tag"] != message.ID || payload.Message.Notification["body"] != notificationBody || len(payload.Message.Data) != 0 {
			t.Error("incorrect private payload")
		}
		w.WriteHeader(200)
	}))
	defer server.Close()
	if got := testTransport(t, server).Send(context.Background(), message); got.Outcome != Accepted {
		t.Fatal(got)
	}
}
func TestProviderOutcomesNeverRetryInsideSend(t *testing.T) {
	cases := []struct {
		name, platform   string
		status           int
		body, retryAfter string
		outcome          Outcome
		delay            time.Duration
	}{
		{"apns-invalid", "ios", 400, `{"reason":"BadDeviceToken"}`, "", InvalidToken, 0},
		{"apns-expired", "ios", 410, `{"reason":"Unregistered"}`, "", InvalidToken, 0},
		{"apns-auth", "ios", 403, `{"reason":"ExpiredProviderToken"}`, "", Rejected, 0},
		{"apns-throttled", "ios", 429, `{}`, "120", Retry, 2 * time.Minute},
		{"apns-down", "ios", 503, `{}`, "", Retry, 15 * time.Minute},
		{"apns-redirect", "ios", 307, `{}`, "", Rejected, 0},
		{"fcm-invalid-argument", "android", 400, `{"error":{"status":"INVALID_ARGUMENT"}}`, "", Rejected, 0},
		{"fcm-generic-not-found", "android", 404, `{"error":{"status":"NOT_FOUND"}}`, "", Rejected, 0},
		{"fcm-unregistered", "android", 404, `{"error":{"details":[{"@type":"type.googleapis.com/google.firebase.fcm.v1.FcmError","errorCode":"UNREGISTERED"}]}}`, "", InvalidToken, 0},
		{"fcm-throttled", "android", 429, `{}`, "1", Retry, time.Minute},
		{"fcm-down", "android", 500, `{}`, "", Retry, time.Minute},
		{"fcm-auth", "android", 401, `{}`, "", Rejected, 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			calls := atomic.Int32{}
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				w.Header().Set("Retry-After", tc.retryAfter)
				w.WriteHeader(tc.status)
				_, _ = io.WriteString(w, tc.body)
			}))
			defer server.Close()
			got := testTransport(t, server).Send(context.Background(), testMessage(tc.platform))
			if got.Outcome != tc.outcome || got.RetryAfter != tc.delay || calls.Load() != 1 {
				t.Fatalf("got %+v, calls %d", got, calls.Load())
			}
		})
	}
}
func TestAmbiguousDisconnectIsUnknownWithoutReplay(t *testing.T) {
	for _, platform := range []string{"ios", "android"} {
		t.Run(platform, func(t *testing.T) {
			calls := atomic.Int32{}
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				_, _ = io.Copy(io.Discard, r.Body)
				conn, _, err := w.(http.Hijacker).Hijack()
				if err != nil {
					t.Error(err)
					return
				}
				_ = conn.Close()
			}))
			defer server.Close()
			if got := testTransport(t, server).Send(context.Background(), testMessage(platform)); got.Outcome != Unknown {
				t.Fatal(got)
			}
			if calls.Load() != 1 {
				t.Fatal("ambiguous request replayed")
			}
		})
	}
}
func TestAPNsProviderTokenRefresh(t *testing.T) {
	config := &apnsConfig{key: testKey(t), keyID: "synthetic", teamID: "synthetic"}
	now := time.Now()
	first, err := config.bearer(now)
	if err != nil {
		t.Fatal(err)
	}
	reused, err := config.bearer(now.Add(49 * time.Minute))
	if err != nil || reused != first {
		t.Fatal("token unnecessarily regenerated")
	}
	refreshed, err := config.bearer(now.Add(50 * time.Minute))
	if err != nil || refreshed == first {
		t.Fatal("token did not refresh")
	}
	parsed, _, err := new(jwt.Parser).ParseUnverified(refreshed, jwt.MapClaims{})
	if err != nil || parsed.Claims.(jwt.MapClaims)["iat"] != float64(now.Add(50*time.Minute).Unix()) {
		t.Fatal("wrong refreshed issue time")
	}
}
func TestRetryAfterHTTPDate(t *testing.T) {
	now := time.Date(2026, 11, 3, 12, 0, 0, 0, time.UTC)
	response := &http.Response{Header: http.Header{"Retry-After": []string{now.Add(3 * time.Minute).Format(http.TimeFormat)}}}
	if got := retryResult(response, now); got.RetryAfter != 3*time.Minute {
		t.Fatal(got)
	}
}
func TestConfigurationAndPreflight(t *testing.T) {
	for _, name := range []string{"PUSH_APNS_KEY_FILE", "PUSH_APNS_KEY_ID", "PUSH_APNS_TEAM_ID", "PUSH_APNS_TOPIC", "PUSH_APNS_SANDBOX", "PUSH_FCM_PROJECT_ID"} {
		t.Setenv(name, "")
	}
	if _, err := NewFromEnv(context.Background()); err == nil {
		t.Fatal("unconfigured providers accepted")
	}
	t.Setenv("PUSH_FCM_PROJECT_ID", "not/a/project")
	if _, err := NewFromEnv(context.Background()); err == nil {
		t.Fatal("invalid project accepted")
	}
	t.Setenv("PUSH_FCM_PROJECT_ID", "")
	t.Setenv("PUSH_APNS_KEY_ID", "synthetic")
	if _, err := NewFromEnv(context.Background()); err == nil {
		t.Fatal("partial APNs config accepted")
	}
	data, err := x509.MarshalPKCS8PrivateKey(testKey(t))
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "synthetic.p8")
	if err = os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: data}), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PUSH_APNS_KEY_FILE", path)
	t.Setenv("PUSH_APNS_TEAM_ID", "synthetic")
	t.Setenv("PUSH_APNS_TOPIC", "cl.example.synthetic")
	t.Setenv("PUSH_APNS_SANDBOX", "true")
	sender, err := NewFromEnv(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if sender.(*transport).apns.endpoint != "https://api.sandbox.push.apple.com" {
		t.Fatal("sandbox not selected")
	}
	if got := sender.Send(context.Background(), testMessage("android")); got.Outcome != Rejected {
		t.Fatal(got)
	}
	expired := testMessage("ios")
	expired.ExpiresAt = time.Now().Add(-time.Second)
	if got := sender.Send(context.Background(), expired); got.Outcome != Rejected {
		t.Fatal(got)
	}
	invalid := testMessage("ios")
	invalid.Token = "../../path"
	if got := sender.Send(context.Background(), invalid); got.Outcome != Rejected {
		t.Fatal(got)
	}
}

type waitingTokenSource struct{ release <-chan struct{} }

func (s waitingTokenSource) Token() (*oauth2.Token, error) {
	<-s.release
	return &oauth2.Token{AccessToken: "synthetic"}, nil
}
func TestTokenAcquisitionHonorsCancellation(t *testing.T) {
	release := make(chan struct{})
	defer close(release)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := accessToken(ctx, waitingTokenSource{release})
	if err != context.Canceled {
		t.Fatal("token acquisition ignored cancellation", err)
	}
}
