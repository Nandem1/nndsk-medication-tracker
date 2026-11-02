# F2: identidad y autorización HTTP

## Decisión

La API conserva `net/http` y los servicios concretos sobre pgx. Firebase Admin verifica el ID token y el backend resuelve su UID a una identidad interna. Los permisos proceden de PostgreSQL.

La autorización pertenece a la transacción de aplicación. Se ejecuta antes de recuperar una respuesta idempotente y resuelve el paciente desde el recurso solicitado. El vínculo activo queda bloqueado en modo compartido hasta completar la operación. La revocación actualiza ese vínculo y espera las operaciones que ya fueron autorizadas.

Un guard HTTP separado sería más pequeño inicialmente, pero dejaría una carrera entre la comprobación y la escritura. Tampoco protegería la recuperación de respuestas después de revocar un vínculo. No se añade una capa de repositorios ni una unidad de trabajo nueva.

## Contrato y consentimiento

Los adaptadores HTTP usan DTOs con nombres `snake_case`. Las cantidades viajan como cadenas decimales y se convierten a las milésimas exactas del dominio. Los structs internos de F1 no son el contrato público.

Los alcances son `read`, `treatments`, `doses` e `inventory`. Los permisos de escritura requieren también `read`, porque las respuestas contienen datos del paciente. El paciente opera su propia información. Un cuidador necesita un vínculo activo con el alcance de la operación.

El cuidador crea una invitación con alcances explícitos. La persona autenticada que acepta es el paciente y da su consentimiento. La base conserva el hash del token, su vencimiento y su consumo. El token se entrega una sola vez y se acepta en el cuerpo de una petición, nunca en la URL. Reintentar la creación devuelve conflicto para evitar persistir el token sin cifrar. Se puede crear otra invitación con una nueva operación.

La aceptación y la revocación conservan auditoría. Reactivar un vínculo requiere otra invitación y aceptación. Revocar no puede borrar copias que ya están en dispositivos desconectados. Las apps deberán borrar sus copias al detectar revocación o cerrar sesión cuando se implementen.

## Límites de F2

La agenda materializa una ventana acotada mediante el generador de F1. No se añade worker. La API expone creación y revisión de tratamientos, agenda, declaraciones, correcciones, proyección y reposición de inventario.

El borrador de rutas de PLAN.md no acredita implementación. Pausa y finalización, ajuste físico de stock, adherencia y dispositivos siguen pendientes de sus respectivos trabajos de dominio. No se crean apps, UI ni notificaciones.

La verificación local y sus límites se registran en el runbook F2 al finalizar. Firebase Admin `VerifyIDToken` comprueba la validez del token, pero no consulta la revocación de sesión del proveedor. La revocación de vínculos se comprueba en PostgreSQL por operación. Véase la [documentación oficial de Firebase](https://firebase.google.com/docs/auth/admin/verify-id-tokens).
