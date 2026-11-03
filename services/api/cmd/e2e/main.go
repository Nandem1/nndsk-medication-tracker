//go:build e2e

package main

import (
	"context"
	"errors"
	"github.com/jackc/pgx/v5/pgxpool"
	"log"
	"medication-tracker/services/api/internal/application"
	httpapi "medication-tracker/services/api/internal/http"
	"net/http"
	"os"
	"strings"
	"time"
)

type verifier struct{}

func (verifier) Verify(_ context.Context, token string) (string, error) {
	if strings.HasPrefix(token, "synthetic-") && len(token) < 128 {
		return token, nil
	}
	return "", errors.New("invalid test identity")
}
func main() {
	cfg, err := pgxpool.ParseConfig(os.Getenv("TEST_DATABASE_URL"))
	if err != nil {
		log.Fatal("invalid test database configuration")
	}
	if !strings.HasPrefix(cfg.ConnConfig.Database, "medication_f3_") || (cfg.ConnConfig.Host != "127.0.0.1" && cfg.ConnConfig.Host != "/private/tmp") {
		log.Fatal("e2e requires a disposable local medication_f3_ database")
	}
	pool, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		log.Fatal("test database unavailable")
	}
	defer pool.Close()
	server := &http.Server{Addr: "127.0.0.1:18083", Handler: httpapi.NewAPI(pool.Ping, application.New(pool, nil), verifier{}, nil), ReadHeaderTimeout: 5 * time.Second}
	log.Fatal(server.ListenAndServe())
}
