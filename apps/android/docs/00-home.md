# Mapa de Android

La app Android permite consultar la agenda propia y las de pacientes que autorizaron al cuidador, declarar y corregir tomas según alcance, gestionar inventario y consentimiento. Cuenta, onboarding y preferencias de navegación forman parte de la app. El proyecto generado con Android CLI oficial compila con minSdk 26 y targetSdk 37. El flujo completo se verifica en emulador. El usuario aceptó F5 tras revisar la app en Xiaomi con Android 13; el runbook conserva los casos físicos pendientes.

```mermaid
flowchart TB
    UI[Compose y Navigation 3] --> VM[PatientViewModel y StateFlow]
    VM --> Repo[Repository: own, patients y accesos]
    Repo --> Room[(Room: caché y cola por cuenta y paciente)]
    Repo --> API[Retrofit y DTOs del contrato]
    API --> Identity[Firebase REST y sesión cifrada Keystore]
    API --> Backend[API Go]
    Repo --> Reminders[Reconciliación de recordatorios]
    Room --> Reminders
    Boot[Arranque y cambios del sistema] --> Reminders
    Reminders --> Alarm[AlarmManager exacto o fallback]
    Alarm --> Receiver[Validar agenda propia y hora vigente]
    Receiver --> Notification[Notificación discreta]
    Notification --> UI
    FCM[Firebase Messaging] --> Push[RemotePushRegistration y servicio]
    Repo --> Push
    Push --> API
    Push --> Notification
```

## Responsabilidades e invariantes

- [`core/Repository.kt`](../app/src/main/kotlin/cl/nndsk/medication/core/Repository.kt) persiste antes de enviar, serializa operaciones y conserva conflictos. Una declaración se escribe en la cola sin esperar la sincronización en curso; un mutex corto la ordena con la limpieza del logout y nunca se sostiene durante la red. La respuesta idempotente no reemplaza el inventario actual. Primero envía la cola de todos los pacientes y después refresca cada acceso de forma secuencial, con fechas en su zona IANA. Los refrescos reemplazan la ventana de agenda sin reducir versiones. Un 403/404 retira sólo el paciente afectado y mantiene sus operaciones como `denied` en Ajustes; un 401 expira la sesión globalmente.
- [`core/LocalDatabase.kt`](../app/src/main/kotlin/cl/nndsk/medication/core/LocalDatabase.kt) separa cuenta y paciente en caché y cola. Las snapshots guardan nombres, perfil, accesos y resumen de la API para restaurar varias agendas sin conexión; no cambia el esquema Room. La unicidad por dosis impide doble acción local. El JSON del comando permanece inmutable hasta recibir respuesta o hasta descarte explícito de un rechazo/conflicto.
- [`core/Identity.kt`](../app/src/main/kotlin/cl/nndsk/medication/core/Identity.kt) ofrece acceso, registro y recuperación mediante Firebase REST. Conserva credenciales, correo y preferencia local de uso cifrados, serializa renovaciones y rechaza un cambio de cuenta sin logout. Datos privados y credenciales quedan excluidos de backups y transferencia.
- [`ui/App.kt`](../app/src/main/kotlin/cl/nndsk/medication/ui/App.kt) conserva la navegación. `ui/account/`, `ui/today/`, `ui/detail/` y `ui/settings/` contienen acceso, Hoy e Historial, detalle y Ajustes con consentimiento. `ui/components/` reúne las filas, tarjetas, acciones y estados compartidos. `ui/caregiver/` contiene la lista de pacientes, invitación con selector nativo para compartir y detalle Hoy/Historial/Inventario. Las pestañas se derivan de accesos, tratamientos propios y preferencia local; ésta no concede permisos. `PatientScreen` lleva un contexto explícito al reutilizar las pantallas de agenda, sin colocar pacientes ajenos en `own`. La revisión fija el comando enviado y la invitación que se acepta. Los registros pendientes y los saldos estimados se distinguen de los confirmados.
- [`notifications/Reminders.kt`](../app/src/main/kotlin/cl/nndsk/medication/notifications/Reminders.kt) reconcilia sólo alarmas de la agenda propia (`patientId == actorId`) y vuelve a comprobar ese origen y el instante antes de entregar, incluso para alarmas antiguas. El receptor no escribe eventos de dosis. La ventana se repone al sincronizar y se reconstruye desde Room después de reinicio.

- [`core/TodayPlan.kt`](../app/src/main/kotlin/cl/nndsk/medication/core/TodayPlan.kt) reparte Hoy con las mismas reglas que iOS, y `LateTime` en [`core/EffectiveTime.kt`](../app/src/main/kotlin/cl/nndsk/medication/core/EffectiveTime.kt) impide horas futuras. Sólo presentan. Una dosis con más de 4 horas de atraso sale de la tarjeta y pasa a «Pasaron sin registrar», sin cambiar su estado. Declarar desde Hoy registra directamente, como en iOS; las correcciones conservan motivo y revisión. `AppState.offline` identifica el último intento sin conexión: omite el onboarding para permitir usar la caché, rotula los datos guardados y deshabilita las mutaciones de inventario. `rejected` e `informational` distinguen rechazos y avisos informativos en la presentación.
- Detalle y Ajustes se agrupan en tarjetas por sección, bajo una barra superior con título y botón de volver. Corregir un registro se hace en una hoja aparte, con motivo obligatorio. Historial incluye las tomas de hoy cuya hora ya pasó, como iOS.
- Los iconos de navegación y estado son vectores en `res/drawable`, sin dependencia de `material-icons`.

La lista de pacientes usa métricas de la API con período y denominador, sin contarlas desde páginas de dosis. Las declaraciones ajenas usan tercera persona; los alcances controlan las acciones visibles y el backend autoriza cada petición. Reposición y conteo requieren conexión y conservan su clave idempotente al reintentar; sólo las declaraciones se encolan offline. No se editan tratamientos ni se gestionan pools familiares desde esta fase. Los contratos compartidos y la autorización se describen en el [mapa del monorepo](../../../docs/00-home.md).

## Verificación y operación

- [Decisión F5](../../../docs/decisions/0006-f5-android-patient-app.md).
- [Pruebas F5 y pendientes físicos](../../../docs/runbooks/f5-verification.md).
- [Configuración y comandos](../../../docs/runbooks/development.md#android-f5).
- [Contrato compartido](../../../packages/contracts/openapi.yaml).

## Avisos remotos F6

[RemotePush.kt](../app/src/main/kotlin/cl/nndsk/medication/notifications/RemotePush.kt) registra el token FCM con identidad verificada, permiso y un ID estable distinto por cuenta e instalación. Renueva el registro al entrar, sincronizar, volver a foreground y recibir un token nuevo. El servicio muestra texto genérico y abre la app, sin registrar declaraciones.

Firebase Messaging está fijado a 26.0.1 en el catálogo de versiones y sus dependencias en el lockfile. Su mínimo API 24 es compatible con minSdk 26 del proyecto, según las [notas oficiales](https://firebase.google.com/support/release-notes/android). Se usa el modo de token compatible con el contrato HTTP v1 del servidor. `getToken`, `deleteToken` y `onNewToken` siguen disponibles pero están deprecados en este SDK. Migrar al nuevo modo FID exige cambiar también el destino del envío en el servidor; F6 no activa `firebase_messaging_installation_id_enabled`. Analytics y auto-init están desactivados en el manifest. La app habilita el registro sólo con sesión y permiso.

Configurar `firebaseProjectId`, `firebaseAppId` y `firebaseSenderId` como propiedades de Gradle junto a la API key pública ya existente. `firebaseAppId` es el identificador Firebase `1:…:android:…`, no el applicationId de Android. El paquete registrado en Firebase debe coincidir con el variant instalado, incluido su sufijo. No se usa `google-services.json` ni se añaden claves de servicio. Sin estos valores, o con Auth emulado, Ajustes oculta la sección de avisos remotos y mantiene los recordatorios locales.

Logout intenta DELETE en la API durante cinco segundos, desactiva auto-init e intenta borrar el token durante otros cinco segundos. Después borra la identidad aunque no haya red. Si falla la revocación remota, muestra que puede quedar un aviso genérico hasta el vencimiento del registro. El callback de token nunca registra una instalación sin sesión. Las notificaciones ya aceptadas por FCM pueden seguir siendo entregadas; el payload del servidor no contiene datos médicos.

Las pruebas unitarias verifican identidad por instalación/cuenta y el cuerpo del contrato. Build y lint no acreditan entrega FCM real. Falta probarla con configuración Firebase y permisos en un dispositivo registrado.

## Cierre de sesión F8

Logout oculta el estado inmediatamente y ejecuta la limpieza bajo el mutex del repositorio sin cancelación. Intenta desregistrar push, borrar credenciales y limpiar Room de forma independiente. Un fallo de Room no vuelve a publicar el snapshot anterior. La identidad conserva una marca de borrado pendiente que impide restaurar credenciales cuando la eliminación quedó incompleta.

Los fallos se muestran sin afirmar que todos los datos fueron borrados. La pantalla de acceso permite reintentar la limpieza sin autenticarse. El borrado lógico no acredita saneamiento forense ni protección del selector de aplicaciones. Ver [verificación F8](../../../docs/runbooks/f8-verification.md).

## Inventario compartido

El snapshot de cada paciente trae `pool` por cuenta, y el propio trae `pendingPools`. Room no cambia de esquema porque el snapshot se guarda como JSON. [`SharedInventory.kt`](../app/src/main/kotlin/cl/nndsk/medication/ui/caregiver/SharedInventory.kt) reúne la tarjeta de decisión de Hoy, el estado y la salida. Proponer, decidir y salir requieren red, no entran a la cola y conservan su operación para reintentar. El estimado local sigue restando sólo las declaraciones pendientes de este teléfono.
