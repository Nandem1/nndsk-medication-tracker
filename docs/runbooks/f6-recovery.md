# Recuperar alertas, agenda e inventario

Usa una base sintética aislada para ensayos. Mantén el worker detenido durante una restauración. No ejecutes migraciones down sobre una base que deba conservar datos.

## Diagnosticar sin alterar historia

1. Configura `DATABASE_URL`, `FIREBASE_PROJECT_ID` y `APP_ENV` fuera del repositorio.
2. Ejecuta `go run ./cmd/worker --reconcile` desde `services/api`.
3. Investiga los contadores distintos de cero. El comando no modifica eventos ni movimientos.
4. Para reponer la ventana de agenda, ejecuta `WORKER_PUSH_MODE=disabled go run ./cmd/worker --once`.
5. Repite la reconciliación. No corrijas divergencias del ledger con un UPDATE. Usa correcciones o conteos auditables del dominio después de identificar la causa.

La ventana automática comienza dos días locales antes del ciclo y abarca el horizonte del dominio. No intenta enviar avisos históricos de más de 48 horas. Una interrupción extensa requiere revisar el período afectado con la API.

## Inspeccionar entregas

Consulta sólo conteos operacionales desde una sesión autorizada de PostgreSQL.

```sql
SELECT state, count(*) FROM notification_outbox GROUP BY state ORDER BY state;
SELECT count(*) FROM notification_outbox
WHERE state IN ('pending','retry') AND next_attempt_at < now() - interval '10 minutes';
```

- `sent` indica aceptación del proveedor, no recepción ni lectura.
- `retry` indica rechazo temporal explícito. El worker aplica backoff, `Retry-After`, frecuencia y vencimiento, con un máximo de cinco intentos.
- `uncertain` indica resultado ambiguo. No restablezcas ese estado a `pending`. Un aviso podría haber llegado.
- `suppressed` indica condición, consentimiento o dispositivo obsoleto.
- `failed` requiere revisar configuración o token. No publiques cuerpos de error del proveedor ni tokens en incidencias.

La rotación de token vuelve a asociar avisos pendientes sin intento al registro vigente. Nunca reabre una entrega intentada. Un token de otro propietario activo no se transfiere. Después de una salida offline, el conflicto puede durar hasta revocar o vencer el registro antiguo.

Una revocación confirmada antes de reservar el envío lo impide. Un envío reservado antes de la revocación puede estar ya en tránsito. Los payloads son genéricos.

## Crear backup cifrado y ensayar restore

1. Crea una clave externa de 32 bytes y conserva una copia segura separada del archivo de backup.
2. Exporta `BACKUP_KEY_FILE`, `BACKUP_ARCHIVE` como rutas absolutas y `DATABASE_URL`.
3. Ejecuta `make backup`. El archivo debe ser nuevo y se crea con permisos 0600.
4. Crea una base local vacía con prefijo `medication_f6_restore_`.
5. Cambia `DATABASE_URL` a esa base. El ensayo acepta únicamente localhost y `sslmode=disable`, sin overrides de conexión.
6. Ejecuta `make restore-test` y reconciliación con el worker detenido.

`make test-backup` automatiza un ensayo con `TEST_DATABASE_URL` local y sintética. Compara hashes de todas las filas de cada tabla, rechaza sobrescribir una base poblada y comprueba que una alteración del archivo falla la autenticación. La base restaurada queda disponible para inspección. No es una prueba de recuperación del proveedor cloud.

El cifrado se realiza en memoria y no crea un dump plano en disco. Esta implementación está destinada al tamaño familiar. Para bases mayores hay que medir memoria y elegir backup gestionado o cifrado por bloques antes de usarla.

## Evitar reenvíos tras restaurar una copia antigua

Una copia puede incluir avisos pendientes que ya se enviaron después del backup. Antes de habilitar el worker en el destino restaurado, invalida dispositivos y termina los avisos activos dentro de una transacción autorizada. Esto obliga a registrar de nuevo cada dispositivo.

```sql
BEGIN;
UPDATE device_registrations
SET revoked_at=now(), token='', permission='denied', revision=revision+1;
UPDATE notification_outbox
SET state='uncertain', completed_at=now()
WHERE state IN ('pending','retry','sending');
COMMIT;
```

No borres las claves de deduplicación ni reconstruyas una outbox histórica. Revisa primero reconciliación, permisos y preferencias. Reactiva sólo tras verificar el destino, el proveedor y la ausencia de datos reales.

## Supervisar sin datos personales

La API expone métricas en `127.0.0.1:9090/metrics`; el worker usa `127.0.0.1:9091/metrics`. `METRICS_ADDR` permite cambiar la escucha para una red operacional privada. No publiques estos puertos en Internet.

Los contadores cubren solicitudes, errores, duración acumulada, resultados de mutaciones de sincronización, ciclos del worker, entregas y retraso acumulado desde encolado hasta aceptación. No contienen IDs, tokens, rutas arbitrarias ni etiquetas médicas. Se reinician con el proceso. Un scraper externo debe conservar la serie temporal.

Investiga incrementos de errores o entregas inciertas y ausencia de ciclos. Compara pendientes vencidos con quiet hours, frecuencia, credenciales y conectividad. Las métricas HTTP no miden operaciones que todavía están offline en el teléfono.

## Preparar staging

`infrastructure/docker/backend.Dockerfile` compila API o worker con versiones fijadas por digest. `staging.compose.yaml` usa una base TLS externa y credenciales montadas como secret. No incluye datos ni credenciales reales.

Define fuera del repositorio `STAGING_DATABASE_URL`, `STAGING_FIREBASE_PROJECT_ID` y `STAGING_FIREBASE_CREDENTIALS_FILE`. Valida con `docker compose -f infrastructure/docker/staging.compose.yaml config --quiet`. Aplica migraciones up contra la base sintética y arranca API sólo en el destino acordado. El perfil `notifications` habilita el worker y FCM explícitamente. APNs necesita además sus variables y la clave montada como secret según el proveedor elegido.

El despliegue verificado de Railway, su TLS y sus límites están documentados en [Railway staging](railway-staging.md). Compose permanece como alternativa local; no es la configuración desplegada en Railway. Antes de habilitar push, completa el registro nativo y acuerda las preferencias por vínculo mediante los endpoints documentados en OpenAPI. F5b y F7 permanecen fuera de alcance.
