# Estado y próximos pasos

Actualizado el 2026-11-06. La entrega de familias v2 se cierra por decisión del usuario para abordar los detalles encontrados al probar las apps.

## Estado actual

- Familias con roles, invitaciones por enlace/QR y misma caja implementadas en backend, web, iOS y Android.
- API y worker desplegados en staging con migración 9. Producción no se tocó.
- iPhone instalado y abierto; APK entregado en Descargas del Xiaomi. El usuario confirma haber probado ambas apps y reporta detalles por revisar, todavía sin enumerarlos.
- Verificación automatizada aprobada: iOS 88 unitarias y E2E 12/12; Android E2E 4/4 y dispositivo 8/8 en emulador; web E2E 13/13; integración Go con detector de carreras y checks comunes.
- [Evidencia y límites](docs/runbooks/familia-verification.md). La prueba general del usuario no acredita todos los escenarios físicos ni significa ausencia de defectos.

## Trabajo siguiente

El usuario autorizó revisar `docs/reviews`, contrastar el informe con el código, pedir una revisión a Opus 5.5 mediante Claude Code y corregir los problemas confirmados. El cierre incluye verificaciones, commit, push y worktree limpio. No incluye desplegar ni instalar en los teléfonos todavía.

### Sincronización de clientes

- [x] Contrastar el informe inicial con los motores y coordinadores de iOS y Android.
- [x] Obtener y contrastar la [revisión independiente de Opus 5.5](docs/reviews/2026-11-06-sync-opus.md). El CLI confirma `claude-opus-5-5`; fue una revisión estática.
- [x] A: agrupar solicitudes pendientes sin devolver antes del ciclo que las cubre, conservar la cola serial y eliminar disparos redundantes de Android.
- [x] B: paralelizar lecturas independientes, conservar paginación secuencial y autorización por paciente, omitir el resumen propio.
- [x] C: refrescar sólo los recursos afectados por declaraciones, perfil, familia e inventario; conservar saldo confirmado y resumen ajeno actuales.
- [x] Ejecutar checks comunes y suites completas de ambas apps.
- [x] Actualizar mapas locales y consolidar informe con evidencia y límites.
- [x] Revisar el diff completo, hacer commit y push y comprobar que el worktree queda limpio. Evidencia: `894c7ef` publicado en `origin/main`, sin diferencias local/remoto ni cambios pendientes antes de este cierre documental.

La agrupación no tiene un máximo global de dos ciclos: las solicitudes durante el segundo pueden necesitar un tercero. Tras vaciar declaraciones de varios pacientes, se renuevan los inventarios y los resúmenes ajenos de todos los afectados. Nunca se copia el saldo histórico del resultado idempotente al inventario.

El trabajo se divide por plataforma después de consolidar la revisión. Cada plataforma conserva sus pruebas de sesión, cola durable y stock; los checks de dispositivo se ejecutan sin competir por el mismo simulador o emulador.

## Pendientes conservados

- Instalar esta entrega en iPhone y Android físicos y medir el cliente contra staging. Los transportes controlados y E2E locales no acreditan latencia real.

- Familia offline en iOS: la lista vive en memoria y no se recupera al reabrir sin red.
- Push remoto APNs/FCM real, pruebas físicas específicas de offline, concurrencia, notificaciones, batería y accesibilidad. Ver [release y pendientes de F8](docs/runbooks/f8-release.md).
- Operación y lanzamiento: CI remoto, restore cloud/PITR, observabilidad remota, retención y tratamiento de backups. Los requisitos detallados permanecen en los runbooks; este cierre no declara preparación para producción ni cumplimiento legal.
- Limpieza del cierre: retirar las bases desechables `*_familia_v2` y apagar sólo los recursos de prueba que corresponda. No afecta staging ni datos del teléfono.

## Dónde consultar

- [AGENTS.md](AGENTS.md): reglas vigentes de colaboración y dominio.
- [Mapa general](docs/00-home.md): arquitectura implementada y enlaces a cada app.
- [ADR 0010](docs/decisions/0010-familia-como-modelo.md): decisiones actuales de familia; sustituye las decisiones indicadas de ADR 0009.
- [Desarrollo](docs/runbooks/development.md) y [staging](docs/runbooks/railway-staging.md): comandos y operación.
- [Planes históricos](docs/archive/plans/README.md): antecedentes, no tareas activas ni autorización automática para trabajo nuevo.
