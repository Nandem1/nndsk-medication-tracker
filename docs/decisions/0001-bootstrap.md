# F0 y límites de paquetes

El proceso API posee configuración, pool PostgreSQL y ciclo de vida. Config valida variables en el borde de entrada. HTTP recibe una función Ping con contexto y expone sólo las dos probes. Esto permite probar errores y cancelación sin un repositorio artificial.

Se comparó un único paquete main con separar config y http. El paquete único reduce archivos, pero mezcla entorno, señales y protocolo HTTP en cada prueba. Se eligieron dos paquetes internos pequeños y main como composición. No se implementan capas de dominio ni repositorios vacíos con interfaces.

ServeMux estándar resuelve dos rutas sin chi. pgxpool es la única dependencia de ejecución. Goose es una herramienta fijada que se instala en .bin, fuera del módulo de la API. sqlc y generación de clientes quedan pendientes hasta tener consultas y contratos que los justifiquen.

Readiness comprueba conectividad, no versión de esquema. La API arranca aunque PostgreSQL no responda y devuelve 503 hasta recuperar conectividad. Liveness no consulta PostgreSQL. La migración inicial contiene únicamente users y no expone operaciones de usuario.

Los directorios futuros se conservan con .gitkeep. No se crean proyectos nativos, paquetes web, tokens inventados ni ejecutables worker.
