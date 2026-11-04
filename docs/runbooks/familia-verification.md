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

P3 a P7 no están implementadas ni verificadas. La aceptación completa exige los doce escenarios de PLAN-FAMILIA.md. Las pruebas manuales en teléfonos físicos siguen a cargo del usuario.

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
- CI web Linux detectó rutas de capturas `/private/tmp` no portables. Se sustituyeron por `test.info().outputPath`, que usa el directorio de resultados de Playwright. Checks comunes y los 11 E2E locales volvieron a pasar; no cambiaron aserciones ni comportamiento de producto.
- Revisión independiente final: PASS para zona y limpieza del error de sesión. Revisión de código, sin repetir suites.

Architecture Impact: cambian sesión y navegación web, lectura del perfil y presentación de métricas. El contrato expone la zona existente, sin migración nueva. Mapas general y web actualizados. Sin despliegue ni instalación nativa.

## P3.1, separación Android

`PatientApp.kt` se dividió en diez archivos de navegación, cuenta, Hoy, detalle, Ajustes y componentes. Las 29 funciones conservan firmas y cuerpos; sólo cambian paquetes, imports y visibilidad de funciones compartidas. Una revisión independiente confirmó esa equivalencia. El mapa Android enlaza las nuevas ubicaciones.

`make test-android`, `make lint-android`, `make test-android-device` y `make test-android-e2e`: PASS. Siete tests de dispositivo y un E2E con API, PostgreSQL y Firebase Auth emulado. El E2E pasó antes y después del movimiento. Las capturas `/private/tmp/familia-p3-before.png` y `/private/tmp/familia-p3-after.png`, revisadas por implementador y coordinador, conservan disposición y textos; cambian las horas de los fixtures.

Los checks comunes `tokens-check`, `test` y `lint` pasaron. La repetición en raíz requirió acceso elevado a caché Go tras un error de permisos del sandbox. No se modificaron expectativas de pruebas ni comportamiento. Esta verificación usa emulador, no teléfono físico.

Architecture Impact: separación interna, sin cambios de límites, contratos ni reglas. P3 funcional sigue pendiente. Este refactor tiene su propio commit antes de añadir modo cuidador.
