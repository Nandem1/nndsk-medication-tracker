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
		var previous int
		if err := tx.QueryRow(ctx, `SELECT low_stock_days_threshold FROM inventory_accounts WHERE id=$1 FOR UPDATE`, c.AccountID).Scan(&previous); err != nil {
			return StockThreshold{}, err
		}
		if previous != c.ExpectedDays {
			return StockThreshold{}, ErrConflict
		}
		_, err := tx.Exec(ctx, `UPDATE inventory_accounts SET low_stock_days_threshold=$2 WHERE id=$1`, c.AccountID, c.Days)
		return StockThreshold{c.Days}, err
	})
}
