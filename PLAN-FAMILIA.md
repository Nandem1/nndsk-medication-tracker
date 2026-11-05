# PLAN-FAMILIA.md — Modo familia de punta a punta

> **Estado al 2026-11-04:** P0 a P6 implementadas, verificadas en local y publicadas en `main`. P7 parcial: staging desplegado; aceptación en teléfonos pendiente. Evidencia en [familia-verification.md](docs/runbooks/familia-verification.md).
> **Punto de partida:** `main` en `6219d33`, más este plan.
> **Ejecutor previsto:** otro modelo, sin contexto de la conversación que originó este plan. Todo lo necesario está aquí, en `AGENTS.md` y en `PLAN.md`.
> **Regla de lectura:** lee `AGENTS.md`, `PLAN.md` y este archivo completos antes de cambiar nada. Las decisiones de la sección 2 ya están tomadas por el usuario o delegadas por él: no las reabras. Si el código contradice una suposición de este plan, sigue la intención, resuelve con el cambio más pequeño y registra la diferencia en el informe de cierre.

---

## Traspaso a Claude Opus 5.5

P4 quedó cerrada por Claude Opus 5.5 después de este traspaso. No se desplegaron los cambios de modo familia ni se instalaron en teléfonos físicos.

### Lo terminado

| Fase | Commits publicados en `main` | Evidencia |
|---|---|---|
| P0 | `396cb06` | ADR 0009, selector de iPhone físico y checks comunes |
| P1 | `3f9dfe2` | Migración 6 reversible, perfiles, nombres, autorización y materialización concurrente; integración PASS |
| P2 | `a3cef74`, `64921c7` | Portal, 24 unitarias y 11 E2E PASS; corrección de capturas para CI Linux |
| P3.1 y P3 | `4f7882b`, `02ec143` | Refactor separado, modo cuidador; 33 unitarias, 8 instrumentadas y 2 E2E Android PASS |
| CI Android | `8f47817`, `2a6afe0` | Rutas SDK y plataforma 37.0; CI Linux final PASS |

La rama de trabajo es `feat/modo-familia`. `main` y `origin/main` quedaron en `2a6afe0`. Los resultados completos y límites están en el runbook enlazado; no repetir P0 a P3 desde cero.

### P4 cerrada

El candidato de Codex se conservó. Faltaban ajustes de las pruebas, dos textos y un bug de `ConsentView`. La suite final, los comandos y los límites están en el [runbook](docs/runbooks/familia-verification.md). `.tmp/familia-p4` conserva una copia ya integrada; no volver a aplicarla.

### P5 cerrada

Inventario compartido en backend, web, Android e iOS. Resultados y diferencias en el runbook y en ADR 0009.

### Pendientes concretos, en orden

1. Ejecutar P7 completo. Faltan verificación final de todas las plataformas, migraciones up/down/up, staging, instalación/copia a teléfonos y escenario de aceptación de doce puntos. No marcar preparación para producción ni cumplimiento legal.

### Entorno local para retomar

- Base iOS desechable `medication_f4_familia_p4`, migrada a versión 6. Usar `medication_f4_familia_p5`, en versión 7. Migrar con el binario de goose y `GOOSE_DBSTRING`: `make migrate-up` lee `.env` y apunta a la base de desarrollo. API/proxy/Auth usan puertos 18083/18084/9099. Comprobar que estén libres antes de arrancar; identificar procesos antes de terminarlos.
- Simulador iPhone 17, iOS 27.2, UUID `63A76226-B64A-4067-9EA5-37C0B7B52600`. Es un simulador, no el iPhone físico del usuario.
- Definir `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` y `XCODE_DEVELOPER_DIR` con ese valor. El `xcrun` sin esa configuración no encuentra `simctl`. Esta instalación ejecuta el runtime pero no se encontró `Simulator.app`.
- XcodeGen local `.bin/xcodegen-2.46.0/xcodegen`; pasar su ruta absoluta si se ejecuta desde otro worktree. Generar el proyecto con el comando existente, nunca fabricarlo.
- El helper ignorado `.tmp/familia-db-run.py` inyecta la conexión local sin imprimirla. Usar `FAMILIA_TEST_DB=medication_f4_familia_p4`; no copiar URLs ni credenciales al plan o a logs. Firebase emulado requiere el JDK local `.tmp/android-tools/jdk-21.0.13+9/Contents/Home`.
- El runner acepta `IOS_E2E_ONLY=MedicationTrackerUITests/FamilyFlowUITests` para diagnóstico. Quitar ese filtro para la suite completa. Las pruebas usan API/PostgreSQL reales y Firebase Auth emulado; no verifican entrega real de correo.
- `.tmp/familia-resume.md` y `.tmp/familia-todo.md` conservan detalles locales adicionales. Los worktrees de fases anteriores contienen copias de cambios ya integrados; no mezclarlos con trabajo pendiente ni borrarlos sin comprobar su estado.

---

## 1. Objetivo

Una familia real debe poder usar la app como un producto terminado:

- **3 cuidadores** (el usuario en iPhone, una hermana en iPhone, otra en Android) siguen a **2 pacientes** (sus padres, en Android).
- Crear una cuenta, ponerse nombre y vincularse debe ser intuitivo y no requerir ayuda técnica.
- Todos ven «Mamá» y «Papá» en todas partes, nunca identificadores.
- Los padres **comparten físicamente la misma caja** cuando les recetan el mismo medicamento, así que el stock debe poder compartirse.

**Hecho se define en la sección 11.**

---

## 2. Decisiones cerradas

### Producto

| # | Decisión |
|---|---|
| D1 | Se implementa todo: F5b (vista de cuidador), nombres, vista conjunta, cuentas, vinculación simple, F5c (inventario compartido) y F8b (borrado y exportación). |
| D2 | **No se crea una entidad «familia».** Los vínculos paciente↔cuidador existentes ya modelan 3×2. «Familia» es una presentación, no una tabla. |
| D3 | Crear cuenta y recuperar contraseña se hacen dentro de las apps y el portal, con Firebase. Cada persona tiene su propia cuenta. |
| D4 | La invitación se comparte como código (WhatsApp, etc.) y se pega. **Sin enlaces con token ni QR.** `PLAN.md` prohíbe el token en URLs y un QR añadiría permiso de cámara y una dependencia. |
| D5 | Cada persona tiene **un solo nombre visible**, igual para todos. No hay alias por cuidador. |
| D6 | **Push real queda fuera** (sección 10). Mientras no esté configurado, la sección «Avisos remotos del cuidador» se **oculta** en Ajustes de ambas apps. |
| D7 | El inventario compartido exige **consentimiento de cada paciente** y nunca se activa automáticamente. |
| D8 | La UI del paciente en iOS le encanta al usuario: **no se rediseña**. Sólo se añade lo indicado aquí. Android sigue su misma estructura. |
| D9 | Crear o editar tratamientos sigue siendo sólo del portal web (`PLAN.md`, F5b). |

### Autorización del usuario para este plan

- **Datos:** todo lo local y de staging es de prueba. Se puede romper o perder.
- **Staging:** autorizado migrar (incluso destructivamente) y desplegar API y worker con `railway up`.
- **Producción:** prohibido. Sigue reservada, sin instancias.
- **Commits:** autorizados en la rama de este plan y merge a `main` al cerrar cada fase con pruebas en verde.
- **Push:** el usuario autoriza un push a `origin/main` al cerrar cada fase con pruebas en verde, porque dejó esta implementación de punta a punta en manos del ejecutor. Sólo `main` y la rama de trabajo. Nunca `--force`.
- **No autorizado:** datos reales de salud, publicar en tiendas, crear credenciales de proveedor, tocar producción.

---

## 3. Orden de ejecución

Una fase, un commit como mínimo, sus pruebas en verde, y recién entonces la siguiente.

| Fase | Contenido | Por qué en este orden |
|---|---|---|
| **P0** | Rama, ADR, entorno | Base |
| **P1** | Backend: perfiles, nombres, invitación con nombre, reintento de materialización | Todas las apps dependen de esto |
| **P2** | Web: cuentas, onboarding, nombres, invitación simple | La validación más barata del contrato |
| **P3** | Android: cuentas, onboarding, multi-paciente, vista cuidador, vista conjunta | Es el teléfono de los pacientes, y Room ya separa por paciente |
| **P4** | iOS: lo mismo, recreando la base local | Más riesgo; llega con el diseño ya validado |
| **P5** | F5c: inventario compartido en backend, web, Android e iOS | Toca el dominio; va sobre multi-paciente ya estable |
| **P6** | F8b: exportación desde apps y borrado de cuenta | Depende de saber salir de un inventario compartido |
| **P7** | Staging, instalación, documentación, cierre | Validación completa |

Rama: `feat/modo-familia`, desde `main`.

---

## 4. P0 — Preparación

1. Crear la rama. Comprobar herramientas según `AGENTS.md`.
2. Escribir `docs/decisions/0009-modo-familia.md` con las decisiones de la sección 2 y el diseño de P5.
3. En `PLAN.md`: las fases F5b, F5c y F8b remiten a este archivo. Marcar checkboxes sólo con evidencia.
4. Corregir `scripts/ios-run-device.sh`: su filtro puede elegir un simulador conectado en lugar del iPhone. Debe seleccionar sólo dispositivos físicos (por ejemplo, excluir los que no tengan identificador físico tipo `00008…`) y seguir aceptando `IOS_DEVICE`.

---

## 5. P1 — Backend de identidad y nombres

### Migración `00006_profiles.sql` (reversible)

```sql
ALTER TABLE users ADD COLUMN profile_completed_at TIMESTAMPTZ;
ALTER TABLE users ADD COLUMN profile_version BIGINT NOT NULL DEFAULT 1 CHECK (profile_version > 0);

CREATE TABLE user_profile_changes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  actor_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  client_operation_id UUID NOT NULL,
  previous_name TEXT,
  new_name TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX user_profile_changes_operation
  ON user_profile_changes(actor_user_id, client_operation_id);

ALTER TABLE invitations ADD COLUMN patient_name_hint TEXT
  CHECK (patient_name_hint IS NULL OR length(btrim(patient_name_hint)) BETWEEN 1 AND 60);
```

`display_name` ya existe y hoy siempre vale `'User'`. Con `profile_completed_at` nulo se trata como **sin nombre**: la API devuelve `null`, nunca `'User'`.

### Reglas de nombres

- 1 a 60 caracteres tras `trim`, sin saltos de línea. Se guarda tal cual, con mayúsculas.
- Editan el nombre: la propia persona, siempre; y un cuidador con vínculo activo y alcance `treatments`.
- **Gana la última escritura**, con `expected_version` (409 si cambió) y registro en `user_profile_changes`.
- Idempotente por `client_operation_id`, como el resto de mutaciones.
- El nombre no es dato médico, pero no se registra en logs.

### API (actualizar `packages/contracts/openapi.yaml` y DTOs)

| Método | Ruta | Cambio |
|---|---|---|
| GET | `/v1/me` | Añade `display_name` (nullable), `profile_version`, `profile_complete` |
| PUT | `/v1/me/profile` | Nuevo. `{client_operation_id, expected_version, display_name}` |
| PUT | `/v1/patients/{patientId}/profile` | Nuevo. Igual, autoriza alcance `treatments` |
| GET | `/v1/patients` | Añade `display_name` (nullable) y `profile_version` por paciente |
| GET | `/v1/caregiver-links` | Añade `patient_display_name` y `caregiver_display_name` (nullable) |
| POST | `/v1/invitations` | Acepta `patient_name_hint` opcional |
| POST | `/v1/invitations/preview` | Añade `caregiver_display_name` y `patient_name_hint` |
| POST | `/v1/invitations/accept` | Si el paciente no tiene nombre y hay `patient_name_hint`, lo aplica como nombre en la misma transacción, con registro de cambio. Nunca sobrescribe un nombre ya completado |

### Revocación por el cuidador

Comprobar que `DELETE /v1/caregiver-links/{linkId}` permite al propio cuidador dejar de seguir al paciente. Si no, habilitarlo con prueba: paciente o cuidador del vínculo; nadie más.

### Reintento de materialización (causa raíz)

`Agenda`/`FilteredAgenda` (`queries.go`) y el informe (`adherence.go`) materializan dosis bajo `RepeatableRead`. Si dos consultas coinciden sobre un paciente sin materializar, PostgreSQL da `40001`/`23505` y la API responde 409 en un **GET**. Con 3 cuidadores y varios dispositivos esto pasará en la práctica.

- Envolver esas transacciones en un reintento de hasta 3 intentos con espera corta (50–200 ms con jitter), sólo ante `40001`, `40P01` y `23505` de materialización.
- Prueba de integración: N consultas concurrentes sobre un paciente sin materializar → todas 200.
- La espera secuencial de la web en `dashboard.tsx` se mantiene; no estorba.

### Pruebas P1

Integración con PostgreSQL: propio edita; cuidador con `treatments` edita; cuidador sólo `read` → 403; ajeno → 403/404 seguro; versión vieja → 409; reintento idempotente; hint aplicado sólo si no hay nombre; `/v1/me` nunca devuelve `'User'`; concurrencia del punto anterior; migración up/down/up en base desechable.

---

## 6. P2 — Web

- **Acceso:** pantalla con «Iniciar sesión», «Crear cuenta» y «¿Olvidaste tu contraseña?» usando el SDK Firebase (`createUserWithEmailAndPassword`, `sendPasswordResetEmail`).
  - Contraseña de mínimo 8 caracteres en cliente.
  - Tras pedir recuperación, mostrar siempre el mismo mensaje exista o no la cuenta.
  - La identidad sintética de E2E (`@identity`) necesita los mismos métodos.
- **Onboarding:** si `profile_complete` es falso, pantalla «¿Cómo te llamas?» antes de todo. Después, «Mi perfil» en la navegación principal para cambiarlo.
- **Nombres:** `patientLabel` en `lib/sections.ts` usa `display_name`; sin nombre, «Paciente sin nombre». Quitar la `reference` con UUID de la cabecera del paciente y de las tarjetas. En consentimiento, mostrar nombres en lugar de `caregiver_id`.
- **Nombre del paciente:** con alcance `treatments`, botón «Cambiar nombre» en la cabecera del paciente.
- **Invitación simple (ver sección 7.4):** presets, nombre sugerido, código copiable y botón «Copiar mensaje».
- **Vista conjunta:** la ruta `/` deja de ser sólo tarjetas: cada paciente muestra «X de N registradas» de hoy, dosis sin confirmar y reposiciones por revisar.
- E2E: crear cuenta, onboarding, invitación con nombre, y el nombre visible al otro lado.

---

## 7. P3 — Android

### 7.1 Estructura

Separar `ui/PatientApp.kt` antes de añadir nada: `ui/App.kt`, `ui/today/`, `ui/detail/`, `ui/settings/`, `ui/caregiver/`, `ui/account/`, `ui/components/`. Sin cambio de comportamiento, con E2E en verde, en su propio commit.

### 7.2 Multi-paciente

- `Identity` añade registro (`accounts:signUp`) y recuperación (`accounts:sendOobCode` con `PASSWORD_RESET`). El emulador de Firebase los admite.
- `Repository`: `AppState` pasa a tener `own: Snapshot?`, `patients: Map<String, Snapshot>` y `accesses: List<PatientAccess>`. Eliminar el `singleOrNull` en `restore` y `login`, que falla con varias agendas.
- `syncLocked` recorre cada acceso de `/v1/patients`. Primero envía la cola de todos, luego refresca uno por uno, de forma secuencial.
- `PatientContext` conserva su forma. `record()` sigue siendo el único camino y mantiene su comportamiento: escribe en disco sin esperar la red.
- **Revocación por paciente:** un 403/404 en un paciente borra sólo su snapshot y lo retira de la lista. Sus operaciones quedan como `denied`, visibles en Ajustes: no se descartan en silencio. Un 401 sigue siendo global.
- **Recordatorios:** `Reminders.kt` (línea ~55) debe programar sólo la agenda propia (`patientId == actorId`). **Un cuidador nunca recibe recordatorios locales de la dosis de otro.** Prueba obligatoria.
- `context()` exige hoy alcance `doses` en el acceso propio, que siempre existe. Un acceso de cuidador sólo necesita `read`.
- Room: basta con el esquema actual. Si cambia, destructivo está permitido.

### 7.3 Navegación

Las pestañas dependen de lo que confirma el backend, nunca de un rol enviado por el cliente:

| Situación | Pestañas |
|---|---|
| Sin pacientes vinculados | Hoy, Historial, Ajustes (como hoy) |
| Con pacientes y sin tratamientos propios | Pacientes, Ajustes |
| Con ambos | Hoy, Historial, Pacientes, Ajustes |

Tras el onboarding, la pregunta «¿Cómo usarás la app?» con dos opciones grandes, «Tomo mis medicamentos» y «Cuido a alguien», sólo decide si se muestra Pacientes aunque aún esté vacía. Se guarda localmente y no da permisos. Se puede cambiar en Ajustes.

### 7.4 Pantallas

**Cuentas y onboarding (también iOS):**
1. Acceso con «Entrar», «Crear cuenta» y «¿Olvidaste tu contraseña?».
2. «¿Cómo te llamas?» si `profile_complete` es falso, con el nombre sugerido ya escrito si llegó por invitación.
3. «¿Cómo usarás la app?».

Ajustes añade **Mi perfil**: nombre y correo.

**Invitar (cuidador):**
1. Nombre del paciente: «¿Cómo se llama?» (por ejemplo, «Mamá»), opcional.
2. Permisos con tres opciones en lenguaje simple:
   - «Sólo mirar»: `read`.
   - «Ayudar a registrar»: `read`, `doses`.
   - «Administrar todo»: `read`, `treatments`, `doses`, `inventory`. **Opción por defecto.**
3. Resultado: código y botón «Compartir», con el selector nativo y este mensaje:
   > Hola, te invito a Mis tomas. Abre la app, entra en Ajustes › Acceso de cuidadores y pega este código: `<token>`. Vence en 24 horas.

El código se muestra una sola vez. Mantener la regla actual: cada envío crea otra invitación. Un fallo de red no reutiliza el token.

**Aceptar (paciente):**
- Botón «Pegar código» que lee el portapapeles sólo al tocarlo.
- Extraer el token con la expresión `[A-Za-z0-9_-]{43}` para que funcione aunque se pegue el mensaje completo. Confirmar en P1 que el token tiene esa forma; la prueba web actual usa `^[\w-]{43}$`.
- Revisión: «**{caregiver_display_name}** podrá: …», vencimiento y nombre sugerido. Acción: «Autorizar».
- Lista de cuidadores por nombre, con «Quitar acceso».

**Pacientes (vista conjunta):** una tarjeta por paciente con nombre, «X de N registradas», cuántas sin confirmar y cuántas reposiciones por revisar. Más «Invitar a alguien». Estado vacío claro. Los datos salen del snapshot guardado y muestran «Datos guardados de: …» sin conexión.

**Paciente (detalle):** título con su nombre y tres secciones:
- **Hoy:** usa `todayPlan`. La tarjeta se titula «Falta registrar» o «Próxima toma», **nunca «Ahora toca»**, y las acciones van en tercera persona: «Se lo tomó», «Se lo tomó tarde», «No se lo tomó». Misma hoja tardía.
- **Historial:** usa `historyDays`, con corrección.
- **Inventario:** saldo confirmado, estimado (borde punteado) y días de cobertura; fecha de revisión; «Registrar reposición» y «Conteo físico»; movimientos con cantidades como texto.

Menú del paciente: cambiar nombre (con `treatments`) y «Dejar de seguir».

**Permisos:** sin `doses` no hay acciones; sin `inventory`, no hay reposición; con sólo `read`, aviso «Tu acceso permite sólo mirar». El backend sigue autorizando: si responde 403, mostrarlo sin ocultarlo.

**Conflictos:** dos cuidadores registrando la misma dosis produce 409 y aparece en «Por revisar», con el mismo flujo actual.

**Reposición y conteo:** usar los endpoints existentes con clave idempotente que se conserva al reintentar. **No se encolan offline:** sin conexión, los botones explican que requieren internet. Sólo las declaraciones van a la cola.

### 7.5 Ajustes

Ocultar «Avisos remotos del cuidador» si no está configurado (D6). Un `RemotePush.configured` simple basta.

### 7.6 Pruebas P3

- Unitarias: pestañas según accesos, permisos por alcance, extracción del token del mensaje, recordatorios sólo propios.
- E2E: ampliar `AndroidE2ETest` (o añadir una clase) con: crear cuenta; onboarding; invitar con nombre; aceptar pegando el mensaje; ver al paciente por nombre; declarar como cuidador; cuidador `read` sin acciones; revocación que retira al paciente; conflicto entre dos actores.
- Reutilizar el modo `stall` del proxy para comprobar que declarar como cuidador también escribe en disco de inmediato.

---

## 8. P4 — iOS

Mismo comportamiento que P3, con estas diferencias:

- **Base local:** `LocalStore` no tiene columna de paciente: `doses`, `treatments`, `inventory` y `links` son globales, y `meta` guarda un `patient_id`. Añadir `patient_id` a esas tablas y a `operations`. Usar `PRAGMA user_version`: si es menor que la nueva versión, **borrar y recrear** (autorizado, son datos de prueba). Mantener la comprobación de propietario `owner_uid` y la limpieza del logout.
- **`SyncEngine`:** sustituir `resolvePatient()` por el recorrido de accesos, en serie, conservando la cola serial.
- **`AppModel`:** `snapshot` sigue siendo la agenda propia, para no tocar las vistas del paciente. Añadir `accesses` y `patients: [String: LocalSnapshot]`.
- **`ReminderPlanner`:** sólo agenda propia.
- **Vistas nuevas:** `Features/Caregiver/`, `Features/Account/`. `MainTabs` calcula las pestañas igual que en 7.3.
- **`IdentityStore`:** añade registro y recuperación por REST, como Android.
- **Sin cambios visuales en** Hoy, detalle, historial y la hoja tardía del paciente (D8). Sí se añaden Mi perfil y la ocultación de avisos remotos en Ajustes.
- **Pruebas:** unitarias equivalentes a 7.6, y UI tests para cuenta, onboarding, invitación, cuidador con permisos y revocación. Los identificadores de accesibilidad existentes no cambian.

---

## 9. P5 — F5c: Inventario compartido

### 9.1 Modelo: cuentas conservadas, saldo común

**Cada tratamiento conserva su cuenta y sus movimientos.** Un inventario compartido agrupa cuentas. El saldo común es la suma de los movimientos de todas sus cuentas.

Motivo: `inventory_accounts.treatment_id` es `UNIQUE`, los movimientos tienen FK compuesta `(inventory_account_id, treatment_id)` y la unicidad de consumo cuelga de `source_dose_event_id`. Así, consumo único, reversas, reconciliación y exportación por paciente **siguen funcionando sin cambios**.

Alternativas descartadas: que una cuenta tenga varios tratamientos (rompe esas FK y la exportación por paciente) y las transferencias manuales entre cuentas (no refleja una caja real y desordena la proyección).

### 9.2 Migración `00007_inventory_pools.sql` (reversible)

```sql
CREATE TABLE inventory_pools (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  status TEXT NOT NULL CHECK (status IN ('pending','active','dissolved')),
  low_stock_days_threshold INTEGER NOT NULL DEFAULT 5
    CHECK (low_stock_days_threshold BETWEEN 0 AND 30),
  created_by UUID REFERENCES users(id) ON DELETE SET NULL,
  client_operation_id UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  activated_at TIMESTAMPTZ,
  dissolved_at TIMESTAMPTZ,
  UNIQUE (created_by, client_operation_id)
);
CREATE TABLE inventory_pool_members (
  pool_id UUID NOT NULL REFERENCES inventory_pools(id) ON DELETE CASCADE,
  account_id UUID NOT NULL REFERENCES inventory_accounts(id) ON DELETE CASCADE,
  patient_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  status TEXT NOT NULL CHECK (status IN ('pending','accepted','declined','left')),
  decided_by UUID REFERENCES users(id) ON DELETE SET NULL,
  decided_at TIMESTAMPTZ,
  PRIMARY KEY (pool_id, account_id)
);
-- Una cuenta está como máximo en un inventario vivo.
CREATE UNIQUE INDEX inventory_pool_members_live
  ON inventory_pool_members(account_id) WHERE status IN ('pending','accepted');
```

Añadir el motivo `pool_transfer` a los checks `inventory_movements_reason_check` y `inventory_movements_sign_check` (ver `00004_caregiver_portal.sql`). Admite cantidades de cualquier signo, distintas de cero. Etiqueta: «Traspaso por inventario compartido».

### 9.3 Reglas

**Crear:**
- Lo propone quien tenga alcance `inventory` sobre **todas** las cuentas. Se aceptan 2 o más cuentas distintas, no archivadas y sin inventario vivo.
- **Mismo medicamento, validado por el servidor:** `name`, `strength_label` y `form` iguales tras `trim`, minúsculas y colapsar espacios; `unit` idéntica. Sin coincidencia aproximada ni quitar acentos: «Losartán» y «Losartan» **no** coinciden, y el mensaje lo explica. Si no coincide, 422.
- Permitido entre dos tratamientos del mismo paciente; entonces basta su consentimiento único.

**Consentimiento:**
- Cada paciente decide por sí mismo. Si quien propone es uno de los pacientes, su parte queda aceptada.
- **Un cuidador no puede aceptar en nombre de un paciente.**
- Mientras haya pendientes, el estado es `pending` y **los saldos siguen separados**.
- Con todo aceptado pasa a `active`. El umbral inicial es el menor de los miembros.
- Si alguien rechaza y quedan menos de 2 cuentas, el inventario se disuelve.

**Saldo:** los saldos se suman tal cual al activarse. La pantalla sugiere hacer un conteo físico a continuación.

**Consumo:** cada dosis sigue descontando la **cantidad prevista** de **su propia cuenta**. Una omitida o sin confirmar no descuenta.

**Reposición:** el movimiento va a la cuenta desde la que se registra.

**Conteo físico:** `expected_balance` se compara con el saldo común, bajo bloqueo. El ajuste va a la cuenta desde la que se registra.

**Corrección tras salir:** la reversa va a la cuenta de la dosis, no al inventario del que salió.

**Salir:** cualquier paciente miembro, o quien tenga alcance `inventory` sobre esa cuenta.
- **La caja se queda con quienes permanecen:** en la misma transacción, la cuenta que sale recibe `pool_transfer` por `-saldo` y la primera que permanece por `+saldo`. Se omite si el saldo es 0.
- Quien sale queda en 0, con aviso «Registra el stock que tienes».
- Si queda una sola cuenta, se disuelve y conserva su saldo.

**Tratamiento archivado:** sigue en el inventario, y sus dosis futuras ya no se proyectan.

### 9.4 Concurrencia (obligatorio)

Crear `lockInventory(tx, accountID)` en `service.go` y usarlo en todo sitio que hoy bloquea una cuenta (`events.go:74`, `service.go:191`, `portal.go`, `stock_threshold.go`, y `alerts.go` al evaluar stock):

1. Lee la membresía viva de la cuenta.
2. Si es `active`, bloquea la fila del inventario `FOR UPDATE`, **vuelve a leer** la membresía, y luego bloquea las cuentas ordenadas por `id`.
3. Si no, bloquea sólo la cuenta.

Orden global: **inventario, luego cuentas por id**, para evitar interbloqueos.

`balance()` (`service.go:183`) se separa en saldo de cuenta y **saldo efectivo**, que es el común si el inventario está activo. `DoseResult.balance` y la proyección devuelven el efectivo.

### 9.5 Proyección

`inventoryProjection` (`projection.go`) se refactoriza:
- Extraer la planificación de un tratamiento a `plannedDoses(tx, treatmentID, from, through)`.
- Con inventario activo, unir las dosis de **todos** los tratamientos miembros, cada uno en su zona, y ordenarlas por instante.
- La exclusión de dosis ya declaradas debe usar clave **(tratamiento, instante)**. Hoy es sólo el instante: con dos pacientes a la misma hora una ocultaría a la otra. **Esta prueba es obligatoria.**
- `replenish_on` y `low_stock` usan la zona de la cuenta consultada y el umbral del inventario.

### 9.6 Privacidad

Un cuidador puede tener acceso a un solo paciente del inventario. Lo que ve del otro:

| Dato | Con acceso al otro paciente | Sin acceso |
|---|---|---|
| Saldo común y cobertura | Sí | Sí |
| Nombre del otro miembro | Sí | «otra persona» |
| Movimientos del otro | Completos, con su nombre | Sólo cantidad y **fecha sin hora**, motivo `shared_activity`, sin autor, nota ni tratamiento |

Implementar en el servidor, no en el cliente. La exportación de una cuenta incluye sólo sus propios movimientos.

### 9.7 API

| Método | Ruta | Uso |
|---|---|---|
| GET | `/v1/inventory/{accountId}/pool-candidates` | Cuentas compatibles sobre las que el actor tiene `inventory` |
| POST | `/v1/inventory-pools` | `{client_operation_id, account_ids}` |
| GET | `/v1/inventory-pools/pending` | Decisiones pendientes del actor como paciente |
| POST | `/v1/inventory-pools/{id}/decision` | `{client_operation_id, decision: accept\|decline}`. Sólo el propio paciente |
| POST | `/v1/inventory-pools/{id}/leave` | `{client_operation_id, account_id}` |
| GET | `/v1/patients/{id}/inventory` | Añade `pool: {pool_id, status, members: [{patient_display_name, you}]}` o `null` |
| GET | `/v1/inventory/{accountId}/movements` | Con inventario activo, incluye a los demás miembros según 9.6, con campo `shared: true` |
| POST | `/v1/inventory/{accountId}/threshold` | Con inventario activo, actualiza el umbral común |

**Alertas:** `alerts.go` debe avisar de stock bajo **una sola vez por inventario**, usando la cuenta de menor `id` como representante, para no duplicar por cuidador. Push sigue apagado, pero la outbox debe quedar correcta.

**Reconciliación:** `reconcile.go` añade una comprobación: ninguna cuenta está en más de un inventario vivo.

### 9.8 Clientes

**Android e iOS, paciente:** en Hoy, una tarjeta discreta cuando hay decisión pendiente:
> {nombre} propone compartir **Losartán 50 mg** con **Papá**. Compartirán el mismo saldo y podrán ver cuánto queda.

Con «Aceptar» y «Ahora no». En el detalle y en Ajustes, «Inventario compartido con {nombre}» y «Dejar de compartir».

**Android e iOS, cuidador, y web:** en el detalle de la cuenta:
- «Compartir con…» lista los candidatos.
- Estado «Esperando a {nombre}».
- Chip «Compartido con {nombre}» y saldo común.
- Fila de movimiento compartido en texto neutro.
- Al dejar de compartir, confirmar explicando que el saldo se queda con quien permanece.

La lógica de estimado local no cambia: sigue restando sólo las declaraciones pendientes de este teléfono.

### 9.9 Pruebas obligatorias (escribirlas antes que los handlers)

Integración con PostgreSQL:
1. **Carrera:** dos pacientes declaran a la vez sobre un inventario con saldo justo. Un consumo por dosis, saldo exacto.
2. Reintentos idempotentes sin doble consumo.
3. Decimales exactos: 0,5 + 0,25.
4. Corregir `taken`→`skipped` restaura el saldo común.
5. Proyección combinada con dos zonas, incluida la misma hora en dos pacientes.
6. DST de `America/Santiago`.
7. Consentimiento: cuidador no puede aceptar por el paciente; pendiente mantiene saldos separados; rechazo disuelve.
8. Validación: distinta concentración o unidad → 422.
9. Salir: traspaso correcto, saldo 0 en quien sale, suma conservada, disolución.
10. Privacidad de 9.6: cuidador con un solo paciente no ve autor, hora ni nota.
11. Conteo concurrente con consumo.
12. Sin interbloqueo: carrera creando, saliendo y declarando.
13. BOLA/IDOR: ajeno recibe 403/404 en todas las rutas.
14. Alerta de stock única por inventario.

E2E en Android, iOS y web: proponer, aceptar, consumir desde ambos pacientes, ver el saldo común en todos, salir.

---

## 10. P6 — F8b y fuera de alcance

### 10.1 Exportación desde las apps

Ajustes › Mi perfil › «Descargar mis datos» llama a `GET /v1/me/export`, guarda el JSON en archivo temporal privado, abre el selector nativo de compartir y lo borra después. Explicar que el archivo contiene datos de salud. No se registra en logs.

### 10.2 Borrado de cuenta

Antes de implementar, leer `docs/runbooks/f8-security.md` (decisiones de retención y separación de titular y autor) y `docs/runbooks/f8-release.md`.

`DELETE /v1/me` con `{client_operation_id, confirm: "BORRAR"}`, en una sola transacción:

1. Sale de todo inventario compartido (regla de 9.3).
2. Revoca los vínculos como paciente y como cuidador.
3. Elimina su historia como paciente: tratamientos, dosis, eventos, cuentas, movimientos, dispositivos, preferencias.
4. **La historia de otros pacientes no se borra:** donde esta persona sea autor, `users` se conserva anonimizada: `display_name` «Cuenta eliminada», `auth_provider_uid` sustituido por un valor aleatorio, sin correo.
5. Hay FK `ON DELETE RESTRICT`: resolver el orden explícitamente; no cambiar `RESTRICT` por `CASCADE` en tablas de historia.

Después de confirmar: borrar el usuario en Firebase con Admin. Si falla, se puede reintentar sin error y se informa.

Clientes: Mi perfil › «Eliminar mi cuenta», con consecuencias claras, escribir «BORRAR», y limpieza local completa. Sin iconos ambiguos.

Pruebas: integración de todo lo anterior, incluido que la historia de otro paciente queda intacta y el ledger reconcilia.

**Sigue pendiente después:** supresiones tras restaurar backups (`f8-release.md`). Documentarlo; no afirmar cumplimiento legal.

### 10.3 Fuera de alcance

No implementar. Dejar listados en el informe final:

- Push real con FCM y APNs: requiere credenciales y firma que el usuario debe crear.
- Portal desplegado, producción, publicación en tiendas.
- Revisión legal de datos de salud en Chile, antes de cualquier dato real.
- Aceptar la política de retención.
- Revisión manual en teléfonos físicos: la hace el usuario.
- Pautas nuevas (PRN, ciclos), biometría.

---

## 11. P7 — Cierre y definición de hecho

### Comandos obligatorios en la última versión del código

```sh
make tokens-check && make test && make lint && make build
TEST_DATABASE_URL=<base medication_f1_* migrada> make test-integration
TEST_DATABASE_URL=<base medication_f3_* migrada> make test-web-e2e
make test-android && make lint-android && make test-android-device
ANDROID_SERIAL=<emulador> TEST_DATABASE_URL=<base medication_f4_* migrada> make test-android-e2e
make test-ios && make lint-ios
TEST_DATABASE_URL=<base medication_f4_* migrada> make test-ios-e2e
```

Migraciones: up, down y up en base desechable. Revisar el nombre de las bases contra `docs/runbooks/development.md`.

### Despliegue a staging

Sigue `docs/runbooks/railway-staging.md`. Migrar y desplegar API y worker. Comprobar `healthz` y `readyz`, y que los endpoints protegidos exigen token. Si conviene, reiniciar los datos de staging: son de prueba.

### Dejar las apps listas para el usuario

- **iPhone:** `IOS_DEVICE=<udid> make run-ios-device`. `apps/ios/Config/Local.xcconfig` ya apunta a staging.
- **Android:** el usuario instala a mano porque el Xiaomi bloquea `adb install`. Compilar y copiar a Descargas:
  ```sh
  sh scripts/android-gradle.sh :app:assembleDebug -PapiBaseUrl=<staging> -PfirebaseApiKey=<clave pública>
  adb -s <serial> push apps/android/app/build/outputs/apk/debug/app-debug.apk /sdcard/Download/medication-tracker-staging.apk
  ```
  La URL de staging está en `apps/web/.env.local` (`API_PROXY_TARGET`) y la clave en `Local.xcconfig`. Ninguna se copia a archivos versionados ni a logs. Comprobar `BuildConfig.java` antes de copiar.

### Documentación

Actualizar `docs/00-home.md`, los mapas de cada app, `packages/contracts/openapi.yaml`, ADR 0009, y crear `docs/runbooks/familia-verification.md`. Marcar en `PLAN.md` sólo lo evidenciado. Aplicar `living-architecture` en modo MAINTAIN, y pedir `living-architecture REVIEW` antes del último merge porque cambia el dominio.

### Hecho significa

**Escenario de aceptación con datos sintéticos, en staging o local:**

1. Una persona crea cuenta en Android, se llama «Mamá». Otra crea cuenta y se llama «Papá».
2. Un cuidador crea cuenta en iPhone, invita con nombre sugerido y comparte el código. El paciente lo pega completo y autoriza. Cuidador y paciente ven los nombres, nunca un UUID.
3. Otros dos cuidadores se vinculan a ambos, uno de ellos sólo con «Sólo mirar», y no ve acciones.
4. El cuidador crea en el portal el mismo medicamento para ambos, con stock inicial.
5. «Pacientes» muestra a Mamá y Papá con «X de N registradas».
6. El cuidador propone compartir la caja. Ambos aceptan en su teléfono. Todos ven el mismo saldo.
7. Mamá confirma sin conexión. Se guarda. Al reconectar, el saldo común baja **exactamente una vez**.
8. Dos cuidadores registran la misma dosis de Papá: un resultado, conflicto visible para el otro.
9. Mamá revoca a un cuidador: pierde el acceso y su dispositivo retira a Mamá.
10. Papá deja de compartir: traspaso auditable, suma conservada.
11. Una cuenta se elimina sin dañar la historia de nadie más.
12. Ningún cuidador recibe recordatorios locales de dosis ajenas.

**Fallar cualquiera de estos puntos significa que no está hecho.** Si algo no se puede ejecutar, repórtalo como no verificado.

### Informe final obligatorio

Separa implementado, validado y pendiente. Incluye: comandos y resultados, migraciones, qué se desplegó, qué no se pudo ejecutar, diferencias con este plan, Architecture Impact, y lo que el usuario debe probar en teléfonos físicos.

---

## 12. Lo que ya se aprendió en este repositorio

Evita repetir estos errores, todos ocurridos:

- **Reglas de UI ya decididas:** omitida es neutra. `danger` sólo para conflicto o rechazo. «Guardada, falta enviar» usa `syncFg`/`syncBg`. Sin rachas ni gamificación.
- **`OutlinedButton` en Compose** hereda un color atenuado: fijar `contentColor` con el token de texto, o las acciones secundarias quedan penalizadas visualmente.
- **Los E2E no miden apariencia:** tras un cambio visual, captura la pantalla real y mírala. Para capturar hojas modales en Android usa `screencap`; `captureToImage` toma la ventana equivocada.
- **Una acción desactivada por `busy` se traga toques** en cada sincronización. No desactivar acciones del paciente por sincronizar.
- **Consultas paralelas de materialización** daban 409 en un GET (se resuelve en P1).
- **El rate limit de la API** responde 429 si un script de prueba declara muchas dosis seguidas.
- **`dose.today()` y similares** usan la zona de la pauta, no la del dispositivo. El Historial llegó a excluir las dosis de hoy por error.
- **Fechas en la web:** Agenda, alertas y panel Hoy usan la fecha del navegador. Si tocas esto, usa la zona del paciente.
- **`make test-android-e2e` exige el lockfile al día.** Si cambias dependencias, regenera con `--write-locks` en las configuraciones `debug` y `e2e`, y revisa que no entren versiones inesperadas.
- **El script iOS `ios-e2e.sh` y `android-e2e.sh` usan los puertos 9099, 18083 y 18084.** Sin servidores sueltos antes de lanzarlos.
- **`make test-ios-e2e` sólo desinstala la app si `IOS_DESTINATION` usa `name=`.** Con `id=` el permiso de notificaciones sobrevive entre corridas y falla el test de recordatorios, también sobre código sin cambios. Usar el destino predeterminado.
- **`Local.xcconfig`, `.env` y `apps/web/.env.local` no se versionan.** Comprueba con `git check-ignore` antes de editarlos.
