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

## Living Architecture

El mapa de arquitectura es el modelo mental externo. La implementación, las migraciones, los contratos y el comportamiento verificado determinan lo que existe.

- El mapa general vive en `docs/00-home.md`. Describe límites del monorepo, backend, contratos compartidos e infraestructura, y enlaza los mapas locales.
- Cada app mantiene su propio mapa en `apps/<app>/docs/00-home.md`. Describe sólo sus responsabilidades, estructura y flujos internos. Enlaza el mapa general para contratos e integraciones compartidas, sin duplicarlos.
- Antes de trabajo no trivial, identificar las áreas afectadas y leer sólo sus documentos relevantes. Si el área no está clara, comenzar en `docs/00-home.md`. Esto no sustituye la lectura de PLAN.md exigida arriba.
- Aplicar `living-architecture` en modo MAINTAIN cuando cambien límites, contratos de datos, autenticación, integraciones, runtime, reglas de negocio o despliegue.
- Cuando el cambio afecte materialmente al modelo documentado, actualizar sólo los Markdown/Mermaid correspondientes en el mismo cambio. Ajustes cosméticos y refactors internos sin impacto de comportamiento no requieren actualización.
- Cerrar cambios no triviales con un informe breve Architecture Impact. Para cambios complejos o de alto riesgo, solicitar una revisión independiente `living-architecture REVIEW` antes de merge.
- Distinguir lo implementado de lo planificado. No afirmar que tests o despliegues de producción funcionaron sin verificarlos.
- Mantener una única copia de cada documento por proyecto, compartida por todos los agentes. Los mapas locales detallan su ámbito, no replican el mapa general. Si se incorpora CLAUDE.md, debe enlazar esta política en vez de copiarla.
- Instalar la skill globalmente para uso personal o en el proyecto para agentes remotos y equipos. Evitar instalaciones global y local simultáneas del mismo nombre si vuelven ambigua su selección.

Prompt de revisión sugerido:

> Usando living-architecture REVIEW, compara este diff con el código y la documentación reales. No modifiques archivos. Separa divergencias nuevas de las preexistentes y reporta PASS/PARTIAL/FAIL.
