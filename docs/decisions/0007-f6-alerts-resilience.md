# F6. Alertas con entrega incierta explícita

El worker ejecuta un segundo binario dentro del módulo Go de la API. Reutiliza el generador de agenda y la proyección de stock de aplicación. Un módulo independiente exigiría exportar esas reglas o duplicar contratos internos sin aportar aislamiento útil para esta escala.

## Reserva durable antes de enviar

La outbox conserva estados de entrega. El worker confirma la reserva antes de llamar a APNs o FCM. Un fallo de red puede ocurrir después de que el proveedor acepte el mensaje. Ese resultado queda incierto y no se reenvía automáticamente. Un intento abandonado por caída del proceso recibe el mismo tratamiento.

Mantener una transacción SQL abierta durante HTTP no resuelve esa ambigüedad. Si el proveedor acepta y falla el commit, repetir la transacción puede duplicar el aviso. La reserva durable prioriza evitar spam y puede perder una entrega. Las notificaciones siguen siendo best effort.

La rotación de token recupera sólo avisos que todavía no tuvieron un intento. Los avisos enviados, inciertos o previamente intentados conservan su estado y no se reabren.

Los rechazos temporales explícitos admiten reintentos limitados con espera y vencimiento. Collapse ID y tag complementan la deduplicación. No ofrecen una garantía de entrega exactamente una vez. La clasificación sigue las respuestas documentadas por [APNs](https://developer.apple.com/documentation/usernotifications/handling-notification-responses-from-apns) y [FCM](https://firebase.google.com/docs/cloud-messaging/error-codes).

## Límites de dominio y privacidad

El worker genera agenda, evalúa alertas y actualiza la outbox. No declara tomas, no convierte una dosis sin confirmar en omitida y no modifica el ledger. La reconciliación detecta divergencias y exige investigarlas antes de una corrección auditable.

Las alertas requieren preferencias explícitas de un cuidador con vínculo activo. El retraso de dosis sin confirmar queda desactivado por defecto, porque el plan no define un valor acordado con la familia. El stock usa la simulación de dosis futuras existente.

El push contiene sólo texto genérico y una identidad opaca de entrega. El servidor vuelve a verificar consentimiento, condición y dispositivo antes de reservar. El cierre de sesión intenta revocar el registro y desactiva la recepción local. Si el teléfono está offline, el registro servidor puede sobrevivir hasta su vencimiento.

## Recuperación

El backup usa pg_dump custom cifrado con AES-256-GCM, con una clave externa de 32 bytes y nonce aleatorio. El comando de ensayo sólo restaura en una base local vacía cuyo nombre comienza con `medication_f6_restore_`. El worker debe permanecer detenido durante restore y reconciliación. Una copia antigua puede contener avisos que ya se enviaron después del backup. No deben reactivarse automáticamente.

El contenedor usa el mismo código que se prueba en el host. Staging exige TLS verificado para PostgreSQL y un proyecto Firebase separado con datos sintéticos. La existencia de archivos de despliegue no acredita un despliegue remoto.
