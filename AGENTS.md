# Reglas de colaboración

- Leer PLAN.md completo y el código afectado antes de cambiarlo.
- Ejecutar únicamente la fase solicitada. F0 contiene infraestructura, probes y users mínimos. No adelantar UI, autenticación, medicamentos, inventario ni worker.
- Cuestionar decisiones heredadas con evidencia. Proponer alternativas que reduzcan deuda sin añadir abstracciones innecesarias. Acordar expansiones relevantes antes de ejecutarlas.
- Distinguir lo propuesto, implementado, validado y desplegado.
- No hacer commits, push, despliegues ni migraciones destructivas sin autorización explícita. Usar bases desechables para probar down/up.
- No incluir secretos, datos reales de salud ni conexiones de producción. No registrar URLs de conexión, tokens ni información médica.
- Usar versiones estables fijadas. No fabricar proyectos Xcode ni Gradle Wrapper. No introducir dependencias sin necesidad.
- Ejecutar make test, make lint y las pruebas reales aplicables. Reportar herramientas ausentes y bloqueos; no declarar verificación con mocks como prueba real.
- Actualizar checkboxes del plan sólo con evidencia. Cerrar con cambios, decisiones, comandos, tests, bloqueos y siguiente paso.
- Antes de implementar dominio, probar idempotencia, concurrencia, consumo único, correcciones auditables, decimales exactos y DST. No confundir sin confirmar con omitido ni declaración con ingestión.
- La UI es nativa y no se comparte. El backend valida autorización en cada operación.
- La app no prescribe ni recomienda compensaciones de dosis.

## pstack en Codex

Usar inherit-parent en todos los roles y paneles. Conservar el esfuerzo de la sesión. Los paneles del modelo heredado no son revisiones multimodelo.
