package application

import (
	"context"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
	"medication-tracker/services/api/internal/domain"
)

func (s *Service) GetInventoryProjection(ctx context.Context, actorID, accountID string, from time.Time) (Projection, error) {
	var result Projection
	if !domain.ValidID(accountID) || from.IsZero() || from.Year() < 1 {
		return result, ErrInvalid
	}
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadWrite})
	if err != nil {
		return result, err
	}
	defer tx.Rollback(ctx)
	if err = authorize(ctx, tx, actorID, accountTarget(accountID), ScopeRead); err != nil {
		return result, err
	}
	result, err = inventoryProjection(ctx, tx, accountID, from)
	if err != nil {
		return result, err
	}
	return result, tx.Commit(ctx)
}

func inventoryProjection(ctx context.Context, tx pgx.Tx, accountID string, from time.Time) (Projection, error) {
	var result Projection
	var err error
	var tr string
	var starts time.Time
	var ends *time.Time
	var archived *time.Time
	if err = tx.QueryRow(ctx, "SELECT a.treatment_id::text,a.unit,a.low_stock_days_threshold,t.starts_on,t.ends_on,t.archived_at FROM inventory_accounts a JOIN treatments t ON t.id=a.treatment_id WHERE a.id=$1", accountID).Scan(&tr, &result.Unit, &result.LowStockDaysThreshold, &starts, &ends, &archived); err != nil {
		return result, translate(err)
	}
	result.Balance, err = balance(ctx, tx, accountID)
	if err != nil {
		return result, err
	}
	result.From = from.UTC()
	revs, err := revisions(ctx, tx, tr)
	if err != nil {
		return result, err
	}
	if len(revs) == 0 {
		return result, ErrNotFound
	}
	active := revs[0]
	for _, r := range revs {
		if !r.from.After(from) {
			active = r
		}
	}
	result.Timezone = active.schedule.Timezone
	loc, _ := time.LoadLocation(result.Timezone)
	localDay, _ := domain.ParseDate(from.In(loc).Format("2006-01-02"))
	through, err := domain.StartOfDay(localDay.AddDate(0, 0, domain.HorizonDays).Format("2006-01-02"), loc)
	if err != nil {
		return result, err
	}
	result.Through = through.UTC()
	planned := []domain.Occurrence{}
	for _, r := range revs {
		loc, _ := time.LoadLocation(r.schedule.Timezone)
		day, _ := domain.ParseDate(from.In(loc).Format("2006-01-02"))
		last := through.In(loc).Format("2006-01-02")
		window := revisionWindow(r, starts, ends)
		if archived != nil && (window.Until == nil || archived.Before(*window.Until)) {
			window.Until = archived
		}
		if window.From.Before(from) {
			window.From = from
		}
		if window.Until == nil || window.Until.After(through) {
			window.Until = &through
		}
		if !window.From.Before(*window.Until) {
			continue
		}
		for ; day.Format("2006-01-02") <= last; day = day.AddDate(0, 0, 1) {
			occurrences, e := r.schedule.OccurrencesInWindow(day.Format("2006-01-02"), 1, window)
			if e != nil {
				return result, e
			}
			planned = append(planned, occurrences...)
		}
	}
	rows, err := tx.Query(ctx, "SELECT scheduled_at FROM dose_occurrences WHERE treatment_id=$1 AND scheduled_at >= $2 AND scheduled_at < $3 AND status<>'pending'", tr, result.From, result.Through)
	if err != nil {
		return result, err
	}
	declared := map[int64]bool{}
	for rows.Next() {
		var at time.Time
		if err = rows.Scan(&at); err != nil {
			rows.Close()
			return result, err
		}
		declared[at.Unix()] = true
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return result, err
	}
	sort.Slice(planned, func(i, j int) bool { return planned[i].At.Before(planned[j].At) })
	stock := result.Balance
	for _, o := range planned {
		if declared[o.At.Unix()] {
			continue
		}
		result.ScheduledQuantity += o.Quantity
		if result.FirstUncoveredAt == nil && stock < o.Quantity {
			at := o.At
			result.FirstUncoveredAt = &at
		}
		stock -= o.Quantity
	}
	if result.FirstUncoveredAt != nil {
		day, _ := domain.ParseDate(result.FirstUncoveredAt.In(loc).Format("2006-01-02"))
		date := day.AddDate(0, 0, -result.LowStockDaysThreshold).Format("2006-01-02")
		result.ReplenishOn = &date
		result.LowStock = from.In(loc).Format("2006-01-02") >= date
	}
	return result, nil
}
