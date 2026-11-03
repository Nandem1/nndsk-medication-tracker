# PLAN.md — Medication Tracker (monorepo nativo)

> **Estado:** especificación inicial lista para ejecutar por Codex.  
> **Fecha base:** 2026-11-02.  
> **Propósito:** app familiar de recordatorios de medicamentos, registro de tomas, inventario y seguimiento por cuidador.  
> **Nombre provisional del repositorio:** `medication-tracker`.  
> **Idioma del producto:** español de Chile (`es-CL`) al inicio.  
> **Regla para el agente:** leer este documento completo antes de modificar el repositorio. Implementar **una fase por iteración**, confirmar su DoD y registrar decisiones relevantes. No generar toda la aplicación en una sola ejecución.

---

## 0. Visión y principios

### Problema

Un cuidador necesita configurar los medicamentos de sus padres, recordarles las tomas, saber qué han confirmado, estimar cuándo se agotarán sus medicamentos y ver tendencias comprensibles. Los pacientes necesitan una experiencia extremadamente simple.

### Roles

- **Cuidador / administrador familiar:** invita a pacientes, registra tratamientos siguiendo instrucciones médicas existentes, configura horarios e inventario, revisa adherencia *declarada*, corrige errores con trazabilidad y recibe alertas.
- **Paciente:** consulta próximas tomas, registra «Me lo tomé», «Me lo tomé tarde» o «No me lo tomé», revisa su agenda e inventario, y autoriza o revoca el acceso del cuidador.
- **Sistema:** crea ocurrencias de dosis, sincroniza eventos, proyecta inventario y envía recordatorios / alertas; **no prescribe ni modifica pautas clínicas**.

### Uso previsto

Los pacientes usan Android. Los cuidadores usan iPhone y Android. Por eso ambas apps móviles tienen dos vistas: paciente y cuidador. La vista disponible depende de los permisos que el backend confirma, no de un rol enviado por el cliente.

### Objetivo de éxito para el MVP

Una prueba real de extremo a extremo debe demostrar:

1. El paciente autoriza al cuidador a ver y administrar su información.
2. El cuidador configura un tratamiento con dosis, horarios, unidades y stock inicial.
3. El paciente ve las dosis previstas y recibe un recordatorio local aunque esté sin internet (dentro de los límites del sistema operativo).
4. El paciente confirma una toma, una toma tardía o una omisión.
5. Una dosis confirmada como tomada genera **exactamente un** descuento de inventario; una omitida o sin confirmar no descuenta.
6. Los cambios se sincronizan correctamente, incluidos reintentos y modo sin conexión.
7. El cuidador ve el historial correcto, las dosis sin confirmar y el cálculo de reposición.

### Restricciones de producto y seguridad

- La app es un **registro de autocuidado**, no una fuente de prescripción ni un sistema de emergencia.
- Nunca sugerir duplicar, adelantar, suspender o compensar dosis. Para una dosis perdida o tardía, mostrar las instrucciones que aportó el profesional o recomendar consultar a un profesional/farmacéutico.
- «Sin confirmar» **no** significa «No me lo tomé»; y una confirmación es una **declaración**, no evidencia de ingestión.
- La notificación es *best effort*: sistemas operativos, permisos, batería y estado del dispositivo pueden impedirla o retrasarla. Mostrar estado de permisos y una advertencia de fiabilidad; no prometer puntualidad garantizada.
- Privacidad por defecto: información sensible de salud, acceso mínimo, consentimiento explícito del paciente, revocación, exportación/borrado y auditoría de accesos y cambios.
- El diseño debe ser accesible para adultos mayores: texto escalable, alto contraste, botones amplios, confirmación clara, feedback no punitivo y navegación sencilla.
- No incorporar secretos, nombres reales de pacientes, tratamientos reales ni datos de producción en fixtures o repositorio.

---

## 1. Decisiones técnicas (ADR resumidas)

| Área | Decisión para MVP | Motivo |
|---|---|---|
| Repositorio | Monorepo Git, `Makefile` como orquestador | Un único lugar, sin imponer una herramienta JS a Swift/Kotlin/Go |
| iOS | Swift + SwiftUI + Observation (`@Observable`) + NavigationStack | UI nativa y declarativa; iOS 17+ inicialmente |
| Android | Kotlin + Jetpack Compose + ViewModel/StateFlow + Navigation 3 | UI nativa, UDF y navegación oficial |
| Web cuidador | React + Vite + TypeScript + Tailwind + shadcn/ui + TanStack Query/Router | Stack familiar, rápido y sin necesidad de SSR |
| Estado web | TanStack Query para servidor; Zustand solo para estado UI transversal si hace falta | Evitar dos fuentes de verdad |
| API | Go + `net/http`/chi + PostgreSQL + pgx + sqlc | API pequeña, explícita y eficiente |
| Migraciones | goose (o alternativa única documentada) | Versionado reproducible |
| Auth | Firebase Authentication como **proveedor de identidad**, sin usar Firestore para historia clínica | Clientes móviles/web maduros; Go valida ID tokens; datos médicos solo en nuestro backend |
| Contratos | OpenAPI 3.1 como fuente de verdad; generar clientes si el generador elegido soporta bien el contrato | Tipado y coherencia entre plataformas |
| Almacenamiento local iOS | SwiftData o SQLite mediante un repositorio abstracto | Cache de agenda y cola de operaciones offline |
| Almacenamiento local Android | Room | Cache y cola offline |
| Push del cuidador | APNs + FCM, en fase posterior | Avisos remotos complementarios, no fuente primaria |
| Recordatorios paciente | Notificaciones locales programadas en cada dispositivo | Funcionamiento parcial sin red |
| Trabajos de servidor | Proceso `worker` Go sobre PostgreSQL, sin Redis al principio | Menor complejidad operativa |
| Infra local | Docker Compose para PostgreSQL; API/worker en host o Docker | Onboarding sencillo |
| Deploy | Contenedores gestionados, región y proveedor por decidir con base en privacidad, latencia y coste | Evitar acoplar el dominio al proveedor |
| Testing | Go test + integración PostgreSQL + tests de UI nativos | Asegurar invariantes del dominio |

**Versiones:** usar versiones **estables actuales** a la hora de inicializar, fijar dependencias y lockfiles, documentar versión exacta en README. No utilizar beta/alpha por defecto. Verificar que iOS mínimo, SDK Android y navegadores cubran los dispositivos reales de los padres antes de cerrar el soporte.

**No introducir de inicio:** Kotlin Multiplatform, React Native, microservicios, Kafka, Redis, GraphQL, Kubernetes, CQRS completo, event sourcing global, analytics externos con datos sensibles ni subscripciones de pago.

---

## 2. Estructura objetivo

```text
medication-tracker/
├── PLAN.md
├── AGENTS.md                      # reglas compactas extraídas de este plan
├── README.md
├── .gitignore
├── .editorconfig
├── .env.example                  # nunca secretos reales
├── Makefile
├── compose.yaml
├── apps/
│   ├── ios/
│   │   ├── MedicationTracker.xcodeproj/
│   │   └── MedicationTracker/
│   │       ├── App/
│   │       ├── Core/               # networking, auth, persistence, notifications
│   │       ├── DesignSystem/       # tokens, componentes, accesibilidad
│   │       └── Features/
│   │           ├── Today/
│   │           ├── MedicationDetail/
│   │           ├── History/
│   │           └── Settings/
│   ├── android/
│   │   ├── gradle/
│   │   ├── settings.gradle.kts
│   │   └── app/src/main/java/.../
│   │       ├── core/               # data, auth, notifications, navigation
│   │       ├── designsystem/
│   │       └── feature/            # today, detail, history, settings
│   └── web/
│       ├── src/
│       │   ├── app/
│       │   ├── components/ui/
│       │   ├── features/
│       │   │   ├── patients/
│       │   │   ├── treatments/
│       │   │   ├── inventory/
│       │   │   └── dashboard/
│       │   └── lib/api/
│       └── package.json
├── services/
│   ├── api/
│   │   ├── cmd/api/main.go
│   │   ├── internal/
│   │   │   ├── auth/
│   │   │   ├── domain/
│   │   │   ├── application/
│   │   │   ├── repository/
│   │   │   ├── http/
│   │   │   └── config/
│   │   ├── db/queries/
│   │   ├── sqlc.yaml
│   │   └── go.mod
│   └── worker/
│       ├── cmd/worker/main.go
│       └── go.mod                 # puede compartir módulo Go si simplifica
├── packages/
│   ├── contracts/
│   │   └── openapi.yaml
│   └── design-tokens/
│       └── tokens.json
├── infrastructure/
│   ├── migrations/
│   └── docker/
├── docs/
│   ├── decisions/
│   ├── domain/
│   ├── api/
│   ├── design/
│   └── runbooks/
└── scripts/
```

**Principio del monorepo:** la UI **no** se comparte. Se comparten contratos, lenguaje visual, definiciones semánticas, reglas de dominio documentadas y backend. La generación de clientes Swift/Kotlin/TS es opcional hasta comprobar su calidad y mantenibilidad; nunca compilar código generado no revisado.

**Notas de creación:** no fabricar un `.xcodeproj` a mano. Usar Xcode o un generador de proyectos explícitamente instalado y versionado; lo mismo para Gradle Wrapper. Si falta el SDK local, preparar la estructura y dejar un bloqueo verificable sin inventar un build exitoso.

---

## 3. Diseño del dominio

### 3.1 Conceptos

- **User:** identidad autenticada, idioma, zona horaria y preferencias.
- **CaregiverLink:** autorización paciente↔cuidador, alcance, fecha, estado y revocación.
- **Medication:** nombre, concentración, forma farmacéutica y metadatos de presentación (sin recomendaciones automáticas de dosis).
- **Treatment:** medicamento asignado a paciente, indicación transcrita, fecha inicio/fin, estado activo/pausado.
- **ScheduleRevision:** versión inmutable de la pauta con horarios locales, zona IANA (`America/Santiago`, etc.), días aplicables, cantidad por toma y vigencia.
- **DoseOccurrence:** instancia prevista de una dosis con ID estable, `scheduled_at` UTC, fecha/hora local original, ID de revisión y estado derivado.
- **DoseEvent:** declaración o corrección append-only del paciente/cuidador, con actor, idempotencia y tiempos.
- **InventoryAccount:** stock por paciente y tratamiento/presentación; unidad canónica elegida y cantidad decimal precisa.
- **InventoryMovement:** compra, consumo confirmado, ajuste físico o reversa; nunca eliminar movimientos históricos.
- **DeviceRegistration:** dispositivo, plataforma, estado de permisos y token push (fase posterior).
- **NotificationOutbox:** eventos de notificación para entrega con reintentos y deduplicación (fase posterior).

### 3.2 Modelo relacional inicial

```text
users
  id PK, auth_provider_uid UNIQUE, display_name, timezone, created_at

caregiver_links
  id PK, patient_user_id FK, caregiver_user_id FK,
  status(pending|active|revoked), scopes, created_at, accepted_at, revoked_at

invitations
  id PK, inviter_user_id FK, target_email_hash?, token_hash,
  expires_at, consumed_at, created_at

medications
  id PK, owner_patient_id FK, name, strength_label, form,
  package_label, created_at, updated_at

treatments
  id PK, patient_user_id FK, medication_id FK, instructions_text,
  status(active|paused|ended), starts_on, ends_on?, version, created_at

schedule_revisions
  id PK, treatment_id FK, revision_number, timezone, rules_json,
  effective_from, effective_until?, created_by, created_at

dose_occurrences
  id PK, treatment_id FK, schedule_revision_id FK,
  scheduled_at TIMESTAMPTZ, scheduled_local_date DATE,
  scheduled_local_time TIME, dose_quantity NUMERIC(12,3),
  status(pending|taken|taken_late|skipped), version, created_at,
  UNIQUE(schedule_revision_id, scheduled_at)

dose_events
  id PK, dose_occurrence_id FK, actor_user_id FK,
  event_type(taken|taken_late|skipped|corrected),
  occurred_at TIMESTAMPTZ?, recorded_at TIMESTAMPTZ,
  client_operation_id UUID, correction_of_event_id?, reason?,
  UNIQUE(actor_user_id, client_operation_id)

inventory_accounts
  id PK, patient_user_id FK, treatment_id FK,
  unit(tablet|capsule|ml|dose|other),
  low_stock_days_threshold INTEGER DEFAULT 5, created_at

inventory_movements
  id PK, inventory_account_id FK, quantity_delta NUMERIC(12,3),
  reason(initial|consumption|replenishment|manual_adjustment|reversal),
  source_dose_event_id FK?, client_operation_id UUID?,
  actor_user_id FK, created_at
```

El esquema es **lógico**: Codex debe adaptar tipos, check constraints, índices y `ON DELETE` de manera segura en migraciones. Un campo `status` en `dose_occurrences` es una proyección transaccional del historial: **el historial de eventos es auditable**. No usar `FLOAT` para stock o dosis; `NUMERIC` en PostgreSQL y decimal exacto en Go.

### 3.3 Invariantes no negociables

1. Una ocurrencia representa una dosis programada concreta y tiene identidad estable.
2. Una confirmación válida (`taken` o `taken_late`) descuenta **la cantidad prevista**, no siempre «1»; una `skipped` o una ocurrencia sin confirmar descuenta **0**.
3. Para una ocurrencia puede existir **un único efecto activo de consumo**. Correcciones crean eventos nuevos y, si cambia el efecto, movimientos compensatorios, nunca borran historia.
4. **Confirmación y movimiento de stock son una sola transacción de base de datos**; aplicar lock de la ocurrencia / cuenta y una restricción de unicidad para impedir doble consumo.
5. Toda mutación móvil tiene `client_operation_id` estable (UUID). Si el cliente reintenta, el backend entrega el resultado anterior sin duplicar eventos ni stock.
6. Si hay un error de concurrencia, el backend retorna `409` explícito y el cliente ofrece reconciliación; jamás pierde silenciosamente una acción offline.
7. El saldo se calcula desde los movimientos, o desde una proyección cacheada que siempre sea reconciliable con el ledger.
8. El stock real se puede ajustar por conteo físico; el inventario calculado **no presume** que una declaración equivale a una cantidad física perfecta.
9. No sugerir ni permitir automáticamente una pauta clínica distinta cuando alguien registra una dosis tarde u omitida.
10. La autorización se valida **en el backend en cada operación**, nunca por `role` o ID de paciente enviados por el cliente sin verificación.
11. Editar horarios afecta ocurrencias futuras, con revisión de pauta, y **no reescribe** tomas históricas.
12. Tiempos: guardar instantes en UTC y la zona IANA + hora local de la pauta. Las reglas de DST y cambios de zona se documentan y prueban. Nunca sumar ciegamente 24 horas a una dosis diaria local.

### 3.4 Semántica de los tres botones

| Acción paciente | Evento | Inventario | Detalle |
|---|---|---|---|
| «Me lo tomé» | `taken` | `-dose_quantity` | `occurred_at` por defecto ahora, editable si fue antes |
| «Me lo tomé tarde» | `taken_late` | `-dose_quantity` | pedir hora efectiva de la toma; nunca asumirla |
| «No me lo tomé» | `skipped` | `0` | motivo opcional, nunca asignar automáticamente |
| Sin respuesta | ninguno / vista `unconfirmed` | `0` | estado derivado del reloj, no declaración del paciente |
| Corregir una toma | `corrected` + nuevo estado | delta compensatoria según corresponda | requiere historial y trazabilidad |

**Importante:** `unconfirmed` no necesita ser un estado persistido; se deriva de `pending` al consultar un intervalo vencido. Una dosis marcada `taken_late` sigue siendo tomada para adherencia declarada, pero no puntual para la métrica de puntualidad. Los umbrales de «tarde» son métricas de organización, **no instrucciones clínicas**.

### 3.5 Recurrencias — alcance inicial

**MVP:** una o varias horas fijas por día, todos los días o días de la semana elegidos; fechas inicio/fin; pausar/reactivar con revisión. Dosis por horario expresada en decimal exacto, con unidades del stock.

**Post-MVP:** pautas alternas, ciclos, disminuciones progresivas, «según necesidad» (PRN), gotas, inhaladores con contadores específicos, dosis variables según parámetros clínicos y manejo de fracciones/combinaciones complejas. No representarlas incorrectamente como un simple horario diario.

**DST:** el generador trabaja desde fecha local + zona IANA. Si una hora local es inexistente por cambio horario, seleccionar explícitamente una política documentada (por ejemplo, siguiente instante válido del mismo día); si es ambigua, seleccionar una de las ocurrencias consistentemente y no duplicar. Antes de implementar, escribir tests para `America/Santiago` en cambios de horario y otras zonas. Cualquier política con impacto en horario de medicación deberá revisarse con usuario/profesional y mostrarse en la configuración.

---

## 4. Arquitectura y flujo

```mermaid
flowchart TD
    WEB[Admin Web: React / Vite] --> API[API Go + OpenAPI]
    IOS[iOS: SwiftUI] --> API
    AND[Android: Compose] --> API
    API --> PG[(PostgreSQL)]
    W[Go Worker] --> PG
    W --> PUSH[APNs / FCM: alertas cuidador]
    API --> AUTH[Firebase Auth: verificación ID token]
    IOS --> LOCAL1[Notificaciones y cache local]
    AND --> LOCAL2[Alarmas y cache local]
```

```mermaid
sequenceDiagram
    participant P as Paciente
    participant M as App móvil
    participant A as API Go
    participant D as PostgreSQL
    participant C as Cuidador
    P->>M: Me lo tomé
    M->>M: Guardar operación UUID en cola local
    M->>A: POST /v1/doses/{id}/events (idempotencia)
    A->>D: BEGIN; validar acceso; lock; registrar evento
    A->>D: Aplicar movimiento de stock en misma transacción
    D-->>A: COMMIT
    A-->>M: Estado y saldo autoritativos
    M->>M: Marcar operación sincronizada
    C->>A: Consultar actividad y stock
    A-->>C: Datos actualizados
```

### Fuente de verdad y consistencia

- **PostgreSQL** es la fuente de verdad de tratamientos, historial, permisos e inventario.
- Las apps guardan copias locales para visualizar agenda y registrar acciones offline.
- Acciones offline pendientes aparecen como **«Pendiente de sincronizar»**; su impacto en el stock local es estimado y se distingue del saldo confirmado por servidor.
- Reconciliación por `client_operation_id`, `updated_at`/`version`, cursor de sincronización paginado y operaciones idempotentes.
- Si el servidor rechaza una acción por pauta modificada, revocación o conflicto, conservar la operación para resolverla con el usuario; no hacer drop silencioso.
- Inicialmente no hace falta WebSocket: refresco por apertura/foreground y después de cada mutación es suficiente.

### Operaciones atómicas

Para confirmar dosis:

1. Validar sesión y autorización sobre paciente/dosis.
2. Buscar `client_operation_id` previamente ejecutado; devolver respuesta almacenada si existe.
3. Iniciar transacción; bloquear ocurrencia de dosis (`SELECT ... FOR UPDATE`).
4. Validar versión, ocurrencia, fecha, estado actual y transición permitida.
5. Crear `dose_event` append-only.
6. Crear `inventory_movement` únicamente si hubo efecto de consumo o corrección.
7. Actualizar proyección de estado/saldo y registrar respuesta idempotente.
8. `COMMIT`; devolver estado autoritativo.

Para correcciones, usar un comando separado con versión esperada, motivo y referencias al evento corregido. Evitar que una confirmación tardía vuelva a descontar después de una reconexión.

---

## 5. Contrato de API (borrador v1)

Prefijo `/v1`, JSON, timestamps RFC 3339 con zona/UTC, IDs UUID, paginación con cursor en históricos. Errores estándar: `code`, `message`, `request_id`, `details` sin datos personales innecesarios. Mutaciones idempotentes: `Idempotency-Key` o `client_operation_id` (elegir **un mecanismo uniforme** y probarlo).

| Método | Endpoint | Uso |
|---|---|---|
| GET | `/healthz` | Liveness sin DB |
| GET | `/readyz` | Readiness con DB |
| GET | `/v1/me` | Perfil y permisos efectivos |
| GET | `/v1/patients` | Pacientes accesibles para el actor |
| POST | `/v1/invitations` | Crear invitación de cuidador/paciente |
| POST | `/v1/invitations/accept` | Aceptar vínculo mediante token de un solo uso en el body, con identidad verificada |
| DELETE | `/v1/caregiver-links/{id}` | Revocar acceso |
| GET | `/v1/patients/{patientId}/treatments` | Listado de tratamientos |
| POST | `/v1/patients/{patientId}/treatments` | Crear tratamiento + pauta inicial |
| PATCH | `/v1/treatments/{treatmentId}` | Pausar, reanudar, finalizar y actualizar metadatos |
| POST | `/v1/treatments/{treatmentId}/schedule-revisions` | Cambiar pauta desde fecha efectiva |
| GET | `/v1/patients/{patientId}/doses?from=&to=` | Agenda por rango de fechas |
| POST | `/v1/doses/{doseId}/events` | Declaración de toma / omisión |
| POST | `/v1/doses/{doseId}/corrections` | Corrección trazable |
| GET | `/v1/patients/{patientId}/inventory` | Saldo y proyección de stock |
| POST | `/v1/inventory/{accountId}/movements` | Reposición / ajuste (con controles de autorización) |
| GET | `/v1/patients/{patientId}/adherence?from=&to=` | Métricas por rango |
| POST | `/v1/devices` | Registrar dispositivo/token (fase posterior) |
| DELETE | `/v1/devices/{id}` | Desregistrar dispositivo (fase posterior) |

Ejemplo de comando:

```json
{
  "client_operation_id": "b6b5ed99-4a9f-4e5c-9ad0-8237efda7821",
  "event_type": "taken_late",
  "occurred_at": "2026-11-02T20:24:00-03:00",
  "expected_version": 1
}
```

**Reglas:** no confiar en `patient_id` del payload para autorización; obtener identidad mediante token verificado. Especificar esquema OpenAPI, respuestas 200/201/400/401/403/404/409/422 y ejemplos **sintéticos**. No crear rutas de prueba inseguras en producción.

---

## 6. Autenticación, autorización y privacidad

### Identidad

- Usar **Firebase Authentication solo para identidad** (correo/contraseña para primer corte; evaluar mecanismos más accesibles posteriormente).
- Cada persona tiene cuenta propia. Evitar sesión compartida padre/cuidador.
- Clientes obtienen ID token; API Go lo valida en backend con Firebase Admin y resuelve `auth_provider_uid` a `users.id` interno.
- En entorno local se permite un modo de auth de desarrollo **solo en tests/emulador, explícitamente bloqueado en producción**. Nunca aceptar un header arbitrario como `X-User-ID` en producción.

### Autorización por paciente

- El propietario de la historia es el paciente. Un cuidador solo ve o edita según un vínculo **activo, explícitamente aceptado y revocable**.
- Invitaciones con token aleatorio, hash en BD, uso único y expiración; enviar token en body de POST, no en URL ni logs; evitar exponer información de existencia de cuentas.
- En cada endpoint proteger el `patientId` (riesgo IDOR/BOLA); revocar acceso invalida futuras lecturas y mutaciones incluso si el dispositivo tiene datos cacheados.
- Definir claramente qué puede seguir viendo un dispositivo offline después de revocación y borrar datos locales al detectar revocación/cierre de sesión.

### Controles mínimos

- HTTPS, tokens en almacenamiento seguro (Keychain/Android Keystore según SDK), no PII médica en logs, analytics ni push por defecto.
- Encriptación de almacenamiento en tránsito y en reposo por proveedor; evaluar cifrado local, backup y retención.
- Auditoría de lectura administrativa sensible y mutaciones, con minimización de datos.
- Exportación/eliminación de datos con política documentada y manejo correcto de registros necesarios para auditoría conforme a requisitos aplicables.
- Backups cifrados, restore probado, rate limiting, CORS restrictivo, timeouts, límites de payload, consultas parametrizadas, secrets fuera de Git.
- Pantallas de consentimiento, política de privacidad y explicación de que se trata de datos autodeclarados.
- Revisar normativa chilena aplicable a datos de salud **antes** de desplegar con información real; no asumir que una app familiar está exenta de todas las obligaciones.

---

## 7. Recordatorios y gestión de notificaciones

### Recordatorios locales (paciente)

- La API entrega agenda futura; el móvil persiste una ventana de eventos (p. ej. 14–30 días, ajustable según límites del SO).
- iOS: `UserNotifications` + `UNCalendarNotificationTrigger`/notificaciones no recurrentes y reconciliación de IDs. Evitar agendar más solicitudes de las permitidas; verificar las pendientes y reponer ventana en foreground/sync.
- Android: `AlarmManager` para alarmas sensibles al horario; manejar `POST_NOTIFICATIONS` y permisos de alarmas exactas cuando correspondan. No solicitar `USE_EXACT_ALARM` sin verificar políticas/eligibilidad de Google Play; fallback explícito si el usuario niega acceso.
- Reprogramar al editar pauta, cambiar zona horaria, reiniciar Android, iniciar sesión, revocar permisos y volver a foreground. Cancelar notificaciones obsoletas.
- Una notificación **abre la dosis específica**, no marca «tomada» por sí sola. Si se implementan acciones directas, deben pasar por el mismo flujo idempotente.
- UI debe mostrar estado: «Recordatorios habilitados», «Permiso denegado», «Precisión limitada» o «Sincronización pendiente».

### Alertas al cuidador (posterior)

- Worker detecta dosis **sin confirmar** tras plazo configurable, no la clasifica automáticamente como omitida.
- Enviar push al cuidador por APNs/FCM con texto discreto: «Hay una toma pendiente de confirmar», sin nombre del fármaco en pantalla bloqueada por defecto.
- Enviar aviso de stock bajo basado en calendario de futuras dosis, no solo promedio diario.
- Throttling, quiet hours, deduplicación y configuración por paciente. Worker usando outbox y reintentos, sin dobles envíos lógicos.

**Documentación oficial relevante:**
- Apple local notifications: https://developer.apple.com/documentation/UserNotifications/scheduling-a-notification-locally-from-your-app
- Android alarms: https://developer.android.com/develop/background-work/services/alarms
- Android permisos de alarmas: https://developer.android.com/about/versions/14/changes/schedule-exact-alarms
- Android permisos de notificaciones: https://developer.android.com/develop/ui/compose/notifications/notification-permission

---

## 8. Experiencia de producto y design system

### Paciente — navegación inicial (máximo 3 secciones)

1. **Hoy:** próxima toma destacada, lista por horario, estados claros y tres acciones principales.
2. **Historial:** calendario y registro de tomas de días anteriores, con corrección explícita.
3. **Ajustes:** recordatorios, permisos, cuenta y acceso del cuidador.

Pantalla «Hoy» debe priorizar: nombre claro, dosis indicada, hora local y botón principal **«Me lo tomé»**; acciones «Me lo tomé tarde» y «No me lo tomé» igual de accesibles sin penalización visual.

### Cuidador — web y móvil

El portal web es la herramienta completa, y crear o editar tratamientos sólo se hace allí. La vista móvil cubre el trabajo diario; su alcance está en F5b.

1. Pacientes vinculados y estado de consentimiento.
2. Tratamientos + formulario de pauta + inventario y reposiciones.
3. Agenda diaria por paciente, con diferencias entre confirmado, omitido y sin confirmar.
4. Histórico y métricas de adherencia declarada.
5. Alertas por stock y ausencia de confirmación.

### Visual y accesibilidad

- Fuente dinámica (Dynamic Type y escalado Android); mínimo 44pt de área táctil iOS y 48dp Android como referencia de diseño.
- Colores semánticos: `success`, `warning`, `danger`, `muted`; nunca depender del color sin texto/icono.
- Buen contraste, acciones con etiquetas explícitas, VoiceOver/TalkBack, soporte modo oscuro, estados de error/carga/vacío.
- Los iconos no reemplazan el texto de medicamento o dosis; evitar gamificación que induzca confirmaciones falsas.
- Tokens JSON compartidos como **referencia**, adaptados a `Color`, `Font`, `Shape`/modifiers de SwiftUI, Compose Theme y CSS variables. No intentar compartir JSX o UI rendering.
- La pantalla del paciente debe funcionar con una mano y con mala conectividad.

### Gamificación saludable (después del MVP)

- Indicadores de registro constante, calendario, logros por **participación honesta** y mensajes de apoyo.
- No quitar puntos por dosis omitidas, no romper rachas de modo punitivo, no poner metas que incentiven fingir consumos.
- Mostrar fuentes de las métricas y un aviso de que son **autodeclaradas**.

---

## 9. Métricas y proyección

### Adherencia declarada

```text
adherencia_declarada = dosis (taken + taken_late) / dosis evaluables
```

- Denominador: dosis programadas cuyo horario ya pasó, excluyendo las canceladas por cambios legítimos de pauta antes de ocurrir; reportar además el número `unconfirmed`.
- Tasa de confirmación = dosis con respuesta explícita / dosis evaluables.
- Puntualidad = dosis `taken` dentro de la ventana organizativa / dosis confirmadas como tomadas; no confundir con juicio médico.
- Mostrar siempre período, cantidad evaluable y proporción de datos sin confirmar; no llamar «adherencia clínica» a una autodeclaración.

### Inventario

```text
saldo = SUM(inventory_movements.quantity_delta)
```

- Para pauta simple: duración orientativa ≈ saldo / unidades previstas por día.
- Para pauta con días alternos, usar **simulación de próximas dosis reales** hasta el agotamiento.
- Alertar al cuidador a `low_stock_days_threshold` días y permitir registrar reposiciones / conteo físico.
- No asumir que stock negativo significa algo clínico; señalar inconsistencia y solicitar revisión, sin borrar acciones legítimas.

---

## 10. Fases de implementación — ejecutar en orden

### F0 — Bootstrap del monorepo

**Entregables**

- [x] Crear directorios de la sección 2, `.gitignore`, `.editorconfig`, `.env.example`, `README.md`, `AGENTS.md` y Makefile.
- [x] Inicializar Git si no está inicializado; no crear commits sin indicación del usuario.
- [x] Crear `compose.yaml` con PostgreSQL local, volumen persistente y healthcheck; credenciales de **desarrollo** documentadas en `.env.example`.
- [x] Inicializar `services/api` con Go, router, configuración, structured logging mínimo, `/healthz`, `/readyz` y shutdown gracioso.
- [x] Configurar migraciones (`goose`) y primera migración reversible de `users` únicamente o esquema mínimo probado.
- [x] Inicializar `packages/contracts/openapi.yaml` con `healthz`/`readyz` y reglas de nomenclatura.
- [x] Documentar comandos `make dev`, `make test`, `make lint`, `make migrate-up`, `make migrate-down`, `make generate` (los que no estén implementados deben fallar con mensaje útil, no simular éxito).
- [x] Preparar `apps/ios`, `apps/android`, `apps/web` como carpetas, sin inventar proyectos nativos no compilables.
- [x] Añadir pruebas smoke reales de salud/readiness y un GitHub Actions simple para Go cuando exista build validado.

**Definition of Done F0**

- `docker compose up -d db` inicia PostgreSQL sano.
- API arranca con variables documentadas; `/healthz` da 200; `/readyz` da 200 con DB y 503 sin DB.
- Migraciones `up/down/up` funcionan en DB limpia.
- `go test ./...` pasa y README explica onboarding en macOS.
- No secretos en Git ni dependencias innecesarias.

**NO construir UI, login completo, stock ni features de otras fases durante F0.**

### F1 — Dominio de tratamientos, dosis e inventario (backend primero)

- [x] Escribir tests de invariantes **antes** de los handlers.
- [x] Migraciones de pacientes/vínculos, tratamientos, revisiones de pauta, ocurrencias, eventos e inventario.
- [x] Índices, FKs, constraints, transacciones e idempotencia.
- [x] Servicios de casos de uso: `CreateTreatment`, `GenerateOccurrences`, `RecordDoseEvent`, `CorrectDoseEvent`, `ReplenishInventory`, `GetInventoryProjection`.
- [x] Generador de agenda que respeta fecha local, zona IANA y revisiones de pauta; definir horizonte fijo y regeneración incremental.
- [x] Tests de DST `America/Santiago`, fin/inicio de mes, cambios de pauta, duplicados, concurrencia, stock decimal y correcciones.
- [x] `sqlc` opcional si compensa la generación; elegirlo y fijar configuración antes de escribir queries repetidas. F1 usa pgx directamente, sin sqlc, según [ADR](docs/decisions/0002-f1-domain.md).

**DoD:** tests integrados con PostgreSQL reproducen confirmación única, retries idempotentes, omisiones, correcciones y stock correcto en carrera.

Evidencia local y límites de F1 en [verificación F1](docs/runbooks/f1-verification.md). Al cerrar F1 no había handlers de dominio, autenticación, UI ni worker implementados.

### F2 — Contrato HTTP, identidad y permisos

- [x] Definir esquemas OpenAPI para tratamientos, agenda, eventos, inventario y errores.
- [x] Implementar handlers + middleware de Firebase token verification con modo test seguro aislado.
- [x] Vínculo cuidador-paciente: invitación, aceptación, revocación y tests IDOR/BOLA.
- [x] Validación de entradas, rate limiting inicial, timeouts, request IDs y logs sin PII médica.
- [x] Generar/verificar clientes donde sea práctico, o mantener adaptadores tipados manuales hasta estabilizar contrato.

**DoD:** pruebas de API: usuario sin autorización recibe 403/404 seguros, paciente puede operar sus dosis, cuidador autorizado solo opera ámbitos habilitados.

Evidencia local y límites de F2 en [verificación F2](docs/runbooks/f2-verification.md). Sin UI, worker ni despliegue.

### F3 — Portal web mínimo del cuidador

- [x] React + Vite + TypeScript + Tailwind + shadcn/ui; TanStack Query/Router; Zod/forms según necesidades reales.
- [x] Login, lista de pacientes, invitaciones/consentimiento.
- [x] CRUD de tratamientos con formulario accesible y validador de unidades/horarios.
- [x] Inventario: reposición, ajuste físico, historial de movimientos y días estimados.
- [x] Calendario simple de dosis con estados diferenciados.
- [x] Tests de flujos críticos y estados de red (carga, vacío, error, sin permiso).

**DoD:** cuidador configura un paciente de prueba y crea una pauta que aparece en GET agenda API.

Evidencia local en [verificación F3](docs/runbooks/f3-verification.md). El DoD pasó con navegador, HTTP y PostgreSQL reales e identidad sintética aislada. Login contra un proyecto Firebase real pendiente de configuración. F4 no se inició.

### F4 — iOS SwiftUI MVP (primera app de paciente)

- [x] Crear proyecto iOS válido con Xcode; destino iOS 17+ sujeto a comprobación de dispositivos. Generado con XcodeGen fijado; compilado para iOS 17.0, ejecutado sólo en iOS 27.2.
- [x] `App / Core / DesignSystem / Features`, @Observable, NavigationStack, URLSession, cache/cola offline persistente.
- [x] Inicio de sesión seguro y consentimiento del paciente. Verificado con el emulador de Firebase; proyecto real pendiente.
- [x] Pantalla Hoy con 3 acciones, historial, corrección de registro, accesibilidad. Auditoría automática; sin revisión manual con VoiceOver.
- [x] Notificaciones locales, reconciliación de agenda y diagnóstico de permisos. Entrega verificada en simulador.
- [x] Reintentos offline idempotentes; estados «Pendiente de sincronizar» y conflictos visibles.
- [x] Tests unitarios/UI.
- [ ] Prueba manual en iPhone físico del flujo offline y las restricciones de notificación. Instalación y login sí verificados; ver pendientes.

**DoD:** flujo real iOS: cuidador crea → paciente recibe agenda → confirma offline → sincroniza → stock se descuenta una sola vez.

Evidencia en [verificación F4](docs/runbooks/f4-verification.md). **F4 cerrada el 2026-11-03 por decisión del usuario, con pendientes.** El flujo de la DoD pasó en simulador con API y PostgreSQL reales. En iPhone físico se verificaron instalación, login contra Firebase real y lectura desde la API; la confirmación offline no se ejecutó allí, así que la DoD no está acreditada en dispositivo. Al cerrar F4, F5 aún no se había iniciado.

### F5 — Android Jetpack Compose MVP

- [ ] Crear proyecto Android válido con Android Studio; minSdk 26 inicial, compatible con los teléfonos actuales declarados; target SDK vigente. Proyecto generado con Android CLI oficial, compilado con minSdk 26/target 37 y ejecutado en emulador. Instalación manual y revisión del usuario en Xiaomi 2107113SG con Android 13. Falta importación en Studio.
- [x] Single-Activity + Material 3, Navigation 3, ViewModel/StateFlow, Hilt si aporta, Retrofit/OkHttp, Room.
- [x] Replicar **comportamiento y design tokens**, no copiar mecánicamente UI de iOS.
- [x] Pantallas Hoy/Historial/Ajustes y login/consentimiento.
- [x] Notificaciones con permisos Android 13+/alarmas exactas cuando legítimamente aplican; fallback y rescheduling tras reboot. Verificados en emulador; límites físicos pendientes.
- [ ] Cola local idempotente, manejo de conflictos, test con Doze/ahorro de batería y dispositivo físico. Cola, conflictos, Doze y reboot verificados en emulador; dispositivo físico y ahorro de batería del fabricante pendientes.

**DoD:** mismo flujo real de F4 validado en Android físico, incluidos reintentos y permisos denegados. Es el flujo del que dependen los pacientes: la prueba offline pendiente en iPhone no lo sustituye.

Evidencia y comandos en [verificación F5](docs/runbooks/f5-verification.md). **F5 cerrada el 2026-11-03 por aceptación explícita del usuario: «Bastante bien, PASS F5».** Se instaló la app en Xiaomi 2107113SG con Android 13 y se conectaron Auth emulado y API local mediante ADB por Wi-Fi. La aceptación no acredita los casos físicos no ejecutados; los checkboxes pendientes conservan ese alcance. El flujo completo de stock pasó en emulador con HTTP/PostgreSQL reales. F5b y fases posteriores no se iniciaron.

### F5b — Vista de cuidador en iOS y Android

- [ ] Reemplazar en iOS el supuesto de que el paciente es siempre quien inició sesión; Android nace sin ese supuesto.
- [ ] Selector de paciente y cambio explícito entre «Mis tomas» y «Mis pacientes», con cachés y colas separadas por paciente.
- [ ] Ver agenda, historial, dosis sin confirmar e inventario de cada paciente vinculado.
- [ ] Registrar y corregir declaraciones, y reponer stock, con el mismo flujo idempotente.
- [ ] Crear invitaciones y revisar o revocar vínculos.
- [ ] Mostrar sólo las acciones permitidas: un cuidador con alcance `read` audita sin poder modificar. El backend sigue autorizando cada operación.
- [ ] Mostrar conflictos cuando dos cuidadores o el paciente registran la misma dosis.
- [ ] Decidir cómo crear cuentas y recuperar contraseñas, y cómo simplificar la aceptación de invitaciones para los pacientes.

**Fuera de alcance:** crear o editar tratamientos y pautas; siguen en el portal web.

**DoD:** un cuidador en cada plataforma gestiona dos pacientes con permisos distintos, un cuidador `read` no puede modificar y una revocación se refleja en su dispositivo.

### F6 — Alertas del cuidador y resiliencia

- [ ] Worker Go + outbox para avisos de dosis sin confirmar y stock próximo a agotarse.
- [ ] APNs/FCM con registro de dispositivos, privacidad del payload, deduplicación y control de frecuencia.
- [ ] Despliegue `staging` sin datos reales; backup y ensayo de restore.
- [ ] Reconciliación integral entre ledger, estado de dosis, agenda y dispositivos.
- [ ] Observabilidad: métricas de éxito/error de sync, latencia API, fallos del worker y retrasos de avisos **sin PII**.

**DoD:** ningún fallo temporal de worker/reintento crea consumo duplicado ni spam de push; existen runbooks de recuperación.

### F7 — Dashboard y gamificación

- [ ] Panel semanal/mensual con adherencia declarada, puntualidad, confirmación y `unconfirmed` visibles.
- [ ] Historial por tratamiento y paciente; filtros por rango.
- [ ] Predicción de reposición por calendario, configurable con antelación.
- [ ] Calendario visual de constancia sin castigos por omisiones y sin incentivar declaraciones falsas.
- [ ] Pruebas de denominadores, dosis canceladas, cambios de pauta y ventanas horarias.

### F8 — Endurecimiento y lanzamiento familiar

- [ ] Threat model: exposición de datos de salud, autorización por objeto, tokens, push, dispositivos perdidos.
- [ ] Revocación de cuidador y borrado local al cerrar sesión; exportación/borrado de datos.
- [ ] Auditar accesibilidad y compatibilidad de móviles reales.
- [ ] Revisar políticas de App Store / Play y normativa aplicable antes de publicar.
- [ ] CI por stack con runners macOS para iOS cuando se habilite; Android y Go en runners adecuados.
- [ ] Política de retención, backups/restores, incident response y checklist de release.

---

## 11. Matriz de pruebas de alto riesgo

| Caso | Esperado |
|---|---|
| Doble tap «Me lo tomé» | Un evento efectivo y un movimiento de consumo |
| Request enviada 3 veces por timeout | Una sola aplicación de idempotencia |
| Dos móviles confirman la misma dosis simultáneamente | Un resultado autoritativo, conflicto definido para el otro |
| «No me lo tomé» | No reduce stock |
| «Me lo tomé tarde» | Reduce cantidad correcta una sola vez y registra hora real |
| Corregir `taken` a `skipped` | Movimiento compensatorio, sin borrar auditoría |
| Corregir `skipped` a `taken` | Un único nuevo efecto de consumo |
| Sin conexión durante 24 h | Cola durable, feedback pendiente, sincronización eventual |
| Revocar cuidador | Acceso nuevo denegado y caché invalidada al volver a conectar |
| Cambiar pauta | Historial estable; solo se regeneran dosis futuras afectadas |
| Dosis de 0,5 comprimido | Decimal exacto; no error de float |
| Cambiar zona/DST Santiago | No duplicar ni desplazar silenciosamente ocurrencias |
| Quedan 3 unidades, pauta 2/día | Reposición proyectada de forma transparente |
| Android sin permiso de alarmas exactas | Explicación visible y fallback sin falsa garantía |
| iOS con límite de notificaciones pendientes | Programación en ventana con reconciliación |
| Fecha y hora manual incorrectas | Servidor valida reglas, mantiene `recorded_at` independiente |
| Stock físico distinto del calculado | Ajuste auditable, saldo reconciliado |
| Métrica semanal con 3 dosis sin confirmar | No contarlas como `skipped`; mostrar incertidumbre |

---

## 12. Entorno local y comandos esperados

**Dependencias host:** macOS, Xcode, Android Studio + SDK, Go, Docker/Colima o Docker Desktop, Node LTS, pnpm. Verificar instalaciones sin modificar configuración global del equipo si no es necesario.

**Primer arranque planeado después de F0:**

```bash
cp .env.example .env
docker compose up -d db
make migrate-up
make dev
# en otra terminal:
make test
```

**Ejemplo de `.env.example` sin credenciales reales:**

```dotenv
APP_ENV=development
HTTP_ADDR=:8080
POSTGRES_DB=medication_tracker
POSTGRES_USER=medication_dev
POSTGRES_PASSWORD=local_only_change_me
DATABASE_URL=postgres://medication_dev:local_only_change_me@localhost:5432/medication_tracker?sslmode=disable
AUTH_PROVIDER=firebase
FIREBASE_PROJECT_ID=replace-me
# En tests locales, auth fake solo bajo build/config explícito de test.
```

La configuración real de Docker debe coincidir con este ejemplo. `DATABASE_URL` local sin TLS es válido **solo para desarrollo**; en producción exigir TLS y gestión de secretos. La configuración Firebase que el cliente pueda exponer no incluye claves privadas de servicio. No poner `.env` ni credenciales de Firebase Admin en Git.

---

## 13. Política de ejecución para Codex

Al implementar, el agente debe:

1. Leer `PLAN.md`, `AGENTS.md` y el código existente antes de modificar.
2. Identificar fase actual; entregar primero el **cambio más pequeño verificable**.
3. No implementar una fase futura «por adelantado» sin que se solicite.
4. Seguir el stack elegido, evitar dependencias superfluas y mantener interfaces de repositorio donde aporten testabilidad.
5. Escribir pruebas del dominio sensibles a errores antes de los handlers.
6. No ocultar fallos con mocks, tests omitidos o código de relleno. Si falta Xcode/SDK/docker/permisos, documentar el bloqueo y dejar pasos concretos.
7. Prohibido introducir secrets, datos reales de salud o conexiones a producción.
8. Actualizar README, ADR y checkbox de Fase solamente cuando la acción esté realmente terminada y probada.
9. Al terminar cada sesión informar: archivos cambiados, decisiones, comandos ejecutados, tests, fallos conocidos y siguiente paso preciso.
10. No hacer commit, push, migración destructiva ni deploy sin autorización explícita.
11. Usar errores claros y retries seguros; API y DB deben ser consistentes incluso si el cliente cierra la app.
12. Optimizar por **corrección del dominio y accesibilidad** primero; sofisticación visual después.

### Primer prompt recomendado para Codex

> Lee `PLAN.md` completo. Ejecuta **exclusivamente F0 — Bootstrap del monorepo**, respetando las decisiones y límites del documento. Comienza inspeccionando el entorno macOS y las herramientas realmente instaladas. Crea un esqueleto mínimo que compile donde sea posible; inicia el backend Go, Docker Compose PostgreSQL, migraciones mínimas, health/readiness, Makefile, README y `AGENTS.md`. No implementes lógica médica, pantallas, Firebase ni servicios futuros. Escribe y ejecuta pruebas reales. Si falta una herramienta, explica el bloqueo sin simular que funcionó. No hagas commits. Cierra con un reporte de cambios, comandos, pruebas y siguiente fase sugerida.

---

## 14. Preguntas de producto que NO bloquean F0

Registrar decisiones más adelante, sin frenar el bootstrap:

- ¿Qué iPhone/versión de iOS y qué Android/versión usan realmente los pacientes? **Pacientes en Android con teléfonos actuales; cuidadores en iPhone y Android. Falta el modelo exacto para la prueba física.**
- ¿Quieren ambos un solo perfil compartido o cada paciente su propia cuenta? **Default seguro: una cuenta por persona.**
- ¿Qué tratamientos son diarios y cuáles tienen ciclos o pautas variables? **MVP: horarios fijos.**
- ¿Cuál es la unidad física para cada tratamiento y cómo se registra media unidad?
- ¿Quién autoriza a cuidadores y cómo se revoca en un dispositivo compartido?
- ¿Con cuánta anticipación debe llegar la alerta de stock bajo? **Default organizativo: 5 días, configurable.**
- ¿Cuánto tiempo después de la hora prevista se avisa al cuidador por «sin confirmar»? **Sin valor por defecto clínico; definirlo con la familia.**
- ¿Se permite usar biometría para reabrir la app tras el primer login?

---

## 15. Referencias técnicas oficiales

- SwiftUI / Observation: https://developer.apple.com/documentation/SwiftUI/Managing-model-data-in-your-app
- Notificaciones locales iOS: https://developer.apple.com/documentation/UserNotifications/scheduling-a-notification-locally-from-your-app
- Arquitectura Android: https://developer.android.com/topic/architecture/recommendations
- Navigation 3: https://developer.android.com/jetpack/androidx/releases/navigation3
- Alarmas Android: https://developer.android.com/develop/background-work/services/alarms
- Permisos de notificación Android: https://developer.android.com/develop/ui/compose/notifications/notification-permission
- Firebase ID token verification (Go): https://firebase.google.com/docs/auth/admin/verify-id-tokens
- OpenAPI Specification: https://spec.openapis.org/oas/latest.html

---

## 16. Checklist global de salida del MVP

- [ ] Padre/madre puede comprender la pantalla Hoy sin instrucciones técnicas.
- [ ] Cuidador configura y asigna tratamientos con consentimiento verificable.
- [ ] Tres acciones de dosis y correcciones auditables funcionan en iOS y Android.
- [ ] El stock coincide con movimientos y soporta consumos fraccionales.
- [ ] Sin conexión no se pierden declaraciones y no hay doble descuento.
- [ ] Los recordatorios explican permisos/limitaciones, sin promesas imposibles.
- [ ] La app diferencia `unconfirmed` de `skipped` y `taken_late` de `taken`.
- [ ] Privacidad, autorización, exportación/revocación y logs han sido revisados.
- [ ] Métricas transparentes y ningún incentivo para reportar datos falsos.
- [ ] Backups restaurables y pipeline de despliegue documentado.

**Primera entrega recomendada:** F0 completo y probado. Después F1: hacer correcta la semántica de dosis e inventario antes de añadir interfaces.
