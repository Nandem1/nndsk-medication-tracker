package config

import (
	"crypto/tls"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestPoolConfigTrustAndHostname(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	defer server.Close()
	cert := string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.Certificate().Raw}))
	cfg, err := PoolConfig(Config{DatabaseURL: "postgres://synthetic@127.0.0.1/test?sslmode=verify-full", DatabaseCAPEM: cert})
	if err != nil {
		t.Fatal(err)
	}
	if cfg.ConnConfig.ConnectTimeout != 2*time.Second {
		t.Fatal("missing connection deadline")
	}
	conn, err := tls.Dial("tcp", server.Listener.Addr().String(), cfg.ConnConfig.TLSConfig)
	if err != nil {
		t.Fatal("trusted server rejected", err)
	}
	conn.Close()
	wrong := cfg.ConnConfig.TLSConfig.Clone()
	wrong.ServerName = "wrong.invalid"
	if conn, err = tls.Dial("tcp", server.Listener.Addr().String(), wrong); err == nil {
		conn.Close()
		t.Fatal("wrong hostname accepted")
	}
	defaultCfg, err := PoolConfig(Config{DatabaseURL: "postgres://synthetic@127.0.0.1/test?sslmode=verify-full"})
	if err != nil {
		t.Fatal(err)
	}
	if conn, err = tls.Dial("tcp", server.Listener.Addr().String(), defaultCfg.ConnConfig.TLSConfig); err == nil {
		conn.Close()
		t.Fatal("untrusted certificate accepted")
	}
	for _, mode := range []string{"disable", "allow", "prefer", "require", "verify-ca"} {
		if _, err := PoolConfig(Config{DatabaseURL: "postgres://synthetic@127.0.0.1/test?sslmode=" + mode, DatabaseCAPEM: cert}); err == nil {
			t.Fatalf("accepted insecure mode %s", mode)
		}
	}
	if _, err := PoolConfig(Config{DatabaseURL: "postgres://synthetic@localhost/test?sslmode=verify-full", DatabaseCAPEM: "invalid"}); err == nil {
		t.Fatal("invalid CA accepted")
	}
}
