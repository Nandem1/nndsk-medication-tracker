package auth

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"google.golang.org/api/option"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v4"
)

func TestFirebaseSignedTokenVerification(t *testing.T) {
	t.Setenv("FIREBASE_AUTH_EMULATOR_HOST", "")
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	cert := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "Synthetic test"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature}
	der, err := x509.CreateCertificate(rand.Reader, cert, cert, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	certificates, _ := json.Marshal(map[string]string{"test-key": string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))})
	var accountState atomic.Int32
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/accounts:lookup") {
			switch accountState.Load() {
			case 1:
				_, _ = w.Write([]byte(`{"users":[{"localId":"synthetic-patient","disabled":true}]}`))
			case 2:
				_ = json.NewEncoder(w).Encode(map[string]any{"users": []any{map[string]any{"localId": "synthetic-patient", "validSince": strconv.FormatInt(time.Now().Unix(), 10)}}})
			case 3:
				_, _ = w.Write([]byte(`{"users":[]}`))
			case 4:
				w.WriteHeader(http.StatusServiceUnavailable)
			default:
				_, _ = w.Write([]byte(`{"users":[{"localId":"synthetic-patient","validSince":"0"}]}`))
			}
			return
		}
		w.Header().Set("Cache-Control", "max-age=3600")
		_, _ = w.Write(certificates)
	}))
	defer server.Close()
	roots := x509.NewCertPool()
	roots.AddCert(server.Certificate())
	transport := &http.Transport{TLSClientConfig: &tls.Config{RootCAs: roots, ServerName: "127.0.0.1"}, DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, strings.TrimPrefix(server.URL, "https://"))
	}}
	previous := http.DefaultTransport
	http.DefaultTransport = transport
	t.Cleanup(func() { http.DefaultTransport = previous; transport.CloseIdleConnections() })
	verifier, err := newFirebase(context.Background(), "demo-medication-test", option.WithoutAuthentication())
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().Unix()
	claims := func() jwt.MapClaims {
		return jwt.MapClaims{"iss": "https://securetoken.google.com/demo-medication-test", "aud": "demo-medication-test", "sub": "synthetic-patient", "iat": now - 10, "exp": now + 3600, "auth_time": now - 10}
	}
	sign := func(c jwt.MapClaims, k *rsa.PrivateKey) string {
		t.Helper()
		token := jwt.NewWithClaims(jwt.SigningMethodRS256, c)
		token.Header["kid"] = "test-key"
		raw, e := token.SignedString(k)
		if e != nil {
			t.Fatal(e)
		}
		return raw
	}
	if uid, e := verifier.Verify(context.Background(), sign(claims(), key)); e != nil || uid != "synthetic-patient" {
		_, cause := verifier.client.VerifyIDToken(context.Background(), sign(claims(), key))
		t.Fatal(uid, e, cause)
	}
	for _, state := range []int32{1, 2, 3, 4} {
		accountState.Store(state)
		if _, e := verifier.Verify(context.Background(), sign(claims(), key)); e == nil {
			t.Fatalf("accepted disabled, revoked, deleted or unavailable account state %d", state)
		}
	}
	accountState.Store(0)

	for _, field := range []string{"aud", "iss", "sub", "exp", "iat"} {
		t.Run(field, func(t *testing.T) {
			c := claims()
			switch field {
			case "exp":
				c[field] = now - 3600
			case "iat":
				c[field] = now + 3600
			case "sub":
				c[field] = ""
			default:
				c[field] = "wrong"
			}
			if _, e := verifier.Verify(context.Background(), sign(c, key)); e == nil {
				t.Fatal("accepted invalid claim")
			}
		})
	}
	other, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	if _, e := verifier.Verify(context.Background(), sign(claims(), other)); e == nil {
		t.Fatal("accepted invalid signature")
	}
	unsigned := jwt.NewWithClaims(jwt.SigningMethodNone, claims())
	raw, _ := unsigned.SignedString(jwt.UnsafeAllowNoneSignatureType)
	if _, e := verifier.Verify(context.Background(), raw); e == nil {
		t.Fatal("accepted unsigned token")
	}
}
func TestFirebaseRejectsEmulatorAndMissingProject(t *testing.T) {
	t.Setenv("FIREBASE_AUTH_EMULATOR_HOST", "")
	if _, err := NewFirebase(context.Background(), ""); err == nil {
		t.Fatal("missing project accepted")
	}
	t.Setenv("FIREBASE_AUTH_EMULATOR_HOST", "127.0.0.1:9099")
	if _, err := NewFirebase(context.Background(), "demo-medication-test"); err == nil {
		t.Fatal("emulator accepted")
	}
}

func TestCredentialOptions(t *testing.T) {
	if options, err := credentialOptions("  "); err != nil || options != nil {
		t.Fatal("sin variable se usan las credenciales por defecto", err)
	}
	if _, err := credentialOptions("{sin-json"); err == nil || strings.Contains(err.Error(), "sin-json") {
		t.Fatal("una credencial inválida se rechaza sin repetir su contenido", err)
	}
	if options, err := credentialOptions(`{"type":"service_account"}`); err != nil || len(options) != 1 {
		t.Fatal(err)
	}
}

