# F3: portal del cuidador

## Decisión

El portal usa React, Vite, TypeScript, Tailwind, componentes shadcn/ui y TanStack Router y Query. Router conserva la navegación y Query conserva las respuestas del servidor en memoria. Los formularios y el adaptador HTTP validan cantidades como cadenas decimales. El navegador no calcula ajustes de inventario.

Firebase autentica por correo y contraseña con persistencia en memoria. La API mantiene la autorización por paciente de F2. Cambiar de identidad cancela las consultas y limpia la caché. Una respuesta 401, 403 o 404 cierra también la sesión local. Los formularios abiertos conservan la versión que el usuario comenzó a editar, aunque llegue una consulta nueva. Las invitaciones se reciben en un formulario y viajan en el cuerpo HTTP, nunca en una URL. La vista previa muestra los alcances antes de aceptar.

La UI se organiza en pantallas pequeñas y componentes de formulario. No se añade un backend intermedio ni una segunda capa de estado del servidor. Las apps móviles y el worker siguen fuera de F3.

## Archivo y auditoría

Eliminar físicamente un tratamiento rompería su historial. La acción del portal es archivar, con motivo, versión esperada y clave idempotente. Conserva los datos anteriores y cancela las dosis futuras pendientes. El mismo límite temporal restringe tanto la generación de agenda como la proyección de inventario. Las declaraciones históricas permanecen disponibles.

Editar metadatos conserva una copia auditable del estado anterior. Cambiar horarios continúa creando una revisión de pauta. Las mutaciones incrementan la versión del tratamiento para detectar ediciones concurrentes.

## Conteo físico

El conteo recibe la cantidad observada, el saldo que el usuario revisó y un motivo. El servidor bloquea la cuenta, compara ese saldo y calcula la diferencia con aritmética exacta. Si otra operación cambió el saldo, responde con conflicto. Un reintento de la misma operación devuelve su resultado sin aplicar otra diferencia.

Cada conteo conserva auditoría, incluso cuando coincide con el saldo. Sólo una diferencia distinta de cero crea un movimiento `manual_adjustment`. Las restricciones anteriores sólo admitían negativos para consumos; una migración nueva habilita ajustes positivos o negativos sin modificar movimientos históricos.

## Verificación y límites

Las pruebas del navegador usan HTTP, servicios y PostgreSQL reales, con identidad sintética aislada del ejecutable y del bundle productivos. Este flujo no demuestra autenticación contra un proyecto Firebase real. La configuración de Firebase y sus cuentas de prueba son una comprobación separada.

Las migraciones reversas se ensayan únicamente en bases desechables. Revertir la migración F3 cuando existen ajustes manuales puede fallar al restaurar las restricciones anteriores. No se borran movimientos para forzar esa reversión.

El [runbook F3](../runbooks/f3-verification.md) registra los resultados observados. El [mapa web](../../apps/web/docs/00-home.md) describe las responsabilidades de la aplicación.
