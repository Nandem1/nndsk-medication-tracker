package config

import "testing"

func TestLoad(t *testing.T) {
	for _, tc := range []struct {
		name, addr, url, env string
		fail                 bool
	}{
		{"defaults", "", "postgres://dev@localhost/test?sslmode=disable", "", false},
		{"bad address", "localhost", "postgres://dev@localhost/test", "", true},
		{"bad port", ":70000", "postgres://dev@localhost/test", "", true},
		{"missing database", "", "postgres://localhost", "", true},
		{"missing URL", "", "", "", true},
		{"wrong scheme", "", "https://localhost/db", "", true},
		{"unknown environment", "", "postgres://localhost/db", "prod", true},
		{"insecure production", "", "postgres://localhost/db?sslmode=disable", "production", true},
		{"verified production", "", "postgres://localhost/db?sslmode=verify-full", "production", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("HTTP_ADDR", tc.addr)
			t.Setenv("DATABASE_URL", tc.url)
			t.Setenv("APP_ENV", tc.env)
			cfg, err := Load()
			if (err != nil) != tc.fail {
				t.Fatalf("error=%v, expected failure=%v", err, tc.fail)
			}
			if !tc.fail && tc.addr == "" && cfg.HTTPAddr != "127.0.0.1:8080" {
				t.Fatalf("unexpected address %s", cfg.HTTPAddr)
			}
		})
	}
}
