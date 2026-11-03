# F7: métricas declaradas y reposición

## Decisión

El portal del cuidador consulta las métricas al backend. PostgreSQL conserva las declaraciones y las correcciones que determinan el estado efectivo de cada dosis. El dashboard no calcula sus denominadores a partir de una página de agenda.

Se compararon dos opciones. Agregar la agenda en React evitaba una ruta nueva, pero duplicaba reglas y mezclaba lecturas paginadas. Además, la agenda no contiene la hora efectiva necesaria para calcular puntualidad. Un agregado transaccional reutiliza autorización, generación de ocurrencias y eventos vigentes. Se elige esa opción.

## Semántica

El rango incluye `from` y excluye `to`, según la fecha local original de cada ocurrencia. La consulta captura un único `as_of`. Sólo son evaluables las dosis no canceladas cuyo instante programado es anterior a ese corte. Los tratamientos archivados conservan su historia.

La adherencia declarada divide las tomadas y tomadas tarde por las dosis evaluables. La confirmación incluye también las omisiones explícitas. Las dosis vencidas sin respuesta permanecen sin confirmar. Ninguna de estas métricas demuestra ingestión.

La puntualidad divide las declaraciones `taken` dentro de la ventana organizativa por todas las declaraciones de toma, incluidas `taken_late`. Se usa la hora efectiva del evento vigente, también después de una corrección. La ventana admite adelanto o atraso de hasta los minutos seleccionados, incluidos sus extremos. Su valor inicial es 60 minutos. Es un criterio de presentación, no una tolerancia clínica ni una recomendación de horario.

Un denominador cero produce una proporción nula. La interfaz muestra que no hay datos evaluables, en vez de presentar un 0 % engañoso. El calendario cuenta respuestas explícitas, incluidas omisiones, sin premios por consumo, rachas ni penalizaciones.

## Rango y proyección

Las consultas de historial y métricas admiten hasta 366 días locales y filtran por paciente y tratamiento. La generación reutiliza bloques de hasta 30 días. El horizonte de la proyección de inventario permanece en 30 días.

La reposición usa el ledger y las próximas dosis de las revisiones de pauta, con cantidades decimales exactas. Se expone el umbral existente de la cuenta de inventario. Su edición requiere el alcance `inventory`, una operación idempotente y el valor previo esperado para detectar conflictos. No añade tablas ni movimientos de stock.

La fecha de reposición es orientativa. Si la primera dosis sin cobertura queda fuera del horizonte, no se inventa una fecha de agotamiento. La antelación se expresa en días de calendario de la zona indicada por la proyección.

## Alcance

F7 incorpora el dashboard y el historial al portal web. La vista de cuidador móvil sigue perteneciendo a F5b. No cambia declaraciones, prescripciones ni autenticación. La edición del umbral afecta la planificación existente de stock bajo si el cuidador ya habilitó ese aviso; no activa push. Los resultados de pruebas y límites de esta entrega se registran en la [verificación F7](../runbooks/f7-verification.md).
