//go:build integration

package httpapi

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func TestReadinessWithPostgres(t *testing.T) {
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Fatal("TEST_DATABASE_URL must identify a dedicated test database")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	if err := pool.Ping(ctx); err != nil {
		t.Fatalf("real PostgreSQL unavailable: %v", err)
	}
	server := httptest.NewServer(NewHandler(pool.Ping))
	defer server.Close()
	client := &http.Client{Timeout: 5 * time.Second}
	check := func(path string, want int) {
		t.Helper()
		resp, err := client.Get(server.URL + path)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		if resp.StatusCode != want {
			t.Fatalf("%s: got %d want %d", path, resp.StatusCode, want)
		}
	}
	check("/healthz", 200)
	check("/readyz", 200)
	pool.Close()
	check("/readyz", 503)
	check("/healthz", 200)
}
