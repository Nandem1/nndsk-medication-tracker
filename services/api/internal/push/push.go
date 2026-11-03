package push

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v4"
	"golang.org/x/oauth2"
	"golang.org/x/oauth2/google"
)

type Outcome string

const (
	Accepted     Outcome = "accepted"
	Retry        Outcome = "retry"
	InvalidToken Outcome = "invalid_token"
	Rejected     Outcome = "rejected"
	Unknown      Outcome = "unknown"
)

type Message struct {
	ID, Platform, Token string
	ExpiresAt           time.Time
}

type Result struct {
	Outcome    Outcome
	RetryAfter time.Duration
}

type Sender interface {
	Send(context.Context, Message) Result
}

type transport struct {
	client *http.Client
	now    func() time.Time
	apns   *apnsConfig
	fcm    *fcmConfig
}

type apnsConfig struct {
	endpoint, topic, teamID, keyID string
	key                            *ecdsa.PrivateKey
	mu                             sync.Mutex
	token                          string
	issuedAt                       time.Time
}

type fcmConfig struct {
	endpoint string
	tokens   oauth2.TokenSource
}

const (
	notificationTitle = "Recordatorio"
	notificationBody  = "Hay novedades pendientes. Abre la app para revisarlas."
	requestTimeout    = 10 * time.Second
)

var projectPattern = regexp.MustCompile(`^[a-z][a-z0-9-]{4,61}[a-z0-9]$`)
var tokenPattern = regexp.MustCompile(`^[a-fA-F0-9]{32,512}$`)
var opaqueIDPattern = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,64}$`)

func NewFromEnv(ctx context.Context) (Sender, error) {
	client := &http.Client{Timeout: requestTimeout, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	sender := &transport{client: client, now: time.Now}
	keyPath := os.Getenv("PUSH_APNS_KEY_FILE")
	keyID := os.Getenv("PUSH_APNS_KEY_ID")
	teamID := os.Getenv("PUSH_APNS_TEAM_ID")
	topic := os.Getenv("PUSH_APNS_TOPIC")
	sandbox := os.Getenv("PUSH_APNS_SANDBOX")
	if keyPath != "" || keyID != "" || teamID != "" || topic != "" || sandbox != "" {
		if keyPath == "" || keyID == "" || teamID == "" || topic == "" || (sandbox != "" && sandbox != "true" && sandbox != "false") {
			return nil, errors.New("complete APNs key, team, topic and valid sandbox configuration required")
		}
		data, err := os.ReadFile(keyPath)
		if err != nil {
			return nil, errors.New("cannot read APNs signing key")
		}
		key, err := jwt.ParseECPrivateKeyFromPEM(data)
		if err != nil || key.Curve.Params().BitSize != 256 {
			return nil, errors.New("APNs requires an ES256 private key")
		}
		endpoint := "https://api.push.apple.com"
		if sandbox == "true" {
			endpoint = "https://api.sandbox.push.apple.com"
		}
		sender.apns = &apnsConfig{endpoint: endpoint, topic: topic, teamID: teamID, keyID: keyID, key: key}
	}
	if project := os.Getenv("PUSH_FCM_PROJECT_ID"); project != "" {
		if !projectPattern.MatchString(project) {
			return nil, errors.New("invalid FCM project identifier")
		}
		credentialContext := context.WithValue(ctx, oauth2.HTTPClient, client)
		credentials, err := google.FindDefaultCredentials(credentialContext, "https://www.googleapis.com/auth/firebase.messaging")
		if err != nil {
			return nil, errors.New("FCM application default credentials unavailable")
		}
		sender.fcm = &fcmConfig{endpoint: "https://fcm.googleapis.com/v1/projects/" + project + "/messages:send", tokens: credentials.TokenSource}
	}
	if sender.apns == nil && sender.fcm == nil {
		return nil, errors.New("configure at least one push provider")
	}
	return sender, nil
}

func (s *transport) Send(ctx context.Context, message Message) Result {
	if !opaqueIDPattern.MatchString(message.ID) || message.Token == "" || len(message.Token) > 4096 || !message.ExpiresAt.After(s.now()) {
		return Result{Outcome: Rejected}
	}
	ctx, cancel := context.WithTimeout(ctx, requestTimeout)
	defer cancel()
	switch message.Platform {
	case "ios", "apns":
		return s.sendAPNs(ctx, message)
	case "android", "fcm":
		return s.sendFCM(ctx, message)
	default:
		return Result{Outcome: Rejected}
	}
}

func (a *apnsConfig) bearer(now time.Time) (string, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.token != "" && !now.Before(a.issuedAt) && now.Sub(a.issuedAt) < 50*time.Minute {
		return a.token, nil
	}
	token := jwt.NewWithClaims(jwt.SigningMethodES256, jwt.MapClaims{"iss": a.teamID, "iat": now.Unix()})
	token.Header["kid"] = a.keyID
	signed, err := token.SignedString(a.key)
	if err != nil {
		return "", err
	}
	a.token, a.issuedAt = signed, now
	return signed, nil
}

func (s *transport) sendAPNs(ctx context.Context, message Message) Result {
	if s.apns == nil || !tokenPattern.MatchString(message.Token) {
		return Result{Outcome: Rejected}
	}
	bearer, err := s.apns.bearer(s.now())
	if err != nil {
		return Result{Outcome: Rejected}
	}
	payload := map[string]any{"aps": map[string]any{"alert": map[string]string{"title": notificationTitle, "body": notificationBody}}}
	req, err := jsonRequest(ctx, s.apns.endpoint+"/3/device/"+message.Token, payload)
	if err != nil {
		return Result{Outcome: Rejected}
	}
	req.Header.Set("authorization", "bearer "+bearer)
	req.Header.Set("apns-topic", s.apns.topic)
	req.Header.Set("apns-push-type", "alert")
	req.Header.Set("apns-priority", "5")
	req.Header.Set("apns-collapse-id", message.ID)
	req.Header.Set("apns-expiration", strconv.FormatInt(message.ExpiresAt.Unix(), 10))
	response, err := s.client.Do(req)
	if err != nil {
		return Result{Outcome: Unknown}
	}
	defer response.Body.Close()
	if response.StatusCode == http.StatusOK {
		return Result{Outcome: Accepted}
	}
	if response.StatusCode >= 500 && response.StatusCode <= 599 {
		result := retryResult(response, s.now())
		if result.RetryAfter < 15*time.Minute {
			result.RetryAfter = 15 * time.Minute
		}
		return result
	}
	if response.StatusCode == 429 {
		return retryResult(response, s.now())
	}
	var failure struct {
		Reason string `json:"reason"`
	}
	_ = json.NewDecoder(io.LimitReader(response.Body, 8192)).Decode(&failure)
	if (response.StatusCode == 410 && (failure.Reason == "Unregistered" || failure.Reason == "ExpiredToken")) || (response.StatusCode == 400 && failure.Reason == "BadDeviceToken") {
		return Result{Outcome: InvalidToken}
	}
	return Result{Outcome: Rejected}
}

func (s *transport) sendFCM(ctx context.Context, message Message) Result {
	if s.fcm == nil {
		return Result{Outcome: Rejected}
	}
	token, err := accessToken(ctx, s.fcm.tokens)
	if err != nil || token == nil || token.AccessToken == "" {
		return Result{Outcome: Retry, RetryAfter: time.Minute}
	}
	seconds := int64(message.ExpiresAt.Sub(s.now()).Seconds())
	if seconds < 1 {
		return Result{Outcome: Rejected}
	}
	if seconds > 2419200 {
		seconds = 2419200
	}
	payload := map[string]any{"message": map[string]any{
		"token":        message.Token,
		"notification": map[string]string{"title": notificationTitle, "body": notificationBody},
		"android":      map[string]any{"collapse_key": message.ID, "priority": "normal", "ttl": strconv.FormatInt(seconds, 10) + "s", "notification": map[string]string{"tag": message.ID}},
	}}
	req, err := jsonRequest(ctx, s.fcm.endpoint, payload)
	if err != nil {
		return Result{Outcome: Rejected}
	}
	req.Header.Set("Authorization", "Bearer "+token.AccessToken)
	response, err := s.client.Do(req)
	if err != nil {
		return Result{Outcome: Unknown}
	}
	defer response.Body.Close()
	if response.StatusCode == http.StatusOK {
		return Result{Outcome: Accepted}
	}
	if response.StatusCode == 429 || response.StatusCode == 500 || response.StatusCode == 503 {
		return retryResult(response, s.now())
	}
	var failure struct {
		Error struct {
			Details []struct {
				Type string `json:"@type"`
				Code string `json:"errorCode"`
			} `json:"details"`
		} `json:"error"`
	}
	_ = json.NewDecoder(io.LimitReader(response.Body, 8192)).Decode(&failure)
	if response.StatusCode == 404 {
		for _, detail := range failure.Error.Details {
			if detail.Type == "type.googleapis.com/google.firebase.fcm.v1.FcmError" && detail.Code == "UNREGISTERED" {
				return Result{Outcome: InvalidToken}
			}
		}
	}
	return Result{Outcome: Rejected}
}

func jsonRequest(ctx context.Context, endpoint string, payload any) (*http.Request, error) {
	data, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	// Replaying an ambiguous POST could display the alert again.
	request.GetBody = nil
	request.Header.Set("Content-Type", "application/json")
	return request, nil
}

func retryResult(response *http.Response, now time.Time) Result {
	delay := time.Minute
	raw := strings.TrimSpace(response.Header.Get("Retry-After"))
	if seconds, err := strconv.ParseInt(raw, 10, 32); err == nil && seconds > 0 {
		requested := time.Duration(seconds) * time.Second
		if requested > delay {
			delay = requested
		}
	} else if at, err := http.ParseTime(raw); err == nil && at.Sub(now) > delay {
		delay = at.Sub(now)
	}
	return Result{Outcome: Retry, RetryAfter: delay}
}

func accessToken(ctx context.Context, source oauth2.TokenSource) (*oauth2.Token, error) {
	type result struct {
		token *oauth2.Token
		err   error
	}
	done := make(chan result, 1)
	go func() { token, err := source.Token(); done <- result{token, err} }()
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case value := <-done:
		return value.token, value.err
	}
}
