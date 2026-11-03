# F4: app iOS del paciente

## Proyecto generado

El `.xcodeproj` no se versiona. `apps/ios/project.yml` es la fuente y XcodeGen lo genera con versión y commit fijados en el Makefile, como goose. Se compila desde el código en `.bin`. Evita conflictos de merge y cumple la regla de no fabricar proyectos a mano. La alternativa, crear el proyecto en la interfaz de Xcode, no se puede reproducir por línea de comandos. El Makefile usa `DEVELOPER_DIR` y no cambia la selección global de Xcode.

## Identidad por REST en vez de Firebase iOS SDK

**Decisión revisable.** La app llama a la API REST oficial de Firebase Authentication con `URLSession`. El plan justificaba Firebase por sus clientes maduros; esta decisión se aparta de ese motivo, no del proveedor.

- A favor: ninguna dependencia nueva, código pequeño y el flujo real se puede ejercitar contra el emulador oficial sin rutas de prueba en la app.
- En contra: el refresco y el guardado de tokens son responsabilidad propia. Sin App Check ni otros métodos de ingreso. Añadirlos más adelante favorecería volver al SDK.

`IdentityStore` es el único dueño de las credenciales, por lo que sustituirlo por el SDK queda acotado. El refresh token vive en Keychain con `AfterFirstUnlockThisDeviceOnly`, sin copias ni migración de dispositivo.

## Cola durable en SQLite

Se eligió SQLite del sistema, sin dependencias, en vez de SwiftData. La cola exige transacciones explícitas, y el plan admite ambas opciones.

- Cada declaración se confirma en disco con `synchronous=FULL` antes de intentar la red.
- La operación guarda los **bytes exactos** del cuerpo, porque la API compara una huella del contenido al repetir un `client_operation_id`.
- `occurred_at` se fija al tocar el botón. Si lo decidiera el servidor, `taken` registraría la hora de sincronización.
- Cada dosis admite una sola operación activa, así un doble toque no crea dos declaraciones.
- La respuesta del servidor y el retiro de la operación ocurren en una transacción.

| Respuesta | Efecto en la cola |
| --- | --- |
| 2xx | Se aplica y se retira |
| Sin red o 401 | Se conserva y se detiene el envío |
| 5xx, 429 o respuesta ilegible | Se conserva y se reintenta la misma operación |
| 409, 400/422, 403/404 | Se conserva y espera una decisión de la persona |

Ninguna operación se descarta sin una acción explícita. Las cuentas no heredan registros ajenos: si quedan pendientes de otra cuenta, la app pide decidir antes de borrarlos o enviarlos. Cerrar sesión borra caché, cola y recordatorios, y avisa cuántos registros se perderán. Si la sesión vence, en cambio, se conservan para la misma cuenta.

## Recordatorios por intervalo

Se usa `UNTimeIntervalNotificationTrigger` hacia el instante UTC de la dosis, no `UNCalendarNotificationTrigger`. El backend ya resolvió zona IANA y DST, de modo que un viaje no desplaza la hora. La identidad de cada solicitud incluye ese instante, por lo que un cambio de pauta la reemplaza. Se programan 60 como máximo, dentro del límite de 64 de iOS, y se reponen al sincronizar o volver a primer plano. No hay tarea en segundo plano: si la app no se abre, la ventana se agota, y Ajustes muestra hasta cuándo alcanza. El texto no incluye el nombre del medicamento.

## Pruebas sin rutas especiales

La app no contiene código de pruebas: sólo cambian URLs por build settings. `cmd/e2e`, con etiqueta `e2e`, valida tokens del emulador y añade un proxy que cierra conexiones TCP reales para simular falta de red o pérdida de respuesta tras aplicar el POST. El ejecutable productivo sigue rechazando el emulador. Release rechaza URLs no HTTPS y el emulador.

## Límites

Las pruebas automáticas no demuestran el comportamiento en iPhone físico, iOS 17, Data Protection, batería ni Firebase real. En dispositivo sólo se verificaron instalación y login. El [runbook F4](../runbooks/f4-verification.md) separa lo comprobado de lo pendiente.
