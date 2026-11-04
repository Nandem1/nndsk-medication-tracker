# Verificación de modo familia

## P0

Preparación ejecutada el 2026-11-03 desde `main` en `0df13f7`. El punto de partida incluye el commit del plan posterior a `6219d33`. Rama `feat/modo-familia` creada.

El ADR 0009 registra las decisiones cerradas y el diseño previsto de inventario compartido. Las referencias de F5b, F5c y F8b ya estaban en PLAN.md y no se duplicaron. Ningún checkbox funcional se marcó.

El selector de instalación iOS admite únicamente filas `physical`, con estado exacto `connected` o `available`. Conserva el override `IOS_DEVICE`. La inspección real encontró un simulador conectado y un iPhone físico emparejado disponible. El selector corregido encontró el físico sin instalar ni abrir la app.

Comandos y resultados sobre el cambio final:

- `sh -n scripts/ios-run-device.sh`: PASS.
- Selector AWK extraído del script contra cuatro filas sintéticas: PASS para simulador conectado, físico conectado, físico disponible y físico no disponible. Una primera variante confundía `unavailable` con `available`; la comparación exacta corrigió ese fallo.
- `xcrun devicectl list devices` con el filtro final: PASS, encontró un físico disponible.
- `make tokens-check`: PASS.
- `make test`: PASS, Go con detector de carreras y 21 pruebas web.
- `make lint`: PASS, tokens, Go vet y TypeScript.
- `git diff --check`: PASS.

Herramientas comprobadas: Go 1.27.3, Node 22.23.4, pnpm 12.15.0, Docker servidor 29.5.2, Xcode 27.2, XcodeGen 2.46.0 disponible, JDK 21.0.13, SDK Android en `android-37.0`, ADB con emulador disponible y Railway CLI 5.71.0. ADB no está en PATH, pero está en `.tmp/android-sdk/platform-tools/adb`.

El sandbox impidió inicialmente escribir referencias Git y consultar Docker y CoreDevice. Las mismas comprobaciones con permisos elevados funcionaron. No se cambiaron configuraciones globales.

Una revisión independiente del mismo modelo no encontró defectos bloqueantes en P0. No repitió las pruebas del ejecutor. El registro de decisiones está en [familia-decisions.tsv](familia-decisions.tsv).

Architecture Impact: P0 no cambia límites, contratos ni dominio en ejecución. El ADR describe cambios futuros. No hubo migraciones, despliegues ni instalación de apps. Las pruebas nativas y E2E de producto no se ejecutaron en P0.

## P1

Perfiles con nombre nullable, versión y auditoría implementados. La edición propia y con alcance `treatments` conserva idempotencia y vuelve a autorizar antes del replay. Las invitaciones aceptan un nombre sugerido y lo aplican en la transacción de aceptación sólo si el perfil está incompleto. Los listados y la exportación respetan esa nulabilidad.

Agenda e informe reintentan la transacción completa hasta tres veces, con espera cancelable de 50 a 200 ms. Conservan el SQLSTATE hasta clasificar errores. Unicidad sólo se reintenta en materialización. La prueba de 16 GET concurrentes produjo nueve 409 con un único intento y pasó al restaurar tres.

Validación sobre el código final:

- `make tokens-check`, `make test`, `make lint`: PASS.
- `make test-integration`, con `TEST_DATABASE_URL` hacia `medication_f1_familia_p1`: PASS. PostgreSQL real, HTTP local e identidad sintética.
- Migración `00006_profiles.sql` up, down y up en esa base desechable: PASS. Estado final versión 6.
- Pruebas de permisos, versión vieja, idempotencia concurrente, Unicode, nombres sugeridos, revocación por cuidador y exportación sin placeholder: PASS.
- Revisión independiente detectó exposición de nombre tras revocar y NUL aceptado que causaba 500. Las pruebas reprodujeron ambos fallos antes de corregirlos. La suite final pasa y la revisión confirmó los fixes por lectura.
- `git diff --check`: PASS.

Los cambios en pruebas anteriores sólo actualizan la firma de creación de invitación con hint opcional explícito. No cambian sus resultados esperados. Se corrigió además una divergencia previa de OpenAPI: `Link.status` admitía sólo `active`, aunque el endpoint entrega también vínculos revocados. Ahora enumera los tres estados de la base.

Architecture Impact: cambian esquema, contrato, autorización de perfiles y reintentos de lecturas. El mapa general documenta esos cambios. No cambian clientes ni proveedores. No se desplegó P1 ni se migró staging. El trigger append-only de perfiles se tendrá que considerar junto con los existentes al implementar P6.

## Pendiente

P4 a P7 no están implementadas ni verificadas. La aceptación completa exige los doce escenarios de PLAN-FAMILIA.md. Las pruebas manuales en teléfonos físicos siguen a cargo del usuario.

## P2

El portal incorpora registro y recuperación, perfil inicial obligatorio y edición versionada. Las tarjetas, cabeceras y consentimiento muestran nombres sin UUID visibles. Las invitaciones tienen permisos predefinidos, nombre sugerido, copia de código o mensaje y pegado del mensaje completo. La vista conjunta muestra conteos de la API con fecha, zona y denominador.

Se añadió `timezone` a `PatientAccess`, leyendo el valor que ya guarda `users`. Es una diferencia respecto del detalle del plan necesaria para usar el día del paciente. La primera implementación lo infería del primer tratamiento; la revisión detectó que un tratamiento archivado podía desplazar el día. El campo explícito elimina esa inferencia y evita una consulta por tarjeta.

Comandos y evidencia final:

- `make tokens-check`, `make test`, `make lint`, `make build`: PASS, incluidas 24 pruebas unitarias web. Build conserva advertencias previas de Vite sobre directivas de dependencias y tamaño del bundle.
- `make test-integration` en base desechable local: PASS, incluida exposición de zona del paciente.
- `FAMILIA_TEST_DB=medication_f3_familia_p2 E2E_PORT_OFFSET=100 make test-web-e2e`, con conexión local inyectada sin imprimirla: 11 de 11 PASS.
- Los E2E usan navegador, HTTP y PostgreSQL reales, con identidad sintética. No acreditan registro remoto ni entrega de correo Firebase.
- La suite inicial agotó el límite de 120 peticiones por minuto, confirmado como 429 en trace. El runner inicia API y Vite por caso, sin modificar el límite productivo.
- Los tests previos se adaptaron a nombres y onboarding, conservando sus aserciones funcionales. Nuevos casos prueban cuentas, recuperación genérica, consentimiento con nombre, replay y conflicto del editor, salida y recarga del onboarding.
- Capturas reales revisadas por implementador y coordinador en `/private/tmp/familia-p2-{account,onboarding,invitation,patients,patients-mobile}.png`. Se corrigieron radios afectados por estilos de campos de texto y se repitieron las capturas. No se observó desbordamiento horizontal móvil.
- CI web Linux detectó rutas de capturas `/private/tmp` no portables. Se sustituyeron por `test.info().outputPath`, que usa el directorio de resultados de Playwright. Checks comunes y los 11 E2E locales volvieron a pasar; no cambiaron aserciones ni comportamiento de producto. El commit `64921c7` pasó [CI web Linux](https://github.com/Nandem1/nndsk-medication-tracker/actions/runs/41758597580) y [escaneo de secretos](https://github.com/Nandem1/nndsk-medication-tracker/actions/runs/41758597994).
- Revisión independiente final: PASS para zona y limpieza del error de sesión. Revisión de código, sin repetir suites.

Architecture Impact: cambian sesión y navegación web, lectura del perfil y presentación de métricas. El contrato expone la zona existente, sin migración nueva. Mapas general y web actualizados. Sin despliegue ni instalación nativa.

## P3.1, separación Android

`PatientApp.kt` se dividió en diez archivos de navegación, cuenta, Hoy, detalle, Ajustes y componentes. Las 29 funciones conservan firmas y cuerpos; sólo cambian paquetes, imports y visibilidad de funciones compartidas. Una revisión independiente confirmó esa equivalencia. El mapa Android enlaza las nuevas ubicaciones.

`make test-android`, `make lint-android`, `make test-android-device` y `make test-android-e2e`: PASS. Siete tests de dispositivo y un E2E con API, PostgreSQL y Firebase Auth emulado. El E2E pasó antes y después del movimiento. Las capturas `/private/tmp/familia-p3-before.png` y `/private/tmp/familia-p3-after.png`, revisadas por implementador y coordinador, conservan disposición y textos; cambian las horas de los fixtures.

Los checks comunes `tokens-check`, `test` y `lint` pasaron. La repetición en raíz requirió acceso elevado a caché Go tras un error de permisos del sandbox. No se modificaron expectativas de pruebas ni comportamiento. Esta verificación usa emulador, no teléfono físico.

Architecture Impact: separación interna, sin cambios de límites, contratos ni reglas. P3 funcional sigue pendiente. Este refactor tiene su propio commit antes de añadir modo cuidador.

## P3, modo cuidador Android

La app separa agenda propia, pacientes y operaciones globales por propietario. Envía las colas antes de refrescar cada paciente secuencialmente. Un rechazo de acceso retira sólo ese snapshot y conserva los registros locales como `denied`. La planificación y la entrega de alarmas exigen agenda propia.

Se añadieron cuenta y onboarding, preferencia local de uso, invitaciones con nombre y permisos, consentimiento, tarjetas con métricas API, detalle cuidador e inventario. Las declaraciones y correcciones ajenas usan tercera persona. Reposición y conteo requieren conexión y conservan su clave de reintento.

La revisión independiente encontró llamadas nuevas que no expiraban la sesión ante 401 y textos de corrección en primera persona. Una segunda revisión confirmó sus correcciones por lectura, la retirada de pacientes ante 403/404 y el mapa Android actualizado. No sustituyen las pruebas de ejecución.

Comandos y evidencia final:

- `make tokens-check test lint`: PASS en el worktree y después de integrar en raíz. Incluye Go con race y 24 pruebas web.
- `make test-android`: 33 PASS. `make lint-android`: PASS debug y release.
- `make test-android-device`: ocho pruebas PASS en emulador, incluidas persistencia tras revocar sólo un paciente y bloqueo de una alarma ajena antigua.
- `make test-android-e2e`: dos casos PASS sobre la versión final. Usa UI Compose, API, PostgreSQL y Firebase Auth emulado. No acredita entrega real de correo ni ejecución en teléfono físico.
- El flujo familiar prueba registro, onboarding, invitación con nombre y mensaje completo, dos pacientes, lectura sin acciones, declaración cuidadora, conflicto, escritura durante red retenida, revocación y restauración offline. Reposición y conteo pierden una respuesta real, reintentan los mismos bytes y conservan un único efecto y saldo exacto.
- CI Android falló antes de compilar porque `sdkmanager` no estaba en PATH. El workflow usa ahora su ruta bajo `ANDROID_HOME`, conforme al [instalador del runner](https://github.com/actions/runner-images/blob/main/images/ubuntu/scripts/build/install-android-sdk.sh). La siguiente ejecución encontró la herramienta pero no `platforms;android-37`. Se fijan Command-line Tools 22.0 y `platforms;android-37.0`, publicados en el catálogo oficial. YAML y checks comunes locales pasan. El commit `2a6afe0` pasó [CI Android Linux](https://github.com/Nandem1/nndsk-medication-tracker/actions/runs/41762743367) y el escaneo de secretos. Build, unitarias y lint corrieron en el runner.
- `go test -tags=e2e ./cmd/e2e`: PASS. El proxy de prueba ahora descarta también respuestas POST de inventario; antes sólo cubría dosis. El fixture espacia bloques para respetar 120 solicitudes por minuto. No se cambió el límite productivo.
- Capturas reales revisadas por implementador y coordinador en `/private/tmp/familia-p3-captures/`. Se corrigió el aviso rojo de recuperación exitosa y se volvió a capturar con tono informativo. La captura de pendientes es parcial; su conservación y estado se verifican mediante assertions.
- Los fixtures de recordatorios previos usaban un actor distinto del paciente para representar agenda propia. Se corrigió esa identidad y se añadieron pruebas explícitas de agenda ajena; no cambió la expectativa de entrega propia.
- Revisión independiente de fixes: PASS por lectura. Living Architecture REVIEW detectó una frase antigua sobre `offline`; se corrigió y el coordinador comprobó su correspondencia con el código. `git diff --check`: PASS.

Architecture Impact: cambian estado local, autenticación y navegación Android. Room conserva su esquema; snapshots añaden perfil, accesos y métricas. Contrato productivo, reglas de consumo e infraestructura sin cambios. Mapas general y Android actualizados. No desplegado ni probado en teléfono físico.

## P4, referencia previa

Antes de implementar se ejecutó `make test-ios-e2e` con base desechable `medication_f4_familia_p4`, simulador iPhone 17 con iOS 27.2 y Firebase Auth emulado. Las siete pruebas pasaron. Incluyen declaración offline, Dynamic Type máximo, tardía y corrección, entrega de recordatorio sin declaración, conflicto, revocación y limpieza de sesión. Log en `/private/tmp/familia-p4-baseline.log`; capturas exportadas en `/private/tmp/familia-p4-baseline-captures/`. No es prueba en iPhone físico. P4 sigue en implementación.

## P4, entrega en curso al 2026-11-04

El usuario pidió finalizar la sesión y documentar los pendientes para Claude Opus 5.5. El candidato iOS queda integrado sin commit en `feat/modo-familia`. Se compararon sus 34 archivos byte a byte con el worktree entregado. `git diff --check` pasó. No se cerró P4 ni se iniciaron P5, P6 o P7.

SQLite separa datos por paciente y conserva la cola global. La revocación retira sólo la caché afectada y mantiene operaciones rechazadas. La revisión encontró carreras entre respuestas antiguas, cambios de cuenta y reintentos 401; se corrigieron con generación de sesión, parada de sincronización y autorización de cada solicitud en su sesión original. Nuevas pruebas reproducen esas carreras con transporte controlado. Esto no sustituye E2E.

Checks comunes, lint iOS y 82 unitarias en 17 suites pasaron antes del diagnóstico final de UI. La revisión independiente estática y Living Architecture REVIEW dieron PASS. Logs en `/private/tmp/familia-p4-final-common.log`, `/private/tmp/familia-p4-final-unit.log` y `/private/tmp/familia-p4-final-lint-ios.log`.

El intento completo de E2E falló al interactuar con onboarding después del aviso de guardar contraseña. Se comprobó una ventana transitoria que capturaba el toque y una discrepancia posterior entre hit-test UIKit y accesibilidad XCTest. Se retiraron los experimentos de navegación, foco e instrumentación. El helper de FamilyFlow usa coordenadas y observa el teclado para comprobar foco. El caso `testAcceptFullMessageAndRevokeNamedCaregiver` pasó sin relanzar, 1 test en 48,883 segundos, log `/private/tmp/familia-p4-physical-focus.log`. La pausa inicial de 61 segundos se restauró después; no se repitió la suite por la orden de finalizar.

## P4, cierre

Resultados sobre la versión final, en simulador iPhone 17 con iOS 27.2, API y PostgreSQL reales y Firebase Auth emulado:

- `make tokens-check`, `make test`, `make lint`: PASS.
- `make test-ios`: 82 pruebas en 17 suites PASS. `make lint-ios`: PASS.
- `make test-ios-e2e`: 10 casos PASS, 0 fallos, 0 esperas de inactividad agotadas. Log `/private/tmp/familia-p4-final2-e2e.log`.
- `git diff --check`: PASS.

**Bug de producto corregido.** Tras revisar una invitación, «Autorizar a este cuidador» podía quedar bajo la barra de pestañas y el toque no llegaba al botón. Falló en 2 de 10 casos en la penúltima corrida, y esas dos invitaciones seguían sin consumirse en la base. `ConsentView` ahora desplaza el botón a la vista, y `PatientFlowUITests` exige que quede sobre la barra.

**Textos corregidos.** Punto doble en la cobertura del inventario y fila «Uso» redundante en Mi perfil.

**Pruebas que cambiaron, sin cambiar el comportamiento esperado de la app:**

- PatientFlow usa el mismo foco por coordenadas que FamilyFlow. Sólo repite toques de foco y de elección local de uso, nunca una mutación de servidor.
- Se cierra el aviso «¿Guardar contraseña?» antes de cada reintento, porque puede llegar tarde.
- Al registrar, se cierra la oferta de contraseña segura de iOS, que se llevaba lo escrito. Se exige envío habilitado. AutoFill sigue activo.
- Tras relanzar, se busca la fila con «Guardada, falta enviar». La dosis pendiente pasa a «Ya registradas», así que la primera fila era otra dosis.
- El conflicto se busca por prefijo, porque el texto real es «Necesita revisión: cambió en el servidor».
- La hoja de compartir ahora se exige abierta y con el mensaje completo. Antes la captura no la esperaba.
- Volver a la raíz de Pacientes tolera que ya no exista botón atrás.

**Comparación visual.** Capturas contra el baseline: Hoy, detalle, hoja tardía, pendiente offline y texto máximo sin cambios de diseño. «(hora de GMT)» sólo aparece en el baseline porque el fixture elige la zona según la hora del día. Historial no tenía captura en el baseline: se añadió una, revisada sin problemas, y su código sólo cambió el cálculo de días. Pantallas nuevas revisadas: Pacientes, detalle cuidador, inventario, conflicto, consentimiento, Mi perfil, invitación, hoja de compartir, recuperación y revocación selectiva. Capturas en `/private/tmp/familia-p4-c-attfull/` y `/private/tmp/familia-p4-final2-att/`.

**Observaciones sin corregir:**

- Una corrida tuvo 15 esperas de inactividad de 60 s tras enfocar `invitation-token`, y su caso tardó 1.017 s. No se repitió en las seis corridas posteriores. La primera de ellas usó el mismo código de app. Causa no determinada.
- `SettingsView.swift:75` puede mostrar punto doble en «Cubren hasta». Es anterior a P4.
- Los movimientos de inventario se ordenan por UUID (`portal.go`), así que su orden en pantalla no es cronológico. Es anterior a P4.
- Tras una revocación, el aviso rojo no dice qué paciente se perdió.
- No se ejecutó en iPhone físico. No acredita entrega real de correo ni revisión con VoiceOver.

Architecture Impact: cambian persistencia, sincronización, autenticación y navegación iOS. Conserva los contratos y las reglas de consumo. Mapas general e iOS actualizados. Sin despliegue ni instalación física.
