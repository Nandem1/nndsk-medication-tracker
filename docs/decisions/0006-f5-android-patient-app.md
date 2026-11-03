# App Android del paciente

## Decisión

Android usa Single Activity, Compose Material 3, Navigation 3, ViewModel/StateFlow, Retrofit/OkHttp y Room. La composición explícita en `MedicationApplication` evita incorporar Hilt para tres dependencias. No comparte UI con iOS ni añade la vista de cuidador de F5b.

El proyecto se generó con `android create empty-activity` de Android CLI oficial, plantilla `templates-sdk-package-16732273`. Su Gradle Wrapper proviene de esa plantilla. Se fijó Gradle 9.4.1 con checksum y AGP 9.2.0 para SDK 37. Android Studio no estaba instalado. Se comprobó el proyecto mediante compilación Gradle y ejecución en Android Emulator; abrirlo/sincronizarlo en Studio queda pendiente. No se fabricó un wrapper.

## Identidad y datos locales

Firebase REST mantiene la misma integración de identidad que iOS. La sesión y el identificador de aceptación de invitación se guardan en un archivo atómico cifrado AES-GCM con una clave Android Keystore. La API valida los tokens y autoriza cada operación. Release rechaza HTTP y el emulador de identidad. Las variantes debug y e2e tienen identificadores distintos de release; e2e sólo apunta a servicios loopback accesibles por `adb reverse`.

`PatientContext` separa UID Firebase, actor interno y paciente. F5 selecciona exclusivamente el acceso propio confirmado por `/v1/me` o `/v1/patients`, con `link_id` nulo y scopes de lectura y dosis. La caché y cola tienen claves de cuenta y paciente. No hay selector de pacientes ajenos ni operaciones de cuidador.

Room guarda la agenda y las operaciones antes de enviarlas. Las cantidades permanecen como texto decimal y la estimación usa `BigDecimal`. La UI usa coma decimal es-CL y evita separadores de miles ambiguos. Los saldos confirmados llevan la fecha de la última actualización; el saldo estimado con pendientes se muestra por separado. Conflictos impiden inventar una estimación.

## Sincronización

Cada declaración revisada fija UUID, versión, referencia de corrección, hora efectiva y cuerpo JSON. Guardar no reconstruye la versión después de que otra sincronización pudiera haberla cambiado. La restricción única de cuenta/paciente/dosis evita dobles toques pendientes.

Un mutex serializa envío, refresco, login y logout. Se reintenta al abrir/volver a foreground, recuperar una red o pulsar Sincronizar; no hay un servicio de sincronización permanente en segundo plano. La respuesta de dosis y la retirada de la operación se aplican en una transacción Room. La respuesta idempotente puede ser antigua; no se usa su saldo como saldo actual. El inventario se consulta tras vaciar la cola. El refresco protege versiones más recientes y reemplaza la ventana para retirar ocurrencias canceladas.

Los errores de red, 429, 5xx y respuestas ilegibles conservan UUID y cuerpo. Los 409, entradas inválidas y denegaciones quedan visibles para revisión. Descartar requiere decisión explícita y sólo se permite para operaciones terminales. Una corrección posterior crea otro UUID. El cierre de sesión advierte de pendientes, borra datos locales y cancela avisos. La sesión expirada o ilegible ofrece volver a entrar o cerrar explícitamente.

La aceptación de consentimiento envía el token asociado a los permisos que se revisaron, aunque cambie el campo mientras llega una respuesta. Un error de invitación no invalida la agenda del paciente.

## Recordatorios

AlarmManager programa instantes UTC proporcionados por la API, sin regenerar reglas clínicas en el teléfono. Reconcilia hasta 128 dosis futuras, excluye declaraciones locales pendientes y cancela alarmas obsoletas. Registra cada identificador antes de programar para poder cancelarlo tras una interrupción.

Se solicita `POST_NOTIFICATIONS` desde Ajustes y se ofrece `SCHEDULE_EXACT_ALARM` como acceso especial voluntario. No se declara `USE_EXACT_ALARM`. Si falta acceso exacto se usa `setAndAllowWhileIdle` y se muestra precisión limitada. No se promete puntualidad ni entrega. La revocación de acceso exacto puede eliminar alarmas del sistema; al volver a abrir la app se reconstruyen con el permiso vigente.

Los receptores de arranque, actualización, cambio de hora/zona y concesión de precisión reconcilian la ventana guardada. Cada entrega valida cuenta, paciente, dosis, hora prevista y ausencia de declaración pendiente. La notificación usa texto discreto y abre esa dosis; nunca confirma una toma.

## Límites

La DoD exige Android físico. El emulador no acredita comportamiento de fabricantes, ahorro de batería real, TalkBack ni compatibilidad con los teléfonos familiares aún sin identificar. No hay distribución, publicación, worker, nuevas migraciones ni cambios del contrato backend.

Referencias consultadas: [AGP 9.2](https://developer.android.com/build/releases/agp-9-2-0-release-notes), [Navigation 3](https://developer.android.com/jetpack/androidx/releases/navigation3), [Room](https://developer.android.com/jetpack/androidx/releases/room), [alarmas](https://developer.android.com/develop/background-work/services/alarms), [permisos de notificación](https://developer.android.com/develop/ui/compose/notifications/notification-permission), [Firebase REST](https://firebase.google.com/docs/reference/rest/auth).
