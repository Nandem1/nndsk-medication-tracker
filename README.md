# Medication Tracker

Registro de tomas, recordatorios e inventario para pacientes y cuidadores. Apps nativas en SwiftUI y Compose, portal React y backend Go con PostgreSQL.

La app registra declaraciones de toma. No prescribe ni recomienda cambios de dosis.

## Desarrollo

Consulta la [guía local](docs/runbooks/development.md) para configurar Firebase, PostgreSQL y cada app. Guarda las credenciales fuera del repositorio.

```sh
make web-install
make test
make lint
```

Las pruebas móviles requieren Xcode o Android SDK. Las pruebas de integración usan una base desechable.

## Documentación

- [Arquitectura](docs/00-home.md)
- [Estado y próximos pasos](PLAN.md)
- [Seguridad y pendientes de F8](docs/runbooks/f8-verification.md)
- [Guía de rediseño](docs/design/claude-redesign-handoff.md)
