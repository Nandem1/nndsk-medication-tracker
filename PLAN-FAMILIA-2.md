# PLAN-FAMILIA-2.md — La familia como modelo

> **Estado al 2026-11-05:** aprobado por el usuario e iniciado en la rama `feat/familia-v2`.
> **Origen:** el usuario pidió en esta sesión reemplazar los vínculos uno a uno por familias, y aprobó la recomendación completa.
> **Regla de lectura:** este plan reabre, por decisión explícita del usuario, las decisiones D2, D4 y D7 de [`PLAN-FAMILIA.md`](PLAN-FAMILIA.md). El resto de `AGENTS.md`, `PLAN.md` y `PLAN-FAMILIA.md` sigue vigente.

## 1. Problema

Con 3 cuidadores y 2 pacientes hacían falta 6 vínculos, y cada padre pegaba 3 códigos de 43 caracteres. Esa es la parte más difícil para un adulto mayor.

## 2. Decisiones

| # | Decisión |
|---|---|
| G1 | **Todo es una familia.** Una persona crea una familia y queda como administradora. Un cuidador con un solo paciente es una familia de dos. |
| G2 | **Los vínculos se derivan de la pertenencia.** `caregiver_links` deja de crearse a mano: se recalcula en la misma transacción que cambia la familia. La autorización de cada endpoint, las alertas, la exportación y el borrado siguen leyendo los vínculos sin cambios. Es el cambio más pequeño que conserva el modelo de autorización ya probado. |
| G3 | **Roles por familia:** `admin` (todo, más invitar y quitar), `caregiver` (ver, registrar tomas e inventario), `observer` (sólo mirar) y `patient` (sus propios datos). Un paciente no ve los datos de otro paciente. |
| G4 | **El paciente consiente una vez, al unirse.** Ve quién está en la familia, recibe aviso de quién se une y puede salir cuando quiera. Los cuidadores nuevos heredan a los pacientes sin otra aprobación. |
| G5 | **Ingreso por enlace o QR, con el código como respaldo.** El enlace usa el esquema propio `mistomas://unirse#<token>`. El token va en el fragmento, nunca llega a un servidor por la URL y se canjea por POST. Las invitaciones son de un solo uso, con rol, y vencen en 7 días. Reemplaza D4. |
| G6 | **Misma caja.** Quien tenga alcance `inventory` sobre ambas cuentas marca «Usan la misma caja» y el inventario queda activo de inmediato, con un conteo físico obligatorio en la misma transacción. Desaparecen las propuestas pendientes. Cada paciente puede separarse. Reemplaza D7. |
| G7 | **La familia nunca queda sin administración.** Si sale la última persona administradora y quedan cuidadores, asume el cuidador más antiguo. Las familias no se borran: conservan su historia. |
| G8 | **Una persona puede estar en varias familias.** El vínculo resultante une los alcances de todas. |
| G9 | Se retiran `POST /v1/invitations`, `/v1/invitations/preview`, `/v1/invitations/accept`, `GET /v1/caregiver-links` y `DELETE /v1/caregiver-links/{id}`. Las preferencias de alerta siguen por vínculo. |
| G10 | **Datos:** local y staging son de prueba. La migración revoca los vínculos sin familia y disuelve las propuestas pendientes. Producción no se toca. |

## 3. API

| Método | Ruta | Uso |
|---|---|---|
| GET | `/v1/families` | Familias del actor, con miembros, roles y fecha de ingreso |
| POST | `/v1/families` | `{client_operation_id, name}`; el actor queda `admin` |
| POST | `/v1/families/{familyId}/invitations` | `{client_operation_id, role, patient_name_hint?}`; sólo `admin` |
| POST | `/v1/family-invitations/preview` | `{token}`: familia, quien invita, rol, miembros y vencimiento |
| POST | `/v1/family-invitations/accept` | `{client_operation_id, token}`; idempotente |
| DELETE | `/v1/families/{familyId}/members/{userId}` | Salir, o quitar si el actor es `admin` |
| POST | `/v1/inventory-pools` | `{client_operation_id, account_ids, counted_account_id, counted_quantity}`; queda `active` |

## 4. Fases

1. **Backend:** migración `00009_families.sql` reversible, servicio, HTTP, contrato, DTO y pruebas de integración escritas primero.
2. **Pruebas más rápidas:** límite de solicitudes configurable sólo en los servidores E2E, sin las esperas de 61 s y con servidores web compartidos.
3. **Web:** familia, invitación con enlace, ingreso, misma caja y la renovación visual pedida.
4. **Android** y 5. **iOS:** familia, ingreso por enlace o código, QR para configurar en persona, aviso de miembros nuevos y misma caja.
6. **Cierre:** staging migrado y desplegado, instalación en el iPhone y documentación.

## 5. Pruebas obligatorias (antes de los handlers)

Crear familia; invitar con cada rol; sólo `admin` invita y quita; aceptar es idempotente y de un solo uso; token vencido o ajeno da conflicto; el paciente une a los cuidadores existentes y un cuidador nuevo hereda a los pacientes; `observer` sólo lee; un paciente no lee a otro; salir revoca; quitar revoca; promoción del último `admin`; unión de alcances con dos familias; BOLA/IDOR entre familias; misma caja activa con conteo exacto, decimales exactos y concurrencia con consumo.

## 6. Fuera de alcance

Cambiar el rol de un miembro (se quita y se vuelve a invitar), permisos distintos por paciente dentro de una familia, enlaces universales con dominio propio y push real.
