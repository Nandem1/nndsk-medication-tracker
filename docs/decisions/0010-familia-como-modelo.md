# ADR 0010 — La familia como modelo

**Estado:** aceptada por el usuario el 2026-11-05. Reabre D2, D4 y D7 de [ADR 0009](0009-modo-familia.md). Plan en [PLAN-FAMILIA-2.md](../../PLAN-FAMILIA-2.md).

## Contexto

Con 3 cuidadores y 2 pacientes hacían falta 6 vínculos y cada padre pegaba 3 códigos de 43 caracteres. La autorización por vínculo, las alertas, la exportación y el borrado ya estaban probados sobre `caregiver_links`.

## Decisión

- Una persona crea una familia y la administra. Los miembros tienen un rol: `admin`, `caregiver`, `observer` o `patient`.
- Los vínculos se derivan: `syncLinks` recalcula, en la transacción que cambia la pertenencia, cada par que comparte una familia con un paciente. Los alcances son la unión de los roles de todas las familias en común. No hay otra forma de crear, cambiar o revocar un vínculo.
- El paciente consiente al unirse. Ve a los miembros, recibe aviso de quién se une durante una semana y puede salir. Los cuidadores que se unen después heredan a los pacientes.
- Las invitaciones son de un solo uso, con rol y 7 días de vigencia. Se comparten como `mistomas://unirse#<token>`, como QR o como código; el token sólo se canjea por POST.
- «Misma caja» activa el inventario compartido de inmediato, con un conteo físico obligatorio que fija el saldo común.
- Si sale la última persona administradora y quedan cuidadores, asume el cuidador más antiguo y, si no hay, quien sólo mira.

## Consecuencias

- Autorización, alertas y exportación siguen leyendo vínculos sin cambios. El riesgo queda acotado a `syncLinks`, cubierto por pruebas de integración de cada rol, unión de alcances entre familias, salida, remoción, promoción y espera de transacciones autorizadas.
- Permisos distintos para un mismo cuidador según el paciente necesitan familias distintas. Cambiar un rol exige quitar y volver a invitar.
- Las familias no se borran: conservan la historia de consentimiento.
- La migración 9 revoca los vínculos sin familia y disuelve las propuestas pendientes. Son datos de prueba.
