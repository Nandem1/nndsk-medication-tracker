package application

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
)

func TestMaterializedReadRetryPolicy(t *testing.T) {
	for _, tc := range []struct {
		name  string
		err   error
		calls int
	}{
		{"serialization", &pgconn.PgError{Code: "40001"}, 3},
		{"deadlock", &pgconn.PgError{Code: "40P01"}, 3},
		{"materialization unique", materializationError{&pgconn.PgError{Code: "23505"}}, 3},
		{"unrelated unique", &pgconn.PgError{Code: "23505"}, 1},
		{"invalid", ErrInvalid, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			calls := 0
			_, err := retryMaterializedRead(context.Background(), func() (int, error) { calls++; return 0, tc.err })
			if calls != tc.calls || err == nil {
				t.Fatal(calls, err)
			}
		})
	}
	ctx, cancel := context.WithCancel(context.Background())
	calls := 0
	_, err := retryMaterializedRead(ctx, func() (int, error) { calls++; cancel(); return 0, &pgconn.PgError{Code: "40001"} })
	if calls != 1 || !errors.Is(err, context.Canceled) {
		t.Fatal("cancellation ignored", calls, err)
	}
}

func TestProfileNameUnicode(t *testing.T) {
	if got, err := profileName("  " + strings.Repeat("ñ", 60) + "  "); err != nil || got != strings.Repeat("ñ", 60) {
		t.Fatal("60 Unicode characters rejected")
	}

	for _, name := range []string{"a\u0085b", "a\u2028b", "a\u2029b", "\xff"} {
		if _, err := profileName(name); !errors.Is(err, ErrInvalid) {
			t.Fatal("invalid name accepted")
		}
	}
}
