# Dominio transaccional de F1

F1 mantiene las reglas de cantidades y calendario en `internal/domain`. Los casos de uso viven en `internal/application` y ejecutan transacciones PostgreSQL con pgx. El proceso HTTP conserva únicamente las probes de F0.

Se comparó esta estructura con separar aplicación, repositorio y unidad de trabajo mediante interfaces. PostgreSQL es la única persistencia prevista y sus locks y constraints forman parte de la corrección. Las interfaces añadirían propagación de transacciones sin sustituir las pruebas reales. Se elige el servicio concreto y se mantiene puro el cálculo que no necesita persistencia.

No se incorpora sqlc en F1. Las consultas pertenecen a operaciones transaccionales pequeñas y las pruebas integradas comprueban su comportamiento. No hay una segunda representación generada ni nuevas dependencias.

## Cantidades e historial

Las cantidades se representan en milésimas enteras en Go y `NUMERIC(12,3)` en PostgreSQL. No se usan floats. El saldo procede de la suma de movimientos; una declaración de toma no acredita ingestión real.

Los eventos y movimientos se añaden sin sobrescribir historia. Una corrección referencia el evento vigente, exige la versión esperada y registra el motivo. Un cambio en el consumo produce movimientos compensatorios. Una proyección única por ocurrencia identifica su consumo activo.

Cada comando de usuario incluye actor y operación UUID. La transacción conserva una huella del comando y su respuesta. Repetir el mismo comando devuelve aquella respuesta, incluso si operaciones posteriores modificaron el saldo. Reutilizar la clave con otro contenido produce conflicto.

## Calendario y límites

Las revisiones conservan la pauta original y las ocurrencias guardan fecha y hora locales además del instante UTC. Cambiar la pauta conserva el pasado y cancela las ocurrencias pendientes futuras afectadas, sin convertirlas en omisiones.

La política DST es obligatoria. Puede rechazar horas inexistentes o ambiguas, o seleccionar explícitamente el siguiente minuto válido y el primer instante de una hora repetida. Esta selección es una capacidad técnica, no una recomendación clínica. Antes de exponerla a pacientes debe revisarse y mostrarse en la configuración, como exige el plan.

Dos horarios que convergen al mismo instante por DST provocan un error. Ignorar el duplicado perdería una dosis prevista.

`GenerateOccurrences` genera 30 fechas locales desde la fecha inicial inclusiva. Puede repetirse o avanzar la fecha inicial para extender la agenda; la unicidad por revisión e instante conserva los IDs ya creados. `ReviseSchedule` cancela las pendientes futuras afectadas. La siguiente generación materializa las ocurrencias de la revisión nueva. No hay worker ni regeneración automática en F1.

`GetInventoryProjection` calcula desde las pautas, sin depender de que la agenda esté materializada. Usa una lectura consistente del saldo y las revisiones. Su intervalo incluye `From` y excluye `Through`, el inicio del día local que queda 30 fechas después de la fecha de `From`. Para ese límite usa la zona de la revisión vigente en `From`. Excluye declaraciones ya contabilizadas y devuelve la primera dosis que el saldo no cubre. Si no aparece una dentro del horizonte, no afirma duración ilimitada. El saldo puede ser negativo y no altera la pauta ni recomienda compensaciones.

## Frontera pendiente de F2

Los servicios reciben un actor interno confiable. F1 no verifica tokens ni expone rutas de tratamientos o inventario. F2 debe conectar identidad verificada, autorización por operación y consentimiento antes de exponer estos casos de uso.

El [mapa general](../00-home.md) distingue este dominio de los procesos ejecutables y de las apps aún no implementadas.
