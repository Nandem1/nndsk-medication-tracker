> Archivo histórico. Conserva decisiones, autorizaciones y evidencia de su etapa; sus instrucciones de ejecución y estados no son una cola vigente. Consulta el [estado actual](../../../PLAN.md) y las [reglas vigentes](../../../AGENTS.md).

# PLAN-FAMILIA-2.md — La familia como modelo

> **Estado al 2026-11-06:** fases 1 a 5 implementadas y verificadas en local en `feat/familia-v2`. Código integrado y subido a `main` y `feat/familia-v2`; staging migrado a v9 con API y worker verificados. Avisado el usuario antes de instalación iPhone y generación APK, que siguen pendientes. Decisión en [ADR 0010](../../decisions/0010-familia-como-modelo.md).
> **Origen:** el usuario pidió en esta sesión reemplazar los vínculos uno a uno por familias, y aprobó la recomendación completa.
> **Regla de lectura:** este plan reabre, por decisión explícita del usuario, las decisiones D2, D4 y D7 de [`PLAN-FAMILIA.md`](PLAN-FAMILIA.md). El resto de `AGENTS.md`, `PLAN.md` y `PLAN-FAMILIA.md` sigue vigente.

## 1. Problema

Con 3 cuidadores y 2 pacientes hacían falta 6 vínculos, y cada padre pegaba 3 códigos de 43 caracteres. Esa es la parte más difícil para un adulto mayor.

## 2. Decisiones

| # | Decisión |
|---|---|
| G1 | **Todo es una familia.** Una persona crea una familia y queda como administradora. Un cuidador con un solo paciente es una familia de dos. |
| G2 | **Los vínculos se derivan de la pertenencia.** `caregiver_links` deja de crearse a mano: se recalcula en la misma transacción que cambia la familia. La autorización de cada endpoint, las alertas, la exportación y el borrado siguen leyendo los vínculos sin cambios. Es el cambio más pequeño que conserva el modelo de autorización ya probado. |
| G3 | **Roles por familia:** `admin` (todo, más invitar y quitar), `caregiver` (ver, registrar tomas e inventario), `observer` (sólo mirar) y `patient` (sus propios datos). Un paciente no ve los datos de otro paciente. |
| G4 | **El paciente consiente una vez, al unirse.** Ve quién está en la familia, recibe aviso de quién se une y puede salir cuando quiera. Los cuidadores nuevos heredan a los pacientes sin otra aprobación. |
| G5 | **Ingreso por enlace o QR, con el código como respaldo.** El enlace usa el esquema propio `mistomas://unirse#<token>`. El token va en el fragmento, nunca llega a un servidor por la URL y se canjea por POST. Las invitaciones son de un solo uso, con rol, y vencen en 7 días. Reemplaza D4. |
| G6 | **Misma caja.** Quien tenga alcance `inventory` sobre ambas cuentas marca «Usan la misma caja» y el inventario queda activo de inmediato, con un conteo físico obligatorio en la misma transacción. Desaparecen las propuestas pendientes. Cada paciente puede separarse. Reemplaza D7. |
| G7 | **La familia nunca queda sin administración.** Si sale la última persona administradora y quedan cuidadores, asume el cuidador más antiguo. Las familias no se borran: conservan su historia. |
| G8 | **Una persona puede estar en varias familias.** El vínculo resultante une los alcances de todas. |
| G9 | Se retiran `POST /v1/invitations`, `/v1/invitations/preview`, `/v1/invitations/accept`, `GET /v1/caregiver-links` y `DELETE /v1/caregiver-links/{id}`. Las preferencias de alerta siguen por vínculo. |
| G10 | **Datos:** local y staging son de prueba. La migración revoca los vínculos sin familia y disuelve las propuestas pendientes. Producción no se toca. |

## 3. API

| Método | Ruta | Uso |
|---|---|---|
| GET | `/v1/families` | Familias del actor, con miembros, roles y fecha de ingreso |
| POST | `/v1/families` | `{client_operation_id, name}`; el actor queda `admin` |
| POST | `/v1/families/{familyId}/invitations` | `{client_operation_id, role, patient_name_hint?}`; sólo `admin` |
| POST | `/v1/family-invitations/preview` | `{token}`: familia, quien invita, rol, miembros y vencimiento |
| POST | `/v1/family-invitations/accept` | `{client_operation_id, token}`; idempotente |
| DELETE | `/v1/families/{familyId}/members/{userId}` | Salir, o quitar si el actor es `admin` |
| POST | `/v1/inventory-pools` | `{client_operation_id, account_ids, counted_account_id, counted_quantity}`; queda `active` |

## 4. Fases

1. **Backend:** migración `00009_families.sql` reversible, servicio, HTTP, contrato, DTO y pruebas de integración escritas primero.
2. **Pruebas más rápidas:** límite de solicitudes configurable sólo en los servidores E2E, sin las esperas de 61 s y con servidores web compartidos.
3. **Web:** familia, invitación con enlace, ingreso, misma caja y la renovación visual pedida.
4. **Android** y 5. **iOS:** familia, ingreso por enlace o código, QR para configurar en persona, aviso de miembros nuevos y misma caja.
6. **Cierre:** staging migrado y desplegado, instalación en el iPhone y documentación.

## 5. Pruebas obligatorias (antes de los handlers)

Crear familia; invitar con cada rol; sólo `admin` invita y quita; aceptar es idempotente y de un solo uso; token vencido o ajeno da conflicto; el paciente une a los cuidadores existentes y un cuidador nuevo hereda a los pacientes; `observer` sólo lee; un paciente no lee a otro; salir revoca; quitar revoca; promoción del último `admin`; unión de alcances con dos familias; BOLA/IDOR entre familias; misma caja activa con conteo exacto, decimales exactos y concurrencia con consumo.

## 6. Fuera de alcance

Cambiar el rol de un miembro (se quita y se vuelve a invitar), permisos distintos por paciente dentro de una familia, enlaces universales con dominio propio y push real.

## Traspaso a Codex (2026-11-05)

Rama `feat/familia-v2`. Commits hechos: backend (`72c1602`), web (`4712735`), Android (`38e29eb`). **Sin commit todavía:** iOS completo (familia, unirse, QR, misma caja, pruebas), mover el aviso «Nuevo en…» al final de Hoy en iOS y Android, ADR 0010, mapas y la regla de tokens de `AGENTS.md`.

Estado verificado en local: integración Go con `-race` PASS, web E2E 13/13, Android E2E 4/4 (antes del último cambio en Hoy), iOS unitarias PASS y E2E 11/12. El que faltaba, `testCaregiverCreatesPatientConfirmsOfflineAndStockDropsOnce`, debería pasar con el aviso movido al final.

Pasos pendientes, en orden:
1. Revisar `/private/tmp/claude-501/*/tasks/blm9rwm0c.output`, o repetir: `make lint-ios`, `make test-ios`, `make test-ios-e2e` (destino predeterminado, nunca `id=`), `make test-android`, `make lint-android`, `make test-android-e2e`. Bases desechables ya migradas a la versión 9: `medication_f4_familia_v2` (iOS), `medication_f4_android_familia_v2`, `medication_f3_familia_v2` (web) y `medication_f1_familia_v2` (integración). Usar `.tmp/familia-db-run.py` con `FAMILIA_TEST_DB`.
2. Corregir lo que falle, sin cambiar la intención de las pruebas, y correr `make tokens-check test lint build`.
3. Commit de iOS y docs, con la atribución del entorno. Merge a `main` (autorizado). Push de `main` y `feat/familia-v2` (autorizado por el usuario en esta fase).
4. Staging (autorizado y destructivo si hace falta): aplicar la sección Up de `infrastructure/migrations/00009_families.sql` y registrar la versión 9 en `goose_db_version`. El Postgres de Railway no tiene URL pública: usar `railway ssh --service Postgres` con la llave `~/.ssh/id_ed25519.pub`, registrada sólo durante la migración (`railway ssh keys add` y luego `remove`). Después `railway up` de API y worker según `docs/runbooks/railway-staging.md`, y comprobar `/healthz`, `/readyz` y 401 sin token. No imprimir URLs ni secretos.
5. Instalar en el iPhone: `IOS_DEVICE=00008160-0016796C1EA0000A make run-ios-device`. APK de staging para Android según la sección 11 de `PLAN-FAMILIA.md`.
6. Registrar la evidencia en `docs/runbooks/familia-verification.md`, marcar el estado de este plan y cerrar con un informe: cambios, comandos, pruebas, pendientes (push real, prueba en teléfonos físicos y la familia sin conexión en iOS, que no se guarda en disco).

Al terminar: apagar el emulador (`adb -s emulator-5554 emu kill`), el simulador y Colima si se iniciaron, y borrar las bases `*_familia_v2`.

**Resultado de la verificación final (antes del commit):**

```
ios-lint=0
ios-unit=0
✔ Test run with 87 tests in 19 suites passed after 0.297 seconds.
ios-e2e=0 secs=984
passed=12 failed=0
and-unit=0
and-lint=0
and-e2e=2 secs=165
Tests run: 4,  Failures: 1



[exited with code 0]
```

## Continuación Codex, 2026-11-06

Verificación final PASS: iOS lint y 88 unitarias, E2E 12/12; Android unitarias, lint, dispositivo 8/8 y E2E 4/4 en emulador; web E2E 13/13; integración Go con race; tokens-check, test, lint y build. Se corrigió la espera de publicación del E2E Android y la migración iOS v1→v2 para conservar cola y propietario, retirando sólo links. Regresión roja antes y verde después; revisión independiente focal PASS. Evidencia en `docs/runbooks/familia-verification.md`.

Git: commit `7f4bb8a`, merge fast-forward y push de ambas ramas completados. Staging: migración 9 aplicada en transacción con control previo de versión 8; clave SSH temporal retirada. API y worker SUCCESS; healthz/readyz 200 y me/families sin token 401. Producción no se tocó. Pendientes: paso 5, cierre físico y limpieza final del paso 6.

Instalación iPhone completada el 2026-11-06 por pedido explícito: build, instalación y apertura PASS; bundle apuntando a staging. Pendientes generación APK, pruebas físicas funcionales y limpieza final.

APK de staging generado y entregado en Descargas del Xiaomi el 2026-11-06; configuración y SHA-256 verificados. Instalación Android manual y aceptación funcional física pendientes.
