> Archivo histórico. Conserva decisiones, autorizaciones y evidencia de su etapa; sus instrucciones de ejecución y estados no son una cola vigente. Consulta el [estado actual](../../../PLAN.md) y las [reglas vigentes](../../../AGENTS.md).

# F0

- [x] Leer plan completo e inspeccionar entorno.
- [x] Ground. Repositorio sin código ni commits.
- [x] Sketch. Comparar paquete único con configuración y HTTP separados.
- [x] Agree. Continuar dentro de F0.
- [x] Implement.
- [x] Scrap. No fue necesario rediseñar.
- [x] Blocking first steps. Plan y herramientas revisados.
- [x] Independent workstreams. Un escritor aislado implementa; coordinador verifica entorno.
- [x] Shared mutable state. Copia temporal exclusiva, integración al terminar.
- [x] Smallest safe decomposition. Un backend y su configuración necesitan un único propietario.
- [x] Verificar migraciones y HTTP contra PostgreSQL real.
- [x] Documentar resultados y bloqueos.
- [ ] Commits y PR. skip: usuario prohíbe commits y no solicita PR.

# F2

- [x] `how` over the affected subsystem.
- [x] `architect` for parallel design exploration.
- [x] Write the throughput checkpoint as four todo items.
  - Blocking first steps. Read PLAN.md and trace replay authorization before exposing HTTP.
  - Independent workstreams. Read-only design exploration runs in parallel. One owner implements the coupled backend in an isolated worktree.
  - Shared mutable state. The implementation worktree is exclusive. Review and tests run after handoff.
  - Smallest safe decomposition. One backend owner keeps permissions, transactions and DTOs consistent. Root integrates, documents and verifies.
- [x] Delegate code-writing to a subagent.
- [x] Verify on the matching surface.
- [ ] Rebase into small, ordered commits. skip: user explicitly forbids commits.
- [ ] If the design is contested, `interrogate` before shipping. skip: no contested design yet.
- [ ] Run **Opening a PR**. skip: local implementation requested, no publishing.

Architecture steps: Ground and Sketch completed through source inspection and independent proposals. Agree uses the authorized F2 scope. Implement pending. Scrap applies only if implementation invalidates the design.

F2 implementada y verificada. El runbook `docs/runbooks/f2-verification.md` registra comandos, resultados y límites. F3 no iniciada.

# F3

- [x] `how` over the affected subsystem.
- [x] `architect` for parallel design exploration.
- [x] Write the throughput checkpoint as four todo items.
  - Blocking first steps. Read plan and identify F2 contract gaps before implementation.
  - Independent workstreams. Read-only architecture exploration; one implementation owner for coupled HTTP and web changes.
  - Shared mutable state. Isolated worktree; main tree integration only after ownership returns.
  - Smallest safe decomposition. One owner keeps typed web adapter and HTTP contract consistent.
- [x] Delegate code-writing to a subagent.
- [x] Verify on the matching surface.
- [ ] Rebase into small, ordered commits. skip: user prohibits commits.
- [ ] If the design is contested, `interrogate` before shipping. skip: only if contested.
- [ ] Run Opening a PR. skip: user requests local work without commits.

Architect: Ground, Sketch, Agree (no checkpoint requested), Implement, Scrap (only if needed).
Arena design: Frame, Fan out, Cross-judge, Pick, Graft, Verify.

Design synthesis used small route/feature components, exact strings, versioned editor snapshots and memory-only sessions. The independent review identified lost invitation response recovery and stale-editor version drift; both were fixed and passed real browser regressions. See docs/runbooks/f3-verification.md. No commits, PR or deployment.

# F4

- [x] Leer plan, contrato y comportamiento de replay antes de implementar.
- [x] Implementar app iOS, cola durable, recordatorios y consentimiento.
- [x] Verificar en simulador con API, PostgreSQL y emulador Firebase reales.
- [x] Instalación y login en iPhone físico.
- [ ] DoD offline y restricciones de notificación en iPhone físico. skip: fase cerrada por el usuario con este pendiente.
- [ ] Commits y PR. skip: usuario prohíbe commits.

Ver docs/runbooks/f4-verification.md.

## F6

- [x] 1. `how` over the affected subsystem.
- [x] 2. `architect` for parallel design exploration.
- [x] 3. Write the throughput checkpoint as four todo items.
  - Blocking first steps. Read full plan, domain and authorization; decide delivery ambiguity before implementation.
  - Independent workstreams. Worker/database/API and provider adapters/operations can use separate worktrees.
  - Shared mutable state. Only one writer per worktree; integrate patches sequentially.
  - Smallest safe decomposition. Domain owner keeps generation, outbox and authorization together; provider owner handles transport and restore.
- [x] 4. Delegate code-writing to a subagent using your configured feature model.
- [x] 5. Verify on the matching surface. Local checks, Railway probes and user staging acceptance pass; real push delivery remains pending.
- [ ] 6. Rebase into small, ordered commits. Stack follow-ups.
  - skip: user prohibits commits.
- [ ] 7. If the design is contested, `interrogate` before shipping.
  - skip: conditional on review findings.
- [ ] 8. Run **Opening a PR**.
  - skip: outside requested scope.
- [x] Architecture MAINTAIN, runbooks, evidence and F6 checkboxes.

F6 cerrada por aceptación del usuario el 2026-11-03 como MVP, conservando pendientes externos. Commit de cierre expresamente autorizado después de la prohibición inicial. F5b y F7 no iniciadas.
