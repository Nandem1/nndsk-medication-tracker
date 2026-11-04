package application

import (
	"context"
	"github.com/jackc/pgx/v5"
)

type StockThreshold struct {
	Days int `json:"low_stock_days_threshold"`
}
type SetStockThresholdCommand struct {
	Mutation
	AccountID          string
	ExpectedDays, Days int
}

func (s *Service) SetStockThreshold(ctx context.Context, c SetStockThresholdCommand) (StockThreshold, error) {
	return transact(ctx, s, c.Mutation, accountTarget(c.AccountID), ScopeInventory, "stock_threshold", c, func(tx pgx.Tx) (StockThreshold, error) {
		if c.Days < 0 || c.Days > 30 || c.ExpectedDays < 0 {
			return StockThreshold{}, ErrInvalid
		}
		if _, err := lockInventory(ctx, tx, c.AccountID); err != nil {
			return StockThreshold{}, err
		}
		pool, err := activePool(ctx, tx, c.AccountID)
		if err != nil {
			return StockThreshold{}, err
		}
		query, id := `SELECT low_stock_days_threshold FROM inventory_accounts WHERE id=$1`, c.AccountID
		update := `UPDATE inventory_accounts SET low_stock_days_threshold=$2 WHERE id=$1`
		if pool != "" {
			query, id = `SELECT low_stock_days_threshold FROM inventory_pools WHERE id=$1`, pool
			update = `UPDATE inventory_pools SET low_stock_days_threshold=$2 WHERE id=$1`
		}
		var previous int
		if err = tx.QueryRow(ctx, query, id).Scan(&previous); err != nil {
			return StockThreshold{}, err
		}
		if previous != c.ExpectedDays {
			return StockThreshold{}, ErrConflict
		}
		_, err = tx.Exec(ctx, update, id, c.Days)
		return StockThreshold{c.Days}, err
	})
}
