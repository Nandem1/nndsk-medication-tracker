# Segunda revisión con Opus 5.5

Revisión estática del código A/B/C antes de las correcciones finales. No ejecutó pruebas. Los hallazgos y su resolución se consolidan en el informe principal y el registro de decisiones.

# Revisión estática de A, B y C en la sincronización (iOS y Android)

**Modelo:** Opus 5.5, `claude-opus-5-5`.

Solo leí archivos: no edité nada, no ejecuté pruebas ni comandos y no abrí secretos ni `.env`. Leí el informe, `AGENTS.md`, `PLAN.md`, `SyncEngine.swift`, `AppModel.swift`, `LocalStore.swift`, `Repository.kt`, `SyncRequests.kt`, `RefreshTriggers.kt`, `MainActivity.kt`, `Api.kt`, `Identity.kt` y las pruebas nuevas.

**Contexto:** el informe describe A, B y C como propuesta, pero el worktree sin commit ya tiene las tres implementadas en ambas apps. Mi veredicto es sobre ese código. Su estado es **implementado, no validado** (las casillas de `PLAN.md` siguen sin marcar).

## Veredicto

| Entrega | Veredicto | Motivo |
|---|---|---|
| **A**: una sola sincronización en vuelo | **PASS con observaciones** | Agrupar solo la solicitud que todavía no empezó cumple la intención y respeta las correcciones del informe. |
| **B**: lecturas en paralelo | **PARTIAL** | La paralelización es correcta, pero en el sync completo de iOS hay un caso en que el saldo se descuenta dos veces. |
| **C**: refresco solo de lo afectado | **PARTIAL** | La selección por paciente y caja es correcta. Falla en la forma de reportar al usuario y en el estado que queda entre sesiones. |

**A en detalle:**
- iOS: `SyncEngine.syncWithFamilies` (`SyncEngine.swift:46-62`). Quien llama se une a `queuedSync` hasta que la tarea empieza; ahí se limpia y la siguiente llamada crea otro ciclo.
- Android: `SyncRequests.request` (`SyncRequests.kt:18-46`). Usa `begin()` dentro del mutex de `action` y `barrier()` en las mutaciones. Como el `Mutex` de kotlinx es FIFO, el orden se conserva.
- `isSyncing` (iOS) y `busy` (Android) cubren hasta el último ciclo.
- Las familias en iOS ya viajan dentro del ciclo.

## Riesgos

### Stock

1. **iOS, alto: un error de servidor queda tapado por una denegación** (`SyncEngine.swift:466-479`). En `drainQueue`, el resultado `.unavailable(.denied)` sobrescribe un `.server` anterior (un 5xx o 429 que deja la operación pendiente e incierta).
   - `run()` deja pasar `.denied` (`:161`) y luego `applyPatients` llama a `replaceInventory` para todos sin revisar pendientes.
   - Resultado: el saldo confirmado puede incluir esa operación, y `StockEstimate` la descuenta otra vez.
   - Contradice la corrección del informe «No se lee inventario tras un vaciado incierto».
   - Android no tiene el problema: `else -> throw e` (`Repository.kt:144`) y `blockedInventory()` protegen ese caso.
2. **iOS, medio: un aviso de error en el flujo normal.** Si la persona declara dos dosis seguidas, la segunda operación, que todavía no se envió, bloquea la lectura de la primera.
   - `refreshDueInventory` (`:398`) devuelve `.unavailable(.server)`, lo que muestra el problema de sincronización y programa un reintento hasta que la siguiente llamada lo limpia.
   - La prueba `newPendingOperationOfPoolMemberPreventsInventoryRead` (`SelectiveSyncTests.swift:66`) fija ese comportamiento.
   - Una operación con `attempts == 0` nunca salió del dispositivo, así que leer el inventario es seguro. El bloqueo solo hace falta con `attempts > 0`.
   - Android en el mismo caso omite la lectura en silencio, y está bien.
3. **iOS, bajo: membresía bloqueada por un pendiente.** En `.membership`/`.profiles`, el chequeo de pendientes (`:356`) bloquea el snapshot completo (tratamientos y dosis también), no solo el inventario. Aceptar una invitación con un pendiente propio de la misma caja termina en `.server`.

### Sesiones

4. **iOS, bajo: estado que sobrevive al cambio de cuenta.** `stop()` no limpia `inventoryDue`, `reportsDue`, `snapshotsDue` ni `conflictDaysDue`, y el motor es el mismo entre sesiones. Si la cuenta nueva comparte pacientes, por ejemplo en la misma familia, hereda lecturas pendientes. Es inocuo pero mezcla sesiones; conviene limpiarlo en `signOut` sin romper `failedConflictReadRetriesAfterEngineRestart…`.
5. **iOS, bajo: un error viejo puede pisar un éxito nuevo.** `AppModel.handle` no tiene la guarda de secuencia que sí tiene `applyFamilies`. Con varios llamadores que esperan ciclos distintos, un resultado viejo podría reponer `syncProblem` y su reintento. El orden de MainActor lo hace poco probable, pero no está garantizado.
6. **Android, medio: renovación forzada repetida.** Ante un 401, `Api.kt:40` llama a `token(force = true)` y `Identity.kt:122-124` renueva cada vez que entra al lock. Con las oleadas de B (hasta 3 + 4×4 peticiones), una revocación o desfase de reloj provoca hasta unas 19 renovaciones en serie. Se corrige renovando solo si el token rechazado sigue siendo el vigente.
7. **Android, bien:** las sincronizaciones de la sesión anterior se descartan (`invalidate()` + `begin()`), y `logout` toma el mutex, así que ninguna escritura llega tarde.

### Concurrencia y disparos en Android

8. **Medio:** `RefreshTriggers` (`RefreshTriggers.kt:6`, `MainActivity.kt:26-36`) solo recupera la conexión tras un ciclo `onLost` → `onAvailable`.
   - Quedan sin cubrir el cambio de red predeterminada sin `onLost` y los `IOException` con la red «disponible» (DNS caído, portal cautivo). Android no tiene el reintento con espera de iOS.
   - Cubre bien la carrera en que `onAvailable` llega antes de marcar `offline`, porque no depende de `state.offline`.
9. **Bajo:** al rotar la pantalla vuelve `ON_RESUME` y se sincroniza, aunque no es una vuelta a primer plano.
10. **iOS, bajo:** `watchNetwork` solo actúa si `syncProblem == .transport` ya está publicado. Si la red vuelve antes de eso, queda el reintento a los 15 s.

## Pruebas necesarias

**iOS: `apps/ios/MedicationTrackerTests/SelectiveSyncTests.swift`**
- `fullSyncKeepsInventoryWhenDenialFollowsServerError`: operación de «other» con 500 y luego operación de «unrelated» con 403; llamar a `engine.sync()`. Debe dejar el saldo de «other» en `20.000` y no hacer GET de `/other/inventory`. **Hoy debería fallar** (riesgo 1).
- `neverAttemptedOperationDefersInventoryWithoutServerProblem`: reemplaza la expectativa `.server` de `newPendingOperationOfPoolMemberPreventsInventoryRead`. Cambia el comportamiento esperado: una operación nunca enviada no es incierta.
- `membershipWithPendingOwnOperationStillLoadsNewPatient`.

**iOS: `apps/ios/MedicationTrackerTests/SyncCoordinationTests.swift`**
- `signOutClearsDueRefreshesBeforeNextOwner`: `stop` → `wipe` → `resume` con otra cuenta que comparte paciente; no debe haber GET de inventario ni de conflictos heredados.
- `@MainActor olderFailureDoesNotOverrideNewerSuccess`.
- `declarationBurstSubmitsAllAndReadsEachInventoryOnce`.

**Android: `app/src/androidTest/.../core/SelectiveSyncTest.kt`**
- `quickSecondDeclarationShowsNoErrorAndSecondActionRefreshes`.
- `serverErrorDuringDrainKeepsPoolInventoryInFullSync`: fija que Android hoy está bien.

**Android: `RepositorySyncTest.kt`**
- `logoutDuringParallelReadsWritesNoSnapshot`.

**Android: unitarias**
- `IdentityTest.concurrentForcedRefreshRenewsOnce`, en `app/src/test/.../core/`.
- `RefreshTriggersTest.availableWithoutLostDoesNotSync`: documenta el límite; el comportamiento real de la plataforma necesita un teléfono.

**Física y staging**
- Medir una sincronización real del cliente contra staging, como exige `PLAN.md`. La prueba de 7 en paralelo desde el Mac no la sustituye.

**Comandos**
- Comunes: `make tokens-check`, `make test`, `make lint`.
- iOS: `make test-ios`, `make lint-ios`, `make test-ios-e2e`.
- Android: `make test-android`, `make lint-android`, `make test-android-device`, `make test-android-e2e`. Gradle debe correr de verdad las tareas, no reutilizar resultados en caché como señala el informe.
- `make test-integration` no aplica, porque el contrato no cambia.

## Documentación desactualizada

El informe se contradice:
- La línea 3 dice que hay implementación autorizada, pero las líneas 24 y 242 dicen que nada es tarea activa y que no hay impacto en arquitectura.
- Las líneas 107 y 228 hablan de «máximo dos ciclos», en contra de la corrección de la línea 13.
- Los mapas `apps/*/docs/00-home.md` deben reflejar A, B y C antes del commit.

**Siguiente paso:** corregir los riesgos 1, 2 y 6, añadir las pruebas de arriba y correr las suites completas.
