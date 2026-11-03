# Verificar F8

Estado al 2026-11-03. F8 está parcialmente implementada y no se declara lista para lanzamiento. El usuario autorizó después el commit y la preparación para GitHub. No hay push, migraciones destructivas ni despliegue de esta fase. El rediseño visual queda para Claude.

## Cambios implementados

- Firebase Admin valida firma y revocación, y rechaza cuentas deshabilitadas/eliminadas o verificaciones fallidas. Requiere ADC externo. Los permisos por paciente siguen en PostgreSQL.
- `GET /v1/me/export` devuelve snapshot consistente de la cuenta propia con esquema v1. Exporta historial completo de correcciones, movimientos, dosis canceladas y metadatos permitidos. No exporta secretos ni datos clínicos ajenos. Las cantidades son cadenas exactas. Hay límites de 100.000 registros, 20 MiB y dos exportaciones concurrentes por proceso.
- Logout nativo oculta datos y controla trabajo en vuelo. El historial iOS comparte la cola de sincronización. La limpieza de credenciales informa fallos y mantiene una marca que impide restaurar una eliminación incompleta.
- CI separa Go, web, Android e iOS opcional. El smoke de Go ya no intenta compilar web. Sus credenciales ADC sintéticas sólo permiten inicializar las probes; no verifican identidad remota.
- Se documentan amenazas, incidentes, revisión de requisitos oficiales, checklist de release y entrega del rediseño.

La exportación cubre datos de PostgreSQL. No incluye el perfil almacenado exclusivamente en Firebase ni una interfaz de descarga en las apps. El borrado de cuenta no está implementado.

## Evidencia ejecutada

| Verificación | Resultado y alcance |
| --- | --- |
| `make test` y `make lint` antes de cambios | PASS, baseline Go y web |
| `make test lint build` después de cambios | PASS. Go race tests, vet, 15 tests web, tipos y build Vite. Advertencias preexistentes `use client` del bundler |
| `make test-integration` | PASS con PostgreSQL local real, base `medication_f3_f8`. Incluye IDOR, revocación concurrente, idempotencia, consumo único, correcciones, DST y exportación |
| Exportación bajo cambios concurrentes | PASS. Bloqueo controlado del ledger y cambio de metadatos demuestran una sola instantánea. Pruebas de límites devuelven error sin datos parciales |
| Firebase local | PASS. Firmas RSA y servidor TLS sintéticos; rechazo de cuenta deshabilitada, token revocado, usuario inexistente y proveedor indisponible. No es prueba de Firebase remoto |
| `E2E_PORT_OFFSET=80 make test-web-e2e` | PASS, 6 flujos en navegador con API y PostgreSQL reales e identidad sintética |
| `sh scripts/smoke.sh` | PASS, healthz 200, readyz 200 y SIGTERM sin error |
| `make test-backup` | PASS, backup cifrado y restore local desechable. Coinciden hashes de 21 tablas; se rechazan destino poblado y archivo alterado |
| iOS en simulador iPhone 17 | PASS, 60 pruebas en 12 suites, incluidas carreras de cierre y refresh compartido, con warnings como errores. La copia integrada anterior también pasó 59 pruebas y `lint-ios` |
| iOS UI de limpieza | PASS, una prueba de borrado desde login y relanzamiento, con setup que elimina dependencia del orden |
| Android unitarias | PASS, 15 tests |
| Android instrumentadas | PASS, `make test-android-device` en el worktree final: 7 tests de Room/Keystore, recordatorios y limpieza desde login en emulador `medication_f5` |
| Android lint | PASS, Debug y Release. Persisten avisos de deprecación FCM conocidos |
| YAML de workflows y `git diff --check` | PASS sintáctico. No acredita ejecución GitHub Actions |

Logs locales en `.tmp/f8/final-tests.log`, `.tmp/f8/core-final.log`, `.tmp/f8/ios-root.log`, `.tmp/f8/backup.log`, `.tmp/f8/android-root-device.log` y `.tmp/f8/smoke.log`. Los cambios nativos también se probaron en el worktree aislado `.tmp/f8-clients`; sus logs están en `/tmp/f8-client-ios-final.log`, `/tmp/f8-client-android-device.log` y `/tmp/f8-client-android-lint.log`. Los casos de la última revisión están en `/tmp/f8-client-ios-reviewfix.log`, `/tmp/f8-client-ios-cleanup-ui-final.log` y `/tmp/f8-client-android-reviewfix.log`. Son artefactos locales no versionados.

Los intentos iniciales de red, Gradle y CoreSimulator fueron rechazados por el sandbox. Las mismas comprobaciones se ejecutaron después con acceso local permitido. Un test HTTP necesitó ADC sintético tras habilitar comprobación de revocación; se corrigió el fixture sin desactivar el control productivo.

## Reproducir sin tocar bases existentes

1. Crea una base local desechable. Usa prefijo `medication_f3_` para Playwright.
2. Configura `TEST_DATABASE_URL` exclusivamente hacia esa base, sin imprimirla ni usar conexiones de producción.
3. Aplica goose directamente con `GOOSE_DRIVER=postgres` y `GOOSE_DBSTRING` igual a `TEST_DATABASE_URL`. `make migrate-up` recarga `.env`; no lo uses si allí apunta a otro destino.
4. Ejecuta `make test lint build test-integration` y `make test-web-e2e`.
5. Para backup crea otra base sintética con prefijo `medication_f6_` y ejecuta `make test-backup` apuntando a ella.
6. Ejecuta `make test-ios lint-ios`, `make test-android lint-android` y las pruebas instrumentadas sobre un emulador. No reinicies ni borres teléfonos físicos para este ensayo.

Los tests de integración crean datos sintéticos. No se ejecutaron down migrations porque F8 no modifica el esquema.

## Bloqueos y pendientes

- Falta aceptar la política concreta de borrado/retención planteada al usuario. No se implementó una purga suponiendo consentimiento. Se propone eliminar historia propia, desvincular identidad de acciones sobre historia ajena y caducar backups en 30 días.
- Una purga debe resolver FKs, triggers append-only, respuestas idempotentes por actor, Firebase y supresiones tras restore. No basta marcar la cuenta como eliminada. Requiere pruebas de carreras y preservación de otros pacientes.
- Falta incorporar controles de exportación/borrado en las apps. No se delegan a Claude como trabajo visual.
- Falta auditoría persistente de lecturas administrativas sensibles, con retención definida.
- No se configuraron credenciales ni se probó revocación en Firebase remoto. Staging sigue con su versión anterior.
- Los workflows no se ejecutaron en GitHub. La disponibilidad de SDK/runners y los permisos remotos siguen pendientes.
- Faltan pruebas físicas de lectores de pantalla, texto ampliado, offline y limitaciones del fabricante. El rediseño obliga a repetir contraste y composición.
- No hay protección adicional de capturas/selector de apps ni prueba de saneamiento forense de SQLite/WAL.
- No se activó push ni se acreditó recepción APNs/FCM. No se ensayó restore cloud/PITR.
- Falta elegir canal de distribución, responsables, contacto y revisión jurídica aplicable antes de publicación.

## Architecture Impact

Cambian la validación de identidad, la API de exportación, el ciclo de cierre de sesión móvil y la separación de CI. No cambia el modelo de datos ni las reglas de dosis/inventario. No hay nuevas dependencias de aplicación. Los mapas general, iOS y Android describen los cambios.

La revisión independiente del backend no detectó filtración o autorización incorrecta nueva. Señaló limitar concurrencia de exportación y actualizar mapa/evidencia; ambas observaciones se incorporaron. La revisión nativa señaló recuperación de limpieza y consumidores concurrentes de refresh. Se corrigieron con validación común después de esperar el token, acción de reintento sin autenticación y nuevas regresiones de sesión/UI. La revisión usa el modelo heredado; no es una revisión multimodelo.

## Preparación para GitHub

Gitleaks 8.24.3 no detectó secretos en los 10 commits previos ni en los archivos publicables inspeccionados. Se excluyen configuración local, credenciales, firmas, bases y backups. Un workflow repite el escaneo del historial. Esto no garantiza detectar cualquier dato sensible ni sustituye revisión humana.

El proxy web usa `API_PROXY_TARGET` en configuración local ignorada; el valor por defecto apunta a la API local. Se retiraron identificadores operativos de staging de la documentación actual. Sus referencias históricas siguen en Git; no son credenciales y no se reescribió el historial. El README breve enlaza la guía de desarrollo. No se creó remoto ni se publicó el repositorio.
