package main

import (
	"context"
	"errors"
	"flag"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"medication-tracker/services/api/internal/application"
	"medication-tracker/services/api/internal/config"
	"medication-tracker/services/api/internal/observability"
	"medication-tracker/services/api/internal/push"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	if err := run(logger); err != nil {
		logger.Error("worker stopped", "error", err)
		os.Exit(1)
	}
}
func run(logger *slog.Logger) error {
	once := flag.Bool("once", false, "run one cycle and exit")
	audit := flag.Bool("reconcile", false, "inspect consistency without sending or repairing")
	flag.Parse()
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	pc, err := config.PoolConfig(cfg)
	if err != nil {
		return errors.New("invalid database configuration")
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	pool, err := pgxpool.NewWithConfig(ctx, pc)
	if err != nil {
		return errors.New("database initialization failed")
	}
	defer pool.Close()
	service := application.New(pool, nil)
	if *audit {
		report, err := service.Reconcile(ctx)
		if err != nil {
			return errors.New("reconciliation failed")
		}
		logger.Info("reconciliation", "counts", report)
		if report.DoseStateMismatches+report.ConsumptionMismatches+report.LedgerMismatches+report.AgendaMismatches > 0 {
			return errors.New("reconciliation found inconsistencies")
		}
		return nil
	}
	mode := os.Getenv("WORKER_PUSH_MODE")
	if mode == "" {
		mode = "disabled"
	}
	if mode != "disabled" && mode != "enabled" {
		return errors.New("WORKER_PUSH_MODE must be disabled or enabled")
	}
	var sender push.Sender
	if mode == "enabled" {
		sender, err = push.NewFromEnv(ctx)
		if err != nil {
			return errors.New("push configuration failed")
		}
	}
	metricsAddr := os.Getenv("METRICS_ADDR")
	if metricsAddr == "" {
		metricsAddr = "127.0.0.1:9091"
	}
	metricsDone := make(chan error, 1)
	go func() { metricsDone <- observability.Default.Serve(ctx, metricsAddr) }()
	tick := time.NewTicker(time.Minute)
	defer tick.Stop()
	for {
		cycleCtx, cancel := context.WithTimeout(ctx, 50*time.Second)
		queued, e := service.PlanAlerts(cycleCtx)
		observability.Default.WorkerCycles.Add(1)
		if e == nil && sender != nil {
			var stats application.AlertDeliveryStats
			stats, e = service.DeliverAlerts(cycleCtx, sender, 20)
			observability.Default.PushSent.Add(uint64(stats.Sent))
			observability.Default.PushRetry.Add(uint64(stats.Retry))
			observability.Default.PushUncertain.Add(uint64(stats.Uncertain))
			observability.Default.PushFailed.Add(uint64(stats.Failed))
			observability.Default.PushDeferred.Add(uint64(stats.Suppressed))
			observability.Default.PushDelayMilliseconds.Add(uint64(max(stats.DelaySeconds*1000, 0)))
			logger.Info("worker delivery", "counts", stats.String())
		}
		cancel()
		if e != nil {
			observability.Default.WorkerErrors.Add(1)
			logger.Error("worker cycle failed")
		} else {
			logger.Info("worker cycle complete", "queued", queued, "push_mode", mode)
		}
		if *once {
			if e != nil {
				return errors.New("worker cycle failed")
			}
			return nil
		}
		select {
		case <-ctx.Done():
			return nil
		case <-tick.C:
		case <-metricsDone:
			if ctx.Err() != nil {
				return nil
			}
			return errors.New("metrics server stopped")
		}
	}
}
