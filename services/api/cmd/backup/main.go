package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"medication-tracker/services/api/internal/backup"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	if len(os.Args) != 3 || (os.Args[1] != "create" && os.Args[1] != "restore-test") {
		return errors.New("usage: backup create|restore-test archive.enc; set DATABASE_URL and BACKUP_KEY_FILE")
	}
	key, err := os.ReadFile(os.Getenv("BACKUP_KEY_FILE"))
	if err != nil {
		return errors.New("cannot read BACKUP_KEY_FILE")
	}
	if len(key) != 32 {
		return errors.New("BACKUP_KEY_FILE requires 32 raw bytes")
	}
	connection := os.Getenv("DATABASE_URL")
	u, err := url.Parse(connection)
	if err != nil || u == nil || (u.Scheme != "postgres" && u.Scheme != "postgresql") || u.Hostname() == "" {
		return errors.New("invalid DATABASE_URL")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	if os.Args[1] == "create" {
		dump := exec.CommandContext(ctx, "pg_dump", "--format=custom", "--no-owner", "--no-acl")
		dump.Env, err = postgresEnvironment(u)
		if err != nil {
			return err
		}
		plain, err := dump.Output()
		if err != nil {
			return errors.New("pg_dump failed; check database availability and PostgreSQL client version")
		}
		encrypted, err := backup.Seal(plain, key)
		if err != nil {
			return err
		}
		file, err := os.OpenFile(os.Args[2], os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if err != nil {
			return errors.New("cannot create archive; destination must not exist")
		}
		_, writeErr := file.Write(encrypted)
		closeErr := file.Close()
		if writeErr != nil || closeErr != nil {
			return errors.New("cannot write backup archive")
		}
		fmt.Println("Encrypted backup created")
		return nil
	}
	connection, restoreEnv, err := restoreConnection(u)
	if err != nil {
		return err
	}
	encrypted, err := os.ReadFile(os.Args[2])
	if err != nil {
		return errors.New("cannot read archive")
	}
	plain, err := backup.Open(encrypted, key)
	if err != nil {
		return err
	}
	conn, err := pgx.Connect(ctx, connection)
	if err != nil {
		return errors.New("cannot connect to restore database")
	}
	defer conn.Close(ctx)
	var count int
	if err = conn.QueryRow(ctx, "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_toast%' AND c.relkind IN ('r','p','v','m','S')").Scan(&count); err != nil || count != 0 {
		return errors.New("restore requires an empty disposable database")
	}
	restore := exec.CommandContext(ctx, "pg_restore", "--exit-on-error", "--single-transaction", "--no-owner", "--no-acl", "--dbname="+u.Path[1:])
	restore.Env = restoreEnv
	restore.Stdin = bytes.NewReader(plain)
	if err = restore.Run(); err != nil {
		return errors.New("pg_restore failed; target transaction rolled back")
	}
	fmt.Println("Restored into disposable database; keep worker stopped until reconciliation and notification quarantine")
	return nil
}

func restoreConnection(u *url.URL) (string, []string, error) {
	invalid := errors.New("restore-test requires a canonical local disposable medication_f6_restore_ URL without connection overrides")
	if u == nil || (u.Scheme != "postgres" && u.Scheme != "postgresql") || (u.Hostname() != "localhost" && u.Hostname() != "127.0.0.1") || u.Fragment != "" {
		return "", nil, invalid
	}
	name := strings.TrimPrefix(u.Path, "/")
	if !strings.HasPrefix(name, "medication_f6_restore_") {
		return "", nil, invalid
	}
	for _, c := range name {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_') {
			return "", nil, invalid
		}
	}
	query, err := url.ParseQuery(u.RawQuery)
	if err != nil {
		return "", nil, invalid
	}
	for k, v := range query {
		if k != "sslmode" || len(v) != 1 || v[0] != "disable" {
			return "", nil, invalid
		}
	}
	port := u.Port()
	if port == "" {
		port = "5432"
	}
	n, err := strconv.Atoi(port)
	if err != nil || n < 1 || n > 65535 || u.User == nil || u.User.Username() == "" {
		return "", nil, invalid
	}
	canonical := *u
	canonical.RawQuery = "sslmode=disable"
	canonical.Host = u.Hostname() + ":" + port
	env := []string{}
	for _, value := range os.Environ() {
		if !strings.HasPrefix(value, "PG") {
			env = append(env, value)
		}
	}
	password, _ := u.User.Password()
	env = append(env, "PGHOST="+u.Hostname(), "PGPORT="+port, "PGDATABASE="+name, "PGUSER="+u.User.Username(), "PGPASSWORD="+password, "PGSSLMODE=disable", "PGCONNECT_TIMEOUT=10")
	return canonical.String(), env, nil
}

func postgresEnvironment(u *url.URL) ([]string, error) {
	if u.User == nil || u.User.Username() == "" || u.Hostname() == "" || u.Path == "" {
		return nil, errors.New("database URL requires explicit host, user and database")
	}
	env := []string{}
	for _, value := range os.Environ() {
		if !strings.HasPrefix(value, "PG") {
			env = append(env, value)
		}
	}
	password, _ := u.User.Password()
	port := u.Port()
	if port == "" {
		port = "5432"
	}
	env = append(env, "PGHOST="+u.Hostname(), "PGPORT="+port, "PGDATABASE="+strings.TrimPrefix(u.Path, "/"), "PGUSER="+u.User.Username(), "PGPASSWORD="+password)
	options := map[string]string{"sslmode": "PGSSLMODE", "sslrootcert": "PGSSLROOTCERT", "sslcert": "PGSSLCERT", "sslkey": "PGSSLKEY", "connect_timeout": "PGCONNECT_TIMEOUT"}
	query, err := url.ParseQuery(u.RawQuery)
	if err != nil {
		return nil, errors.New("invalid database connection options")
	}
	for key, values := range query {
		name, ok := options[key]
		if !ok || len(values) != 1 {
			return nil, errors.New("unsupported database connection option")
		}
		env = append(env, name+"="+values[0])
	}
	return env, nil
}
