package config

import (
	"crypto/x509"
	"errors"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func PoolConfig(c Config) (*pgxpool.Config, error) {
	pool, err := pgxpool.ParseConfig(c.DatabaseURL)
	if err != nil {
		return nil, errors.New("invalid PostgreSQL connection configuration")
	}
	pool.ConnConfig.ConnectTimeout = 2 * time.Second
	if c.DatabaseCAPEM == "" {
		return pool, nil
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM([]byte(c.DatabaseCAPEM)) {
		return nil, errors.New("DATABASE_CA_PEM must contain a valid certificate")
	}
	tls := pool.ConnConfig.TLSConfig
	if tls == nil || tls.InsecureSkipVerify || tls.ServerName == "" {
		return nil, errors.New("DATABASE_CA_PEM requires fully verified TLS")
	}
	tls.RootCAs = roots
	for _, fallback := range pool.ConnConfig.Fallbacks {
		if fallback.TLSConfig == nil || fallback.TLSConfig.InsecureSkipVerify || fallback.TLSConfig.ServerName == "" {
			return nil, errors.New("DATABASE_CA_PEM forbids unverified connection fallbacks")
		}
		fallback.TLSConfig.RootCAs = roots
	}
	return pool, nil
}
