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

P2 a P7 no están implementadas ni verificadas. La aceptación completa exige los doce escenarios de PLAN-FAMILIA.md. Las pruebas manuales en teléfonos físicos siguen a cargo del usuario.
