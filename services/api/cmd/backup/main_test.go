package main

import (
	"net/url"
	"strings"
	"testing"
)

func TestRestoreDestinationCannotBeOverridden(t *testing.T) {
	base := "postgres://synthetic:local@127.0.0.1:55433/medication_f6_restore_test"
	for _, suffix := range []string{"?host=remote", "?dbname=other", "?service=other", "?sslmode=disable&sslmode=require", "?sslmode=verify-full", "#ignored", "/other", "?hostaddr=1.2.3.4"} {
		u, _ := url.Parse(base + suffix)
		if _, _, err := restoreConnection(u); err == nil {
			t.Fatalf("accepted override %s", suffix)
		}
	}
	t.Setenv("PGHOSTADDR", "1.2.3.4")
	t.Setenv("PGSERVICE", "other")
	u, _ := url.Parse(base + "?sslmode=disable")
	canonical, env, err := restoreConnection(u)
	if err != nil || canonical != base+"?sslmode=disable" {
		t.Fatal("canonical destination", err)
	}
	for _, v := range env {
		if strings.HasPrefix(v, "PGSERVICE=") || strings.HasPrefix(v, "PGHOSTADDR=") {
			t.Fatal("inherited destination override")
		}
	}
}
