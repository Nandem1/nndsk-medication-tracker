# Railway staging

Desplegado y verificado el 2026-11-03. Proyecto `medication-tracker`, con ambientes `staging` y `production`. Production permanece reservado: cero instancias y cero volúmenes. Staging contiene PostgreSQL, API y worker en `us-east4-eqdc4a` (Virginia). No se cargaron datos reales ni fixtures clínicos.

La API está en https://api-staging-a498.up.railway.app. `/healthz` y `/readyz` responden 200; `/v1/me` sin token responde 401. El portal web y las apps nativas no se desplegaron como parte de este paso.

## Configuración desplegada

API y worker usan `infrastructure/docker/backend.Dockerfile`, con `COMMAND=api` y `COMMAND=worker` respectivamente. API escucha en `0.0.0.0:8080`, publica HTTPS y usa `/readyz` como healthcheck. PostgreSQL y worker no tienen dominio público. Las métricas conservan sus listeners locales privados.

Ambos procesos tienen `APP_ENV=staging` y `WORKER_PUSH_MODE=disabled`. `DATABASE_URL` referencia `${{Postgres.DATABASE_URL}}?sslmode=verify-full`; `DATABASE_CA_PEM` contiene la CA pública de PostgreSQL, inyectada como variable del ambiente. No copies conexiones resueltas ni credenciales a este documento.

El pool compartido valida cadena y hostname, también en sus conexiones alternativas. Rechaza una CA inválida o configuraciones que omiten la verificación TLS. La sesión SQL comprobada negoció TLS 1.3. La imagen de PostgreSQL está fijada a:

```
ghcr.io/railwayapp-templates/postgres-ssl:18@sha256:4fc833b43d2aaf6ecc9b18615f5533602b723a32d0e2efe2dae8ca0f7217c863
```

El template administra sus certificados en el volumen. Una renovación que cambie la CA exige actualizar `DATABASE_CA_PEM` y redesplegar API y worker; verifica `/readyz` y los ciclos después. No soluciones un fallo de confianza desactivando TLS. Los certificados cubren localhost y el dominio privado; no se configuró un proxy TCP público.

`FIREBASE_PROJECT_ID=medication-tracker-dev-8ebde` está configurado en API y worker. Desarrollo y staging comparten usuarios Firebase; PostgreSQL permanece separado. El usuario confirmó login y uso en iOS y posteriormente el flujo completo con web y Android en staging. No hay emulador ni bypass de autenticación. APNs y FCM siguen desactivados y sin credenciales de envío.

## Evidencia

| Recurso | Identificador |
| --- | --- |
| Proyecto | `b910701b-28dc-4d5f-80b1-0a9fd4c70883` |
| Staging | `b185d7b6-fca4-4897-adb3-4ea97d7cd22c` |
| Production reservado | `d513f258-902a-4354-8f1e-7a010938a079` |
| Despliegue PostgreSQL SUCCESS | `e73a5c48-9386-4516-adc4-e6b5c8198272` |
| Despliegue API SUCCESS | `0b2fa1a3-74cc-4704-a919-8a3b340b5853` |
| Despliegue worker SUCCESS | `50bf9827-5502-44cf-b4bd-efb750c9d370` |

Se aplicaron las cinco migraciones con Goose a la base nueva mediante túnel SSH y TLS `verify-full`. No se ejecutó down remoto. El worker registra ciclos consecutivos sin errores, con cero avisos y push desactivado.

Un backup AES-GCM tomado desde staging se restauró en la base local desechable `medication_f6_restore_railway_6ce6db45`. Coincidieron los hashes de las 21 tablas. La base remota sólo contenía esquema y versiones de migración: este ensayo prueba recuperación de ese estado; los ensayos locales con datos sintéticos se documentan en [verificación F6](f6-verification.md). La clave y el archivo cifrado temporales se eliminaron al finalizar.

No se ha ensayado restauración dentro de Railway, PITR ni una programación automática de backups. Para recuperar datos, seguir el [runbook de recuperación](f6-recovery.md), manteniendo push desactivado. Para futuras migraciones seleccionar explícitamente proyecto y ambiente y obtener la conexión desde variables protegidas; no usar un Makefile que cargue `.env` local para una migración remota.

## Siguiente paso dentro de F6

Login y flujo manual en staging aceptados por el usuario como MVP. Quedan proveedores push y firma nativa, registro de teléfonos y comprobación de recepción, revocación y permisos. F6 se cierra con esos pendientes; F5b y F7 no se ejecutaron.

## Architecture Impact

API y worker comparten la construcción del pool TLS, pero se despliegan como procesos separados. Staging aísla variables, servicios y volumen de production dentro del mismo proyecto. No cambian contratos HTTP ni reglas del dominio con esta configuración.
