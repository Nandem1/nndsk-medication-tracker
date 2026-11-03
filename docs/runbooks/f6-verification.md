# Verificación F6

F6 implementada y desplegada en Railway staging el 2026-11-03 con autorización del usuario. Fase cerrada por aceptación explícita del usuario como MVP, con pendientes de entrega APNs/FCM real, recuperación cloud y monitoreo remoto. No se inició F5b ni F7. El usuario autorizó el commit de cierre; no se solicitó push a Git.

## Cambios implementados

- Migración 00005 con registros de dispositivos, preferencias por generación de consentimiento, outbox y frecuencia por cuidador.
- Worker Go en el módulo existente. Reutiliza calendario y proyección exacta. No escribe declaraciones ni movimientos de inventario.
- Reserva durable de entrega antes de HTTP. Resultado incierto sin replay automático, cinco intentos como máximo para rechazo temporal, quiet hours, vencimiento y deduplicación.
- Endpoints autorizados de dispositivos y preferencias, con contrato OpenAPI y respuestas sin tokens.
- APNs HTTP/2 con ES256 y FCM HTTP v1 con OAuth. Sin reintentos internos de envío. Payload genérico.
- Registro y revocación nativos por cuenta e instalación. Configuración desactivada por defecto. No se añadió vista móvil de cuidador.
- Reconciliación de estado, consumo, ledger, ventana de agenda, outbox y dispositivos. Métricas agregadas en listeners privados.
- Backup AES-256-GCM, restore restringido a base local vacía y contenedores fijados por digest. Runbook de recuperación.

## Pruebas ejecutadas

| Comando o prueba | Resultado y alcance |
| --- | --- |
| `make test` | PASS. Go con race detector y 10 tests web |
| `make lint` | PASS. gofmt, go vet y TypeScript |
| `make test-integration` | PASS. PostgreSQL 18.6 real, base `medication_f6_test`, suite completa con race detector |
| Goose `up`, `down-to 0`, `up` | PASS en `medication_f6_migrations`, exclusivamente desechable. Las cinco migraciones se revierten y reaplican |
| `make build-worker`; worker `--once` | PASS. Binario real con push desactivado |
| Worker `--reconcile` | PASS. Seis contadores de discrepancias en cero después de materializar la agenda sintética |
| Worker persistente y `GET /metrics` | PASS. Un ciclo, cero errores y cero envíos con push desactivado, sólo campos agregados |
| Tests de transporte push | PASS contra servidores HTTP locales, APNs HTTP/2. No representan entrega externa |
| `make test-backup` | PASS. Backup cifrado, restore PostgreSQL real y hashes iguales para las 21 tablas. Rechaza destino poblado y archivo manipulado |
| Reconciliación de copia restaurada | PASS. Los seis contadores en cero |
| Docker build API y worker | PASS con versiones fijadas por digest. Docker usa builder clásico porque buildx no está instalado |
| Contenedor worker `--once` y `--reconcile` | PASS contra PostgreSQL local sintético; push desactivado |
| Compose staging `config --quiet` | PASS con valores sintéticos; no acredita despliegue |
| iOS `xcodebuild ... SWIFT_TREAT_WARNINGS_AS_ERRORS=YES test` | PASS en simulador. 55 tests existentes y dos nuevos de registro/contrato |
| Android `:app:assembleDebug :app:testDebugUnitTest :app:lintDebug :app:lintRelease` | PASS. 15 tests, cero errores lint y 22 advertencias |
| `git diff --check` | PASS |

Los tests de aplicación cubren planificación y entrega concurrentes, crash después de reservar, desconexión ambigua, backoff, límites de intentos, revocación antes del claim, consentimiento renovado, permisos, rotación y expiración del token, quiet hours y stock según calendario. Verifican que los ciclos no alteran consumo ni ledger. Los tests HTTP comprueban acceso propio, IDOR, preferencias y consentimiento. Las invariantes F1/F2 permanecen cubiertas por la suite completa.

La revisión detectó que una rotación de token suprimía permanentemente un aviso no intentado. `TestF6TokenRotationRecoversOnlyUnattemptedAlerts` falló antes de la corrección con `rotation lost pending alert 0 suppressed`. Después pasó. La outbox sólo se reasocia si la condición sigue vigente y no hubo ningún intento. Una entrega incierta conserva su estado.

El ensayo de backup detectó que libpq no expande una URI en `PGDATABASE`. Se corrigió pasando campos explícitos mediante variables de entorno, sin URL en argumentos. La revisión también exigió rechazar overrides de destino en restore y respetar la cancelación durante adquisición del token OAuth. Los tests de regresión pasan.

## Evidencia local

Los logs de esta ejecución están en `.tmp/f6/`, fuera de Git. Incluyen `make-test.log`, `make-lint.log`, `integration.log`, `backup.log`, builds Docker y métricas del worker. Los tests nativos se ejecutaron en el worktree aislado antes de integrar los mismos archivos. Sus logs están en `/private/tmp/f6-ios-final.log` y `/private/tmp/f6-android-final.log`.

El restore conservó `medication_f6_restore_07465d0512ba` para inspección. No se ejecutó ningún worker con push habilitado sobre una copia restaurada. Los archivos temporales de clave y backup del ensayo se eliminaron al finalizar.

## Verificación Railway

API y worker terminaron sus despliegues con estado SUCCESS. HTTPS devolvió 200 en `/healthz` y `/readyz`, y 401 en `/v1/me` sin token. Los logs del worker muestran ciclos consecutivos con `queued=0` y `push_mode=disabled`. PostgreSQL 18.6 confirmó TLS 1.3 y recibió sólo las cinco migraciones up. El backup cifrado de staging se restauró localmente en `medication_f6_restore_railway_6ce6db45`: coincidieron los hashes de las 21 tablas, sin datos clínicos cargados.

El soporte de CA personalizada pasó pruebas reales de handshake TLS: acepta la CA confiable y rechaza hostname incorrecto y CA ajena. Después de integrarlo pasaron `make test` y `make lint`. [Configuración y despliegues](railway-staging.md).

## Límites y bloqueos

- Railway staging está desplegado en Virginia; production permanece vacío. Se ensayó backup desde staging y restore local, no recuperación cloud ni PITR. Firebase está configurado con `medication-tracker-dev-8ebde`; el usuario verificó login y uso del flujo completo en staging.
- No se dispone de la configuración de prueba necesaria para acreditar entrega APNs/FCM real. Falta registrar dispositivos, habilitar firma APNs y verificar recepción, revocación y permisos en teléfonos.
- APNs requiere clave, team, key ID, topic y entorno coherentes con la firma. FCM requiere proyecto y ADC del servidor, además de los identificadores públicos correctos en Android.
- Firebase Messaging 26.0.1 conserva las APIs de token usadas pero las marca deprecadas. El nuevo modo FID no se habilitó porque requiere otro contrato de envío. Las advertencias no se ocultaron.
- No se ejecutaron pruebas físicas ni se modificó el Android conectado. La prueba de simulador no acredita restricciones de entrega en dispositivos físicos.
- Las preferencias se configuran por API. El plazo de dosis sin confirmar sigue desactivado hasta acordarlo con la familia. Stock también requiere opt-in.
- Una caída entre reserva y envío puede perder un aviso. Se prioriza no repetir envíos ambiguos. No se promete entrega exactamente una vez ni puntualidad.
- El worker materializa tratamientos en una transacción global por ciclo. Antes de aumentar el volumen familiar hay que medir contención y duración.
- Las métricas de sync cubren respuestas HTTP de declaraciones/correcciones, no operaciones que siguen offline en el dispositivo.

Pendientes conservados tras el cierre: configurar los proveedores push, verificar recepción en ambos teléfonos y ensayar recuperación en el proveedor cloud. La siguiente fase numerada es F7; F5b permanece pendiente y se recomienda retomarla primero para habilitar el rol cuidador móvil. Ninguna de ellas se inició.

## Architecture Impact

Cambian modelo de datos, endpoints, autorización de nuevos recursos, registro nativo, integración push, procesos y operación. Las reglas clínicas y el ledger conservan su semántica. Se actualizaron el mapa general, ambos mapas nativos y la decisión F6. La revisión independiente detectó la pérdida por rotación y se corrigió con regresión. La validación externa sigue pendiente.

## Aceptación del MVP

El usuario confirmó login y uso de iOS en staging y luego declaró: «Funciono perfecto, probe el flujo completo y muy bien, como MVP esta bien pero como producto final faltan detalles», solicitando cerrar la fase con un commit. La web usa Firebase real y el proxy Vite hacia Railway. Se verificaron página local 200 y respuesta protegida 401 desde Railway sin token.

Se compiló e instaló `dev.nndsk.MedicationTracker.staging` como copia iOS aislada. Android se compiló como `cl.nndsk.medication.staging`; ADB rechazó la instalación automática y el APK se entregó en Descargas del teléfono para instalación manual. Sus 15 tests pasaron; lint mostró cero errores y 22 advertencias preexistentes. Las copias nativas mantienen datos separados de desarrollo y push desactivado. La aceptación del usuario acredita su recorrido manual, no una ejecución exhaustiva de offline, concurrencia o notificaciones físicas.
