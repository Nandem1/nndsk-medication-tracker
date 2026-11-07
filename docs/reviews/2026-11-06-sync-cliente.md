# Revisión y corrección de la sincronización móvil

Estado al 2026-11-06: implementación A/B/C validada localmente. Cierre de Git en curso. No se desplegó ni se instaló esta versión en teléfonos físicos.

El usuario autorizó contrastar el borrador con el código, consultar a Opus 5.5 y corregir los problemas confirmados. El seguimiento está en [PLAN.md](../../PLAN.md). Se conservan la [primera revisión de Opus](2026-11-06-sync-opus.md), la [segunda revisión sobre el código](2026-11-06-sync-opus-segunda.md) y el [registro de decisiones](sync-decisions.tsv). Ambas revisiones de Opus son estáticas, ejecutadas mediante Claude Code CLI con `claude-opus-5-5`.

## Diagnóstico contrastado

Los clientes pedían perfil, pacientes y recursos por paciente en serie. iOS encadenaba cada solicitud de sincronización completa; Android esperaba el mutex y repetía todo el refresco. Android tenía tres disparos de inicio: restauración, primer resume y primer callback de red. La lista de familias iOS viajaba fuera del motor, una vez por llamador. El resumen diario propio se pedía sin mostrarse.

El borrador aportó mediciones de staging de una ventana de 30 minutos del 2026-11-06: 372 peticiones, p50 de 80 ms, p99 de 142 ms y ninguna superior a un segundo. También describió ráfagas de 55 peticiones iOS y 21 Android. Esas cifras son antecedentes del borrador; esta tarea no repitió esa medición ni atribuyó cada ráfaga a un llamador específico. Las estimaciones de latencia propuestas no son resultados del código corregido.

## Decisiones implementadas

### A. Compartir el refresco pendiente

Una solicitud comparte únicamente el último refresco pendiente que todavía no empezó. Si ya comenzó, solicita otro posterior. Historial, denegaciones y mutaciones conservan sus barreras de orden. Cada llamador espera datos leídos después de su solicitud y el siguiente ciclo vuelve a enviar la cola durable.

No existe un máximo global de dos ciclos. Las llamadas que llegan durante el primero se agrupan en el siguiente; una declaración durante el segundo puede exigir un tercero. El indicador de sincronización permanece mientras hay trabajo pendiente. La generación de sesión impide reutilizar solicitudes antiguas.

Se eligió la tarea pendiente compartida frente a generaciones de solicitudes y listas adicionales de esperadores. La propia tarea expresa qué ciclo satisface a sus llamadores.

### B. Leer recursos independientes en paralelo

Después del envío serial de operaciones, perfil, accesos y familias se leen en paralelo. Con los accesos y sus zonas, se leen los recursos de hasta cuatro pacientes simultáneos. Cada paginador conserva el orden por cursor. El resumen diario sólo se pide para pacientes ajenos.

Las respuestas de un paciente se reúnen antes de escribir. Las dosis no retroceden de versión. Las denegaciones conocidas se procesan antes de errores recuperables de otros pacientes y un 401 expira la sesión. Familias iOS forma parte del ciclo compartido y su secuencia impide publicar un listado anterior sobre uno posterior.

### C. Refrescar lo que cambió

| Operación | Lecturas posteriores |
| --- | --- |
| Declarar o corregir | Inventario de pacientes enviados y miembros locales de sus cajas; resumen diario de los pacientes ajenos afectados |
| Cambiar nombre | Perfil, accesos y familias; conserva agenda y métricas existentes |
| Crear, aceptar o salir de familia | Directorio completo; invalida revocados y carga sólo accesos nuevos o con cambios de vínculo, permisos o zona |
| Reponer, contar, compartir o dejar caja | Inventarios afectados; si faltan cuentas en caché, renueva los inventarios locales sin releer agendas |
| Recibir un 409 de declaración | Conserva el conflicto y consulta las dosis de su día local para obtener versión y evento vigentes, incluso fuera de la ventana habitual |

Las lecturas pendientes después de un envío confirmado se conservan hasta aplicarlas. Un reinicio ejecuta un refresco completo. El cliente nunca copia `DoseResult.balance` al inventario: puede ser el saldo histórico de una respuesta idempotente.

Un vaciado incierto impide renovar inventario, porque una operación pendiente podría haberse aplicado ya en el servidor. Las cajas compartidas requieren considerar también las operaciones de sus miembros locales. El saldo estimado sigue separado del confirmado.

## Hallazgos de las revisiones

La primera revisión confirmó A y B y recomendó aplazar C por riesgos de saldo y métricas. Se implementó C con pruebas específicas para resolver esos riesgos, en lugar de sustituir el refresco completo por un GET insuficiente.

La revisión posterior detectó pérdida de familias ante un error posterior, dosis obsoletas tras 409 y pérdida de la fecha de un conflicto histórico Android después de un refresco fallido y reinicio. Las regresiones se escribieron antes de los arreglos. La segunda revisión de Opus añadió la prioridad del fallo incierto sobre una denegación posterior en la cola iOS y las renovaciones forzadas redundantes de token Android. Esos casos ya están corregidos y sus regresiones están en la suite final. La renovación Android comparte el trabajo en curso y sólo fuerza una renovación si el token rechazado sigue vigente. Un fallo compartido no se conserva para intentos independientes posteriores. El callback de red distingue la conexión inicial, un cambio de red predeterminada y una pérdida tardía de la red anterior.

También se corrigió la carrera entre expirar sesión y publicar un ciclo posterior: una vez iniciado el cierre del motor por un 401, un resultado posterior no deja la interfaz conectada con el motor detenido. Los pendientes de lectura se limpian al cambiar de cuenta o salir, y se conservan al reautenticar la misma cuenta.

## Evidencia y límites

Cortes intermedios comprobados:

- Código inicial: checks comunes, 88 pruebas iOS y tarea unitaria Android aprobados. Android reutilizó resultados de Gradle en ese primer corte.
- A/B: las regresiones iOS detectaron exceso de ciclos, ausencia de solapamiento y resumen propio innecesario. Android detectó tres ciclos donde debían ejecutarse dos.
- C: cuatro pruebas instrumentadas Android fallaron por lecturas completas innecesarias; las siete iniciales pasaron después del cambio.
- 409: Android conservaba versión 1 cuando el servidor tenía 3; iOS conservaba versión y evento antiguos y no consultaba el día histórico. Ambas regresiones fallaron antes de corregir.
- Conflicto histórico Android: la regresión falló al perder la fecha después del reinicio; las trece pruebas selectivas pasaron tras conservar las dosis referidas por operaciones no resueltas.
- Carrera de sesión iOS: con el guard anterior, la nueva prueba dejó la interfaz conectada y sin error de autenticación. Tras corregirlo, pasó junto con toda la suite.

Verificación final del código:

| Comando | Resultado |
| --- | --- |
| `make tokens-check test lint` | PASS; Go con detector de carreras, 35 pruebas web y validación de tokens |
| `make test-ios` | PASS; 122 pruebas en 21 suites |
| `make lint-ios` | PASS |
| `make test-ios-e2e` | PASS; 12/12 en simulador iOS |
| `make test-android lint-android build-android` | PASS; 48 pruebas JVM, lint y APK debug |
| `make test-android-device` | PASS; 28 pruebas en emulador Android |
| `make test-android-e2e` | PASS; 4/4 con API local, PostgreSQL e identidad emulada |

La captura final de la agenda Android se revisó visualmente. Los E2E iOS probaron también texto grande y notificación local. El código de la app iOS usado en los E2E es idéntico al restaurado después de demostrar la regresión de sesión; sólo se añadió esa prueba unitaria. El script auxiliar se editó durante su ejecución y falló después del `PASS ios-e2e`; XCTest terminó con `TEST SUCCEEDED`. Los checks comunes, unitarios iOS y lint se ejecutaron nuevamente y terminaron correctamente.

No se ejecutaron `make test-integration`, build web ni E2E web: no cambian backend, contrato ni código web. Los E2E móviles sí ejercitaron la API real local. No se probó CI remoto.

Las pruebas con transportes controlados demuestran coordinación y selección de peticiones, no latencia de red real. Los E2E usan simulador/emulador y bases locales desechables. No equivalen a teléfonos físicos ni a un benchmark de staging.

La medición del cliente contra staging y la aceptación funcional en iPhone y Android físicos quedan para la instalación solicitada como siguiente paso. No se promete una sincronización inferior a un segundo ni una mejora porcentual sin esa medición.

## Architecture Impact

Cambian la coordinación de sincronización, la concurrencia de lecturas y los recursos que se renuevan después de mutaciones en los clientes nativos. Los mapas [iOS](../../apps/ios/docs/00-home.md) y [Android](../../apps/android/docs/00-home.md) documentan esos flujos. No cambia el contrato HTTP, el esquema del backend, las transacciones de consumo ni las reglas de autorización. Tampoco se modifica la UI aceptada. La revisión independiente `living-architecture REVIEW`, con el mismo modelo del agente principal, dio PASS al código y mapas finales. No es una revisión multimodelo; las revisiones Opus se conservan por separado. No hay despliegue.
