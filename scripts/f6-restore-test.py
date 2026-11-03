#!/usr/bin/env python3
"""Exercise encrypted backup and restore using only disposable local databases."""
import hashlib
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
from urllib.parse import urlparse, urlunparse

root = Path(__file__).resolve().parents[1]
source = os.environ.get('TEST_DATABASE_URL', '')
parsed = urlparse(source)
if parsed.hostname not in ('127.0.0.1', 'localhost') or not parsed.path.startswith('/medication_f6_') or parsed.query not in ('', 'sslmode=disable'):
    raise SystemExit('Set TEST_DATABASE_URL to a local disposable medication_f6_ database without connection overrides')

def environment(connection):
    env = {k: v for k, v in os.environ.items() if not k.startswith('PG')}
    value = urlparse(connection)
    from urllib.parse import unquote
    env.update(PGHOST=value.hostname, PGPORT=str(value.port or 5432), PGDATABASE=value.path[1:], PGUSER=unquote(value.username or ''), PGPASSWORD=unquote(value.password or ''), PGSSLMODE='disable')
    return env

def sql(connection, statement):
    result = subprocess.run(['psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-c', statement], env=environment(connection), capture_output=True)
    if result.returncode:
        raise SystemExit('PostgreSQL verification failed')
    return result.stdout

def fingerprints(connection):
    tables = sql(connection, "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename").decode().splitlines()
    result = {}
    for table in tables:
        identifier = '"' + table.replace('"', '""') + '"'
        rows = sql(connection, f'SELECT to_jsonb(t)::text FROM public.{identifier} t ORDER BY to_jsonb(t)::text')
        result[table] = hashlib.sha256(rows).hexdigest()
    return result

before = fingerprints(source)
if not before:
    raise SystemExit('Source must contain migrated synthetic fixtures')
name = 'medication_f6_restore_' + secrets.token_hex(6)
admin = urlunparse(parsed._replace(path='/postgres'))
target = urlunparse(parsed._replace(path='/' + name))
sql(admin, f'CREATE DATABASE "{name}"')
with tempfile.TemporaryDirectory(prefix='f6-backup-') as directory:
    directory = Path(directory)
    key = directory / 'key'
    key.write_bytes(secrets.token_bytes(32))
    key.chmod(0o600)
    archive = directory / 'archive.enc'
    env = environment(source)
    env.update(DATABASE_URL=source, BACKUP_KEY_FILE=str(key))
    binary = root / '.bin' / 'backup'
    for operation, connection in [('create', source), ('restore-test', target)]:
        env['DATABASE_URL'] = connection
        subprocess.run([str(binary), operation, str(archive)], env=env, check=True)
    if fingerprints(target) != before:
        raise SystemExit('Restored table fingerprints differ from source')
    result = subprocess.run([str(binary), 'restore-test', str(archive)], env=env, capture_output=True)
    if result.returncode == 0:
        raise SystemExit('Restore incorrectly accepted a nonempty target')
    altered = bytearray(archive.read_bytes())
    altered[-1] ^= 1
    archive.write_bytes(altered)
    result = subprocess.run([str(binary), 'restore-test', str(archive)], env=env, capture_output=True)
    if result.returncode == 0 or b'authentication failed' not in result.stderr:
        raise SystemExit('Restore did not reject tampered archive before touching database')
print(f'PASS encrypted restore: {len(before)} table fingerprints match; nonempty target and tampered archive rejected')
print(f'Disposable database retained for reconciliation: {name}')
