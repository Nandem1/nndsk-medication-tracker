package application

import (
	"context"
	"errors"
	"math/rand/v2"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

type materializationError struct{ error }

func (e materializationError) Unwrap() error { return e.error }

func retryMaterializedRead[T any](ctx context.Context, read func() (T, error)) (T, error) {
	var zero T
	for attempt := 0; attempt < 3; attempt++ {
		value, err := read()
		if err == nil {
			return value, nil
		}
		var pg *pgconn.PgError
		var materialization materializationError
		retry := errors.As(err, &pg) && (pg.Code == "40001" || pg.Code == "40P01" || (pg.Code == "23505" && errors.As(err, &materialization)))
		if !retry || attempt == 2 {
			return zero, translate(err)
		}
		timer := time.NewTimer(time.Duration(50+rand.IntN(151)) * time.Millisecond)
		select {
		case <-ctx.Done():
			timer.Stop()
			return zero, ctx.Err()
		case <-timer.C:
		}
	}
	return zero, ErrConflict
}
