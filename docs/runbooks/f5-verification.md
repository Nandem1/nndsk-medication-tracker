# Verificación F5

F5 implementa Android del paciente. El usuario cerró la fase el 2026-11-03 con «Bastante bien, PASS F5», tras instalar y revisar la app en su teléfono. Se conserva abajo la diferencia entre aceptación del usuario y cobertura técnica acreditada. No se implementó F5b ni F6. No hubo commits, push, publicación ni despliegue.

## Entorno y construcción

- Mac ARM, JDK Temurin 21.0.13+9 descargado con checksum verificado, Android CLI oficial y SDK local dentro de `.tmp`.
- Proyecto generado con la plantilla oficial `empty-activity`, minSdk 26, target/compile 37. Gradle 9.4.1 y AGP 9.2.0. Android Studio no está instalado; no se verificó importación/sync en Studio.
- Emulador ARM Android 17/API 37.0, imagen Google APIs revisión 8, emulator 37.2.13. La primera instalación descargó el binario Intel; se reemplazó por ARM antes de ejecutar las pruebas.
- PostgreSQL local en una base nueva desechable `medication_f4_android_20261103`, migraciones 1 a 4 aplicadas. Se reutiliza el servidor E2E existente, que admite ese prefijo. No se hicieron migraciones down ni cambios de esquema.
- Firebase Auth emulado con proyecto `demo-medication-local`. Ninguna identidad, pauta o conexión de producción.

## Pruebas

| Comprobación | Evidencia y alcance |
| --- | --- |
| `make test` | Go con detector de carreras y 10 tests Vitest. Go reutilizó caché de paquetes sin cambios. |
| `make lint` | gofmt, go vet y TypeScript. |
| `make build-android` y `:app:assembleRelease` | APK debug y APK release sin firma generados. No publicados ni desplegados. |
| `make test-android` | 13 tests JVM sin fallos de hora efectiva, omisión, correcciones, DST Santiago, planificación de recordatorios y stock decimal exacto. |
| `make test-android-device` | 4 tests instrumentados sin fallos. Room sobre SQLite real en emulador, reapertura de DB, inserciones concurrentes, separación de cuentas/pacientes, sesión cifrada e ilegible, permisos denegados, fallback y entrega privada. |
| `make lint-android` | Android Lint debug y release, 0 errores y 22 advertencias por variante, principalmente nuevas versiones disponibles y recomendaciones de estilo/configuración. |
| `make test-android-e2e` | UI Compose real, emulador Firebase, API HTTP y PostgreSQL reales. Incluye Doze forzado, notificación que abre la dosis, offline, retries, corrección y conflicto. |
| `make test-android-reboot` | Entrega observada después de reboot real del emulador, sin abrir la app ni iniciar instrumentación durante la espera. El resultado se registra en `.tmp/android-reboot/delivered.log`. |
| `shellcheck scripts/android-*.sh` | Revisión de scripts de build y pruebas. |

El E2E crea paciente y cuidador sintéticos. El paciente revisa/acepta consentimiento en la UI y el cuidador crea una pauta por HTTP. La app muestra dos dosis y recibe un aviso discreto durante Doze. El aviso abre la dosis correcta sin declararla.

El proxy luego corta conexiones antes del servidor. La app guarda la declaración offline. Se recrea la Activity y se comprueba la cola persistida. A continuación el proxy deja hacer commit pero pierde las respuestas. Tres reintentos conservan el mismo cuerpo y el ledger tiene un solo movimiento de consumo de `0.500`. Al recuperar red queda saldo `9.500`. Una corrección a omitida devuelve `10.000`. Una corrección de otro actor entre revisión y envío provoca un 409 visible, sin sustituir el comando revisado ni duplicar consumo.

La persistencia tras cerrar/reabrir la base se prueba con Room. La recreación de Activity no se presenta como muerte completa del proceso. El reboot prueba recuperación de recordatorios desde almacenamiento persistente. El E2E observa efectos de stock a través de la API contra PostgreSQL; no usa respuestas simuladas del backend.

Los artefactos locales están en `.tmp/f5`, `.tmp/android-e2e`, `.tmp/android-reboot` y `apps/android/app/build/reports`. No se versionan logs, APKs, SDK, JDK ni credenciales. El script E2E conserva una captura de agenda sintética en `.tmp/android-e2e/agenda.png`.

## Correcciones durante la verificación

- La revisión independiente encontró que reconstruir la versión al guardar podía alterar una declaración ya revisada. El repositorio recibe y persiste el comando exacto; el E2E reproduce el cambio concurrente antes de enviarlo.
- La revisión visual de la agenda sintética comprobó el layout. Las cantidades se presentan con coma decimal es-CL, por ejemplo `0,5`, sin convertir a float ni alterar el contrato.
- El UUID de aceptación pendiente se conserva al renovar sesión con el mismo UID. Las horas DST repetidas permiten elegir explícitamente el primer o segundo instante, con offsets visibles.
- El token revisado se conserva junto con los permisos mostrados. Cambiar el campo no puede hacer aceptar otra invitación.
- Los errores de consentimiento no eliminan la agenda. Una sesión expirada ofrece salida explícita con advertencia de pendientes.
- Los IDs de alarma se guardan antes de programar; el receptor compara contexto e instante vigente. Una alarma obsoleta no avisa una dosis reprogramada.
- La primera prueba Doze comparaba texto del comando. Se corrigió para comprobar el estado real `IDLE`.
- El primer ensayo de reboot usaba instrumentación al arrancar; el paquete quedaba detenido y no se observó entrega. La prueba actual inicia la app antes de reboot y observa la notificación desde `adb` sin volver a instrumentar durante la espera.
- El backend rechaza horas posteriores a su reloj. El caso de conflicto usa una hora sintética efectivamente pasada para no confundir un 422 temporal con el 409 que busca probar. La app conserva los rechazos para revisión; no altera automáticamente la hora declarada.

## Aceptación en teléfono físico

Se detectó un Xiaomi 2107113SG con Android 13, API 33, autorizado por USB y después conectado por ADB inalámbrico. Xiaomi bloqueó la instalación por ADB con `INSTALL_FAILED_USER_RESTRICTED`. Se copió el APK a Descargas y el usuario lo instaló manualmente. `pm list packages` confirmó `cl.nndsk.medication.e2e`.

Se levantaron Auth emulado y API local y se conectaron los puertos 9099, 18083 y 18084 mediante `adb reverse`. Una cuenta sintética se creó en Auth y su token obtuvo respuesta 200 en `/v1/me`. El usuario recibió las credenciales de prueba y luego emitió su aceptación. No se registró un recorrido físico detallado ni un resultado de instrumentación en el teléfono. El paquete de tests no figuraba instalado en la última comprobación.

Los intentos de instalación y servicios físicos tienen evidencia local en `.tmp/f5-physical`. La evidencia anterior de emulador se preservó en `.tmp/f5/emulator-proof`.

## Cobertura pendiente al cierre por aceptación

1. Ampliar la comprobación de compatibilidad a los demás teléfonos de los pacientes. Se identificó y ejecutó la app en Xiaomi 2107113SG con Android 13. minSdk 26 es configuración compilada, no una prueba ejecutada sobre todos los teléfonos soportados.
2. Ejecutar el flujo de consentimiento, agenda, offline y sincronización en teléfono físico, con API/PostgreSQL de pruebas. Probar cierre del proceso mientras hay pendientes, reintentos y ausencia de doble consumo.
3. Probar notificaciones y precisión denegadas en teléfono físico, Doze y ahorro de batería del fabricante, reboot, cambio de zona y retirada del permiso exacto. Las alarmas siguen siendo best effort.
4. Revisar TalkBack, texto ampliado, modo oscuro, navegación con una mano y comprensión por un paciente. Los controles usan Material 3, etiquetas de texto, tamaño táctil mínimo 48dp y tipografía escalable; no se acredita revisión humana de accesibilidad.
5. Configurar un proyecto Firebase autorizado y una API HTTPS de pruebas para login fuera del emulador. No se usaron credenciales reales en esta fase.
6. Abrir y sincronizar el proyecto en Android Studio. Se acreditan build Gradle, APK y ejecución en emulador, no una sesión del IDE.

F5 queda cerrada por aceptación del usuario con esta cobertura pendiente documentada. No comenzar F5b sin una petición nueva.

## Architecture Impact

Cambian los límites y runtime de Android al pasar de carpeta reservada a app ejecutable. Añade Room, Firebase REST y AlarmManager como integraciones cliente. No cambian esquema PostgreSQL, API/RPC, autorización backend, reglas clínicas, worker ni despliegue. Se actualizan el mapa general, el mapa Android, README y la decisión F5. La validación es local; producción no verificada.
