# Railway staging

Desplegado y verificado el 2026-11-03. Proyecto `medication-tracker`, con ambientes `staging` y `production`. Production permanece reservado: cero instancias y cero volúmenes. Staging contiene PostgreSQL, API y worker en `us-east4-eqdc4a` (Virginia). No se cargaron datos reales ni fixtures clínicos.

La API está en el dominio de la API configurado en Railway. `/healthz` y `/readyz` responden 200; `/v1/me` sin token responde 401. El portal web y las apps nativas no se desplegaron como parte de este paso.

## Configuración desplegada

API y worker usan `infrastructure/docker/backend.Dockerfile`, con `COMMAND=api` y `COMMAND=worker` respectivamente. API escucha en `0.0.0.0:8080`, publica HTTPS y usa `/readyz` como healthcheck. PostgreSQL y worker no tienen dominio público. Las métricas conservan sus listeners locales privados.

Ambos procesos tienen `APP_ENV=staging` y `WORKER_PUSH_MODE=disabled`. `DATABASE_URL` referencia `${{Postgres.DATABASE_URL}}?sslmode=verify-full`; `DATABASE_CA_PEM` contiene la CA pública de PostgreSQL, inyectada como variable del ambiente. No copies conexiones resueltas ni credenciales a este documento.

El pool compartido valida cadena y hostname, también en sus conexiones alternativas. Rechaza una CA inválida o configuraciones que omiten la verificación TLS. La sesión SQL comprobada negoció TLS 1.3. La imagen de PostgreSQL está fijada a:

```
ghcr.io/railwayapp-templates/postgres-ssl:18@sha256:4fc833b43d2aaf6ecc9b18615f5533602b723a32d0e2efe2dae8ca0f7217c863
```

El template administra sus certificados en el volumen. Una renovación que cambie la CA exige actualizar `DATABASE_CA_PEM` y redesplegar API y worker; verifica `/readyz` y los ciclos después. No soluciones un fallo de confianza desactivando TLS. Los certificados cubren localhost y el dominio privado; no se configuró un proxy TCP público.

`FIREBASE_PROJECT_ID=<firebase-project-id>` está configurado en API y worker. Desarrollo y staging comparten usuarios Firebase; PostgreSQL permanece separado. El usuario confirmó login y uso en iOS y posteriormente el flujo completo con web y Android en staging. No hay emulador ni bypass de autenticación. APNs y FCM siguen desactivados y sin credenciales de envío.

## Evidencia

| Recurso | Identificador |
| --- | --- |
| Proyecto | Consultar en Railway |
| Staging | Consultar en Railway |
| Production reservado | Consultar en Railway |
| Despliegue PostgreSQL SUCCESS | Consultar en Railway |
| Despliegue API F7 SUCCESS | Consultar en Railway |
| Despliegue worker F7 SUCCESS | Consultar en Railway |

Se aplicaron las cinco migraciones con Goose a la base nueva mediante túnel SSH y TLS `verify-full`. No se ejecutó down remoto. El worker registra ciclos consecutivos sin errores, con cero avisos y push desactivado.

Un backup AES-GCM tomado desde staging se restauró en la base local desechable `medication_f6_restore_railway_6ce6db45`. Coincidieron los hashes de las 21 tablas. La base remota sólo contenía esquema y versiones de migración: este ensayo prueba recuperación de ese estado; los ensayos locales con datos sintéticos se documentan en [verificación F6](f6-verification.md). La clave y el archivo cifrado temporales se eliminaron al finalizar.

No se ha ensayado restauración dentro de Railway, PITR ni una programación automática de backups. Para recuperar datos, seguir el [runbook de recuperación](f6-recovery.md), manteniendo push desactivado. Para futuras migraciones seleccionar explícitamente proyecto y ambiente y obtener la conexión desde variables protegidas; no usar un Makefile que cargue `.env` local para una migración remota.

## Siguiente paso dentro de F6

Login y flujo manual en staging aceptados por el usuario como MVP. Quedan proveedores push y firma nativa, registro de teléfonos y comprobación de recepción, revocación y permisos. F6 se cerró con esos pendientes. F5b sigue pendiente; F7 se desplegó después, según el registro siguiente.

## Architecture Impact

API y worker comparten la construcción del pool TLS, pero se despliegan como procesos separados. Staging aísla variables, servicios y volumen de production dentro del mismo proyecto. No cambian contratos HTTP ni reglas del dominio con esta configuración.


## Actualización a F7

El usuario autorizó subir staging a F7 el 2026-11-03 para ejecutar su propio E2E. API y worker se actualizaron mediante `railway up --path-as-root`, con proyecto y ambiente explícitos. Ambos despliegues de la tabla alcanzaron `SUCCESS`. El despliegue se hizo desde el worktree sin commit, sin migraciones ni cambios en production.

El paquete incluyó 67 archivos de backend, Dockerfile y contrato, tomados del workspace con los archivos nuevos sin commit. No incluyó variables locales ni credenciales. Su manifiesto de rutas y hashes SHA-256 quedó en `.tmp/f7-deploy/source-manifest.json`, con hash `0b3116783d7f9d8f0f23c35c99d683038c51cfcdac2a5720eac84abade365375`. Tras desplegar se comprobó que el código local seguía coincidiendo con ese manifiesto.

Las probes públicas `/healthz` y `/readyz` respondieron 200. `/v1/me`, la consulta de adherencia y la mutación de antelación devolvieron 401 sin token. Estas comprobaciones acreditan salud y protección de acceso; no sustituyen un E2E autenticado remoto. El worker completó ciclos a las 22:38 y 22:39 UTC con cero avisos encolados y `push_mode=disabled`.

El portal sigue servido localmente en `http://127.0.0.1:5173`, con proxy hacia esta API. Se comprobó que entrega el módulo F7 de Seguimiento y que `/v1/me` por el proxy devuelve 401 sin sesión. Para la prueba manual, recargar el portal, iniciar sesión y abrir un paciente en Seguimiento. No se creó un servicio web público nuevo.

Los despliegues anteriores registrados antes de la actualización eran API `<deployment-id>` y worker `<deployment-id>`, ambos saludables. Quedan como referencia operacional para una reversión autorizada. La [verificación F7](f7-verification.md) conserva las pruebas locales previas y sus límites.

El usuario confirmó su E2E de F7 en staging el 2026-11-03 con «excelente, todo correcto» y autorizó el commit de cierre. La aceptación conserva los límites y pendientes que no fueron detallados en esa prueba.

## Credencial de Firebase Admin

Desde F8, la API comprueba revocación con Firebase Admin, y el borrado de cuenta da de baja el acceso. Sin credencial, los tokens reales no reciben respuesta a tiempo y nadie puede iniciar sesión. Railway sólo ofrece variables, así que la API lee `FIREBASE_SERVICE_ACCOUNT_JSON`, además de ADC.

La credencial es una cuenta de servicio con el rol «Firebase Authentication Admin» sobre el proyecto de Firebase. Se carga como variable sólo en el servicio `api` de staging. No se versiona, no se imprime y el archivo descargado se borra después de cargarla. Producción necesita su propia cuenta de servicio, no ésta.

## Actualización a modo familia

API y worker se actualizaron desde un paquete limpio de `git archive`. Las migraciones 6, 7 y 8 se aplicaron en una sola transacción mediante `railway ssh`, y se registraron en `goose_db_version`. El usuario autorizó usar su clave SSH existente, que se registró en Railway sólo durante la migración y se retiró al terminar. Producción no se tocó.
