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

## Pendiente

P1 a P7 no están implementadas ni verificadas. La aceptación completa exige los doce escenarios de PLAN-FAMILIA.md. Las pruebas manuales en teléfonos físicos siguen a cargo del usuario.
