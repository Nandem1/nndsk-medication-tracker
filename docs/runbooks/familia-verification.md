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

## P5, inventario compartido

Resultados sobre la versión final:

- `make tokens-check`, `make test`, `make lint`, `make build`: PASS.
- `make test-integration`, base desechable nueva `medication_f1_familia_p5`: PASS. Incluye las 14 pruebas de la sección 9.9, además de salida sin saldo, propuesta pendiente, un solo paciente, reposición, umbral común y desfase de reloj.
- Migración 7, up, down y up en base desechable vacía: PASS. El down falla si ya existen movimientos `pool_transfer`, porque la historia es append-only.
- `make test-web-e2e`, `E2E_PORT_OFFSET=100`: 12 casos PASS. El puerto 5173 estaba ocupado por un proceso ajeno, que no se tocó.
- `make test-android`, `make lint-android`: PASS. `make test-android-device`: 8 pruebas PASS. `make test-android-e2e`: 3 casos PASS, en emulador.
- `make test-ios`: 83 pruebas en 18 suites PASS. `make lint-ios`: PASS. `make test-ios-e2e`: 11 casos PASS, 0 esperas de inactividad agotadas, en simulador.

**Alcance real de los E2E.** Android e iOS: el cuidador propone en la app, Mamá acepta en la app y sale en Ajustes. Android declara con `record()`, sin tocar los botones, e iOS mediante la API. El otro paciente acepta y consume mediante la API. Web: propone y sale en el portal; aceptar y consumir usan la API, porque el portal no decide por el paciente. Se usa un solo teléfono, y no hay dos pacientes operando en dos dispositivos. La carrera real entre pacientes está en integración. No se ejecutó en teléfonos físicos.

**Bug corregido: reloj adelantado.** El emulador recién iniciado iba 0,48 s adelantado y «Me lo tomé» terminaba como «Necesita revisión: datos rechazados». Ver [ADR 0009](../decisions/0009-modo-familia.md#desfase-de-reloj-en-declaraciones). La prueba falló antes del cambio y pasó después. La corrida de Android de las 21:57 lo reprodujo y la final pasó con el mismo emulador.

**Pruebas que cambiaron:**

- El caso `consentOffline…` de Android añade una pausa de 61 s. Con un caso más cambió el orden de JUnit y empezó a fallar al guardar el nombre, justo después de otro caso. La causa probable, sin confirmar en el log, es el límite de 120 solicitudes por minuto. No cambió lo que se exige.
- El helper de iOS que cierra el aviso de contraseña ahora excluye `pool-decline`, porque rechazaba la propuesta al tocar el «Ahora no» de la tarjeta.
- La elección local de uso admite hasta 6 reintentos de toque. No es una mutación de servidor.

**Capturas revisadas:** propuesta, candidatos, espera, compartido y salida en web, Android e iOS. Web corrigió un botón «Confirmar» sin contexto en la propuesta pendiente.

**Incidencias de entorno:**

- `make migrate-up` lee `.env`. Una ejecución por error migró la base local de desarrollo `medication_tracker` de la versión 5 a la 7. Es local, con 1 usuario y 0 dosis. Staging y producción no se tocaron.
- Colima y el emulador estaban detenidos al retomar. Se levantaron con los comandos del proyecto. El emulador sigue corriendo sin ventana (AVD `medication_f5`).

**Observaciones sin corregir:**

- Los movimientos de otros miembros parten en la activación, así que la lista puede no explicar todo el saldo común.
- En iOS, las decisiones pendientes viven en memoria: tras reabrir sin conexión no aparecen hasta sincronizar. Decidir exige red de todos modos.
- «Ahora no» rechaza la propuesta de forma definitiva. Volver a compartir requiere otra propuesta.
- En iOS, Hoy y Ajustes siguen diciendo «Saldo confirmado» y aclaran en una nota que es común. Android dice «Saldo común confirmado». Se mantuvo así para no cambiar la UI aceptada.

Architecture Impact: nueva migración y tablas, orden de bloqueo global, saldo efectivo, proyección combinada, privacidad en el servidor, cinco rutas nuevas y tolerancia de reloj en declaraciones. Mapas general y de las tres apps, contrato y ADR actualizados. Sin despliegue ni instalación física. Falta `living-architecture REVIEW`, previsto antes del último merge.

## P6, exportación y borrado de cuenta

Resultados en bases desechables nuevas `medication_f*_familia_p6`:

- `make tokens-check`, `make test`, `make lint`, `make build`, `make test-integration`: PASS. Migración 8, up, down y up: PASS.
- `make test-web-e2e`: 13 casos PASS.
- `make test-android-e2e`: 4 casos PASS, en emulador.
- `make test-ios`: 83 pruebas en 18 suites PASS. `make lint-ios`: PASS. `make test-ios-e2e`: 12 casos PASS, en simulador.

La corrida final, con todas las migraciones up, down hasta 0 y up, se repitió tras las correcciones de la revisión independiente.

Las pruebas de integración comprueban: confirmación obligatoria, salida de inventario con traspaso, historia ajena intacta, autor anonimizado, fila eliminada sin autoría, revocación auditada como cuidador, reintento, replay de terceros eliminado, reconciliación sin cambios y historia append-only fuera del borrado.

**Bug corregido: hoja de compartir en iOS.** Con `.sheet` sobre la `Section`, la hoja existía para XCTest pero no se veía en la captura, y la prueba pasaba igual. Se movió al botón, y la prueba ahora exige que siga abierta tras 3 s. Captura revisada: `mis-datos`, JSON, 5 KB, con «Guardar en Archivos». Otro caso de un E2E en verde que no significa que se vea bien.

**Otro ajuste visual.** En Android, la pestaña Pacientes usaba el icono de Historial.

**No verificado:**

- Quitar la identidad en un proyecto Firebase real. Requiere permisos de administración en la credencial de la API. Sólo se probó con el emulador y con un doble que falla.
- Contenido del archivo en un destino real. En Android, el E2E cierra el selector sin enviar.
- Si se pierde la respuesta tras eliminar la identidad, el reintento recibe 401. El teléfono conserva sus datos locales hasta cerrar sesión.

**Sigue pendiente, sin afirmar cumplimiento legal:** reaplicar supresiones después de restaurar un backup, caducidad de backups, aceptar la política de retención y revisión legal. La pantalla avisa que las copias pueden conservar datos.

Architecture Impact: nueva excepción controlada al append-only, ruta `DELETE /v1/me`, proveedor de identidad con baja y archivo temporal en clientes. Mapas y contrato actualizados. Sin despliegue en esta fase.

## Revisión independiente de P5 y P6

`living-architecture REVIEW` y revisión de corrección, panel de un solo modelo, sólo lectura, resultado PARTIAL. Se confirmaron y corrigieron cinco defectos. Los cuatro primeros tenían una prueba que falló antes del cambio; el quinto tiene una prueba propia que no reprodujo la carrera:

- Respuestas de replay de terceros conservaban nombres, ids o conteos de la persona eliminada.
- Una declaración simultánea al borrado podía interbloquear y recibir un conflicto espurio, porque tomaba filas antes del candado. Ahora toda mutación toma el candado primero, y la entrega de alertas también.
- Un id en mayúsculas podía dejar el traspaso en la propia cuenta. Los ids de cuenta se normalizan.
- Quien rechazó o salió de un inventario seguía viendo nombres. Ahora sólo los ven los miembros vigentes.
- Una petición entre el borrado y la baja en Firebase podía recrear una fila con el identificador. Se elimina tras la baja.

También se corrigió documentación desactualizada en el mapa general.

Sin corregir, porque el plan no lo define: una propuesta de un cuidador ya eliminado sigue aceptable, la exportación no incluye la membresía en inventarios y un inventario disuelto queda como fila vacía.

## P7, estado parcial

Staging en versión 8 con API y worker desplegados. Con la credencial `medication-staging-api`, una cuenta sintética real inició sesión (`/v1/me` 200), se eliminó (`identity_removed` true) y su token dejó de servir (401). iPhone físico: la app se instaló, pero no abrió porque el teléfono estaba bloqueado. Producción no se tocó.

Pendiente: escenario de aceptación de 12 puntos en teléfonos, copia del APK al Xiaomi (no conectado), repetir la revisión independiente y marcar `PLAN.md`. Queda en Firebase una cuenta `staging-smoke-*@example.test` de una prueba interrumpida.

## Mejoras de UI/UX de modo familia

Pedido por el usuario tras probar las apps. Implementado en la rama `feat/familia-ux`, sin desplegar y sin instalar en teléfonos físicos. Sólo cambia lo que añadió este plan, más el formato de cantidades en toda la web y el estado vacío de Hoy.

**Cambios.** Web: cantidades en es-CL («19.000» se leía como diecinueve mil), tarjetas simples, invitar y aceptar en pantallas separadas, acciones de inventario plegadas y columna Persona. Android: pestañas reales, menú del paciente, Acceso de cuidadores en pantalla propia, invitación con opciones simples, movimientos en la tarjeta, rechazos visibles dentro de la hoja de inventario y coma decimal. iOS: tarjetas simples, invitación con pasos siguientes, revisión al pegar, inventario con jerarquía y movimientos de más reciente a más antiguo. Web y Android unifican «Quitar acceso». Las tres plataformas ofrecen ingresar el código en el estado vacío o en Accesos.

**Corregido al revisar.** En Android, «Fecha de revisión» mostraba la fecha de sincronización. Un error de guardado de inventario quedaba oculto detrás de la hoja.

**Resultados en la versión final, con bases desechables `medication_f3_familia_ux`, `medication_f4_android_familia_ux` y `medication_f4_familia_ux`:**

- `make tokens-check`, `make test`, `make lint` y `make build`: PASS.
- `make test-web-e2e`: 13/13 PASS, con navegador, HTTP y PostgreSQL reales. Un primer intento dio 12/13 porque Vite recargó la página al optimizar una dependencia nueva en frío.
- `make test-android`, `make lint-android` y `make test-android-device`: PASS. `make test-android-e2e`: 4/4 PASS en emulador, también con modo oscuro y escala de fuente 1,3. Una corrida intermedia en oscuro falló esperando el saldo tras guardar una reposición, y no se reprodujo en las siguientes. La causa no se determinó.
- `make test-ios`: 84 pruebas PASS. `make lint-ios`: PASS. `make test-ios-e2e`: 12/12 PASS en simulador; después se amplió y repitió `testAcceptFullMessageAndRevokeNamedCaregiver`, que pasó. Los cinco flujos de familia también pasaron en modo oscuro con texto grande, antes de los últimos ajustes de orden en iOS.

**Capturas revisadas.** Web claro, oscuro, móvil y texto al 200 %. Android claro y oscuro con fuente 1,3. iOS claro y oscuro con texto grande. No hubo revisión manual con VoiceOver ni TalkBack.

**Decisión.** Ajustes de iOS conserva su orden aceptado. Su lista ya lleva a una pantalla propia de cuidadores, y Hoy ofrece el código cuando hace falta.

**Sin implementar:** «Invitación enviada, esperando autorización», porque necesita un endpoint nuevo.

Architecture Impact: nueva ruta web `/invite`, nueva pantalla Android `ui/settings/Access.kt`. Sin cambios en backend, contratos ni datos. Mapas de las tres apps actualizados.

