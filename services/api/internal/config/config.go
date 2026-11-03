package config

import (
	"errors"
	"net"
	"net/url"
	"os"
	"strconv"
)

type Config struct {
	HTTPAddr          string
	DatabaseURL       string
	DatabaseCAPEM     string
	FirebaseProjectID string
}

func Load() (Config, error) {
	c := Config{HTTPAddr: os.Getenv("HTTP_ADDR"), DatabaseURL: os.Getenv("DATABASE_URL"), DatabaseCAPEM: os.Getenv("DATABASE_CA_PEM")}
	if c.HTTPAddr == "" {
		c.HTTPAddr = "127.0.0.1:8080"
	}
	_, port, err := net.SplitHostPort(c.HTTPAddr)
	if err != nil {
		return Config{}, errors.New("HTTP_ADDR must be host:port")
	}
	n, err := strconv.Atoi(port)
	if err != nil || n < 1 || n > 65535 {
		return Config{}, errors.New("HTTP_ADDR requires a port between 1 and 65535")
	}
	u, err := url.Parse(c.DatabaseURL)
	if err != nil || u == nil || (u.Scheme != "postgres" && u.Scheme != "postgresql") || u.Hostname() == "" || u.Path == "" || u.Path == "/" {
		return Config{}, errors.New("DATABASE_URL must be a PostgreSQL URL with host and database")
	}
	switch os.Getenv("APP_ENV") {
	case "", "development", "test":
	case "production", "staging":
		if u.Query().Get("sslmode") != "verify-full" {
			return Config{}, errors.New("staging and production require DATABASE_URL sslmode=verify-full")
		}
	default:
		return Config{}, errors.New("APP_ENV must be development, test, staging or production")
	}
	if os.Getenv("FIREBASE_AUTH_EMULATOR_HOST") != "" {
		return Config{}, errors.New("Firebase emulator environment is forbidden in the API executable")
	}
	c.FirebaseProjectID = os.Getenv("FIREBASE_PROJECT_ID")
	if c.FirebaseProjectID == "" || c.FirebaseProjectID == "replace-me" {
		return Config{}, errors.New("FIREBASE_PROJECT_ID is required")
	}
	return c, nil
}
