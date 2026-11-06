# Reglas de colaboración

Estas reglas aplican a todo modelo y persona que trabaje en este repositorio. La orden explícita del usuario en la sesión actual prevalece sobre ellas, salvo en lo marcado como **nunca**.

## Antes de cambiar nada

- Lee `PLAN.md` completo, el código afectado y el plan de la tarea. Hoy el trabajo activo está en [`PLAN-FAMILIA.md`](PLAN-FAMILIA.md).
- Ejecuta sólo la fase solicitada, en el orden del plan. No adelantes fases ni añadas funciones no pedidas.
- Las decisiones registradas en un plan no se reabren. Si el código las contradice, sigue la intención, haz el cambio más pequeño y regístralo en el cierre.
- Cuestiona con evidencia las decisiones heredadas. Propón alternativas que reduzcan deuda sin añadir abstracciones. Acuerda con el usuario las expansiones relevantes.

## Producto y dominio: nunca se rompe

- **La app no prescribe.** Nunca sugiere duplicar, adelantar, suspender o compensar dosis. Ante una dosis perdida o tardía remite a las instrucciones del profesional o a un farmacéutico.
- **«Sin confirmar» no es «omitida»**, y una declaración no es evidencia de ingestión. Ninguna regla convierte automáticamente una en otra, tampoco por antigüedad.
- **El backend autoriza cada operación.** La UI oculta lo que no corresponde, pero nunca es el control. El rol o el `patient_id` enviados por el cliente no otorgan acceso.
- **El consumo es único y atómico:** declaración y movimiento de stock van en una transacción. `taken`/`taken_late` descuentan la cantidad prevista; `skipped` y sin confirmar descuentan 0.
- **La historia es append-only.** Las correcciones crean eventos y movimientos compensatorios; nunca borran.
- **Toda mutación es idempotente** con `client_operation_id` estable. Un reintento repite la misma operación.
- **Offline:** la declaración se escribe en disco antes de la red. Un 409 u otro rechazo queda visible hasta que la persona decide; nunca se descarta en silencio.
- **Cantidades:** decimales exactos, en texto en la API y los clientes. Nunca float.
- **Tiempo:** UTC más zona IANA y hora local. DST de `America/Santiago` probado. Nunca sumar 24 horas a ciegas.
- **Recordatorios:** una notificación abre la dosis; nunca declara. Texto discreto, sin nombre del medicamento. Sólo la agenda propia, nunca la de otro paciente.
- **Métricas:** vienen de la API, no de páginas parciales en cliente. Siempre con período y denominador. Se llaman «declaradas», nunca adherencia clínica. Sin rachas ni premios por consumo.
- Antes de implementar dominio, escribe las pruebas de idempotencia, concurrencia, consumo único, correcciones auditables, decimales exactos y DST.

## Seguridad y datos

- **Nunca** incluyas secretos, datos reales de salud ni conexiones de producción en el repositorio, fixtures, logs o mensajes.
- No registres URLs de conexión, tokens, cuerpos de petición ni información médica. No los imprimas en la salida de los comandos.
- Tokens de invitación: se canjean sólo en el cuerpo de POST. Fuera de eso, únicamente en el fragmento del enlace `mistomas://unirse#…` o en su QR, que no llegan a ningún servidor; nunca en una ruta o consulta HTTP.
- `.env`, `apps/web/.env.local` y `apps/ios/Config/Local.xcconfig` no se versionan. Verifica con `git check-ignore` antes de editarlos.

## Git, despliegue y acciones irreversibles

- No hagas commit, push, despliegue ni migración destructiva sin autorización explícita del usuario. La autorización vale sólo para lo que cubre: un plan puede otorgarla por escrito, como `PLAN-FAMILIA.md`.
- **Nunca** `git push --force`, ni reescribir historia publicada, ni tocar **producción**, salvo pedido explícito para ese caso.
- Prueba down/up de migraciones sólo en bases desechables. Local y staging contienen datos de prueba, pero producción no se toca.
- Si te toca reemplazar un proceso que no iniciaste, identifícalo antes de terminarlo.
- Termina los mensajes de commit con la atribución que indique tu entorno.

## Implementación

- Usa versiones estables fijadas. No introduzcas dependencias sin necesidad. Respeta los lockfiles.
- No fabriques proyectos Xcode ni Gradle Wrapper. El `.xcodeproj` se genera desde `apps/ios/project.yml`.
- La UI es nativa y no se comparte entre plataformas. Se comparten contratos, lenguaje visual y reglas.
- `packages/contracts/openapi.yaml` es el contrato: actualízalo junto con los handlers y DTOs.
- Escribe como el código de alrededor: mismos nombres, densidad de comentarios e idioma. Producto y documentación en español de Chile.

## Diseño

- **Fuente de verdad visual:** `packages/design-tokens/tokens.json`. Nunca edites los adaptadores generados (`tokens.css`, `Tokens.generated.swift`, `Tokens.kt`); corre `make tokens`. Un par nuevo de contraste se añade a `contrast` en `tokens.json`.
- **Estados:** siempre icono y texto, con su par Fg/Bg. Omitida es neutra. `danger` sólo para conflicto o rechazo. Guardada sin enviar: «Guardada, falta enviar», con `syncFg`/`syncBg`.
- **Las tres declaraciones** tienen el mismo alto y ninguna penalización visual; sólo «Me lo tomé» va rellena.
- **Accesibilidad:** Dynamic Type y escala de fuente, TalkBack y VoiceOver, modo oscuro, mínimo 44 pt / 48 dp, y estados de vacío, carga, error y permiso denegado. Todo gráfico necesita alternativa textual y no depender sólo del color.
- **La UI del paciente en iOS es la referencia aceptada por el usuario.** No la rediseñes sin pedido. Android sigue su estructura con lenguaje de plataforma.
- **Mira lo que construyes.** Tras un cambio visual captura la pantalla real y revísala. Un E2E en verde no significa que se vea bien.

## Verificación

- Ejecuta lo aplicable en la versión final del código, no en una anterior:
  - Siempre: `make tokens-check`, `make test`, `make lint`.
  - Web: `make build`, `make test-web-e2e`.
  - Dominio o API: `make test-integration`.
  - Android: `make test-android`, `make lint-android`, `make test-android-device`, `make test-android-e2e`.
  - iOS: `make test-ios`, `make lint-ios`, `make test-ios-e2e`.
- Las bases de prueba son desechables, con el prefijo que exige cada comando. Ver `docs/runbooks/development.md`.
- Una verificación con mocks no es una prueba real. Un emulador no es un teléfono físico. Dilo cuando corresponda.
- Si un puerto está ocupado o falta una herramienta, repórtalo. No declares verificado lo que no corrió.
- Si cambias una prueba para que pase, explica por qué cambió el comportamiento esperado.

## Cierre e informes

- Distingue siempre **propuesto, implementado, validado y desplegado**.
- Marca checkboxes del plan sólo con evidencia. Una aceptación del usuario cubre sólo lo que probó.
- Cierra con: cambios, decisiones, comandos y resultados, pruebas, bloqueos, lo que no se ejecutó y el siguiente paso.
- No afirmes cumplimiento legal ni preparación para producción. Lo pendiente de `docs/runbooks/f8-release.md` sigue pendiente hasta que se haga.

## Subagentes y paneles

Usa el mismo modelo del agente principal en todos los roles y paneles, y conserva el esfuerzo de la sesión. Paneles de un mismo modelo no son revisiones multimodelo; no los presentes como tales.

## Living Architecture

El mapa de arquitectura es el modelo mental externo. La implementación, las migraciones, los contratos y el comportamiento verificado determinan lo que existe.

- El mapa general vive en `docs/00-home.md`. Describe límites del monorepo, backend, contratos compartidos e infraestructura, y enlaza los mapas locales.
- Cada app mantiene su propio mapa en `apps/<app>/docs/00-home.md`. Describe sólo sus responsabilidades, estructura y flujos internos. Enlaza el mapa general para contratos e integraciones compartidas, sin duplicarlos.
- Antes de trabajo no trivial, identifica las áreas afectadas y lee sólo sus documentos relevantes. Si el área no está clara, comienza en `docs/00-home.md`. Esto no sustituye la lectura de `PLAN.md`.
- Aplica `living-architecture` en modo MAINTAIN cuando cambien límites, contratos de datos, autenticación, integraciones, runtime, reglas de negocio o despliegue.
- Cuando el cambio afecte materialmente al modelo documentado, actualiza sólo los Markdown/Mermaid correspondientes en el mismo cambio. Ajustes cosméticos y refactors internos sin impacto de comportamiento no requieren actualización.
- Cierra cambios no triviales con un informe breve Architecture Impact. Para cambios complejos o de alto riesgo, solicita una revisión independiente `living-architecture REVIEW` antes de merge.
- Distingue lo implementado de lo planificado. No afirmes que tests o despliegues de producción funcionaron sin verificarlos.
- Mantén una única copia de cada documento por proyecto, compartida por todos los agentes. Los mapas locales detallan su ámbito, no replican el mapa general. Si se incorpora CLAUDE.md, debe enlazar esta política en vez de copiarla.
- Instala la skill globalmente para uso personal o en el proyecto para agentes remotos y equipos. Evita instalaciones global y local simultáneas del mismo nombre si vuelven ambigua su selección.

Prompt de revisión sugerido:

> Usando living-architecture REVIEW, compara este diff con el código y la documentación reales. No modifiques archivos. Separa divergencias nuevas de las preexistentes y reporta PASS/PARTIAL/FAIL.
