//go:build e2e

package main

import (
	"context"
	"errors"
	firebase "firebase.google.com/go/v4"
	firebaseauth "firebase.google.com/go/v4/auth"
	"github.com/jackc/pgx/v5/pgxpool"
	"google.golang.org/api/option"
	"log"
	"medication-tracker/services/api/internal/application"
	httpapi "medication-tracker/services/api/internal/http"
	"net/http"
	"os"
	"strings"
	"time"
)

type verifier struct{ emulator *firebaseauth.Client }

func (v verifier) Verify(ctx context.Context, token string) (string, error) {
	if strings.HasPrefix(token, "synthetic-") && len(token) < 128 {
		return token, nil
	}
	if v.emulator != nil {
		decoded, err := v.emulator.VerifyIDToken(ctx, token)
		if err != nil {
			return "", errors.New("invalid emulator identity")
		}
		return decoded.UID, nil
	}
	return "", errors.New("invalid test identity")
}

// El SDK sólo acepta tokens sin firma si FIREBASE_AUTH_EMULATOR_HOST está definido. El ejecutable
// productivo rechaza esa variable; este binario existe únicamente con la etiqueta e2e.
func emulatorClient(ctx context.Context) *firebaseauth.Client {
	host := os.Getenv("FIREBASE_AUTH_EMULATOR_HOST")
	if host == "" {
		return nil
	}
	if !strings.HasPrefix(host, "127.0.0.1:") {
		log.Fatal("e2e only accepts a loopback identity emulator")
	}
	project := os.Getenv("FIREBASE_PROJECT_ID")
	if !strings.HasPrefix(project, "demo-") {
		log.Fatal("e2e only accepts a demo- Firebase project")
	}
	app, err := firebase.NewApp(ctx, &firebase.Config{ProjectID: project}, option.WithoutAuthentication())
	if err != nil {
		log.Fatal("cannot initialize identity emulator")
	}
	client, err := app.Auth(ctx)
	if err != nil {
		log.Fatal("cannot initialize identity emulator")
	}
	return client
}
func main() {
	cfg, err := pgxpool.ParseConfig(os.Getenv("TEST_DATABASE_URL"))
	if err != nil {
		log.Fatal("invalid test database configuration")
	}
	disposable := strings.HasPrefix(cfg.ConnConfig.Database, "medication_f3_") || strings.HasPrefix(cfg.ConnConfig.Database, "medication_f4_")
	if !disposable || (cfg.ConnConfig.Host != "127.0.0.1" && cfg.ConnConfig.Host != "/private/tmp") {
		log.Fatal("e2e requires a disposable local medication_f3_ or medication_f4_ database")
	}
	pool, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		log.Fatal("test database unavailable")
	}
	defer pool.Close()
	go serveFaultProxy("127.0.0.1:18084", "http://127.0.0.1:18083")
	server := &http.Server{Addr: "127.0.0.1:18083", Handler: httpapi.NewAPI(pool.Ping, application.New(pool, nil), verifier{emulatorClient(context.Background())}, nil), ReadHeaderTimeout: 5 * time.Second}
	log.Fatal(server.ListenAndServe())
}
