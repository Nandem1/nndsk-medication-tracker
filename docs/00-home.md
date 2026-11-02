# Mapa del monorepo

La API Go expone únicamente probes operacionales. F1 añade casos de uso internos de tratamientos, agenda, declaraciones e inventario sobre PostgreSQL. Todavía no están conectados a rutas HTTP. Las apps y el worker son carpetas reservadas, sin ejecutables.

```mermaid
flowchart TB
    Probe[Cliente de diagnóstico] --> API[API Go en host]
    API --> Health[healthz sin acceso a DB]
    API --> Ready[readyz con Ping]
    Ready --> DB[(PostgreSQL en Compose)]
    Goose[Goose desde Makefile] --> DB
    Contract[Contrato OpenAPI de probes] -. describe .-> API
    Caller[Invocador interno con identidad confiable] --> UseCases[Casos de uso F1]
    UseCases --> Domain[Cantidades exactas y calendario local]
    UseCases --> DB
```

## Límites y responsabilidades

- [API](../services/api/cmd/api/main.go) compone configuración, pool y servidor; no expone los casos de uso F1 ni implementa autenticación.
- [Probes](../services/api/internal/http/health.go) separan liveness de conectividad. Readiness comprueba Ping con timeout de dos segundos; no verifica la versión del esquema.
- [Migraciones](../infrastructure/migrations/) poseen el esquema de usuarios y dominio. La API no aplica migraciones al arrancar.
- [Dominio](../services/api/internal/domain/) valida cantidades, estados y pautas, y resuelve fechas locales con una política DST explícita.
- [Aplicación](../services/api/internal/application/) ejecuta los casos de uso dentro de transacciones pgx. PostgreSQL conserva historial, saldo e idempotencia. La autenticación y el consentimiento por operación quedan pendientes de F2 antes de exponerlos por HTTP.
- [OpenAPI](../packages/contracts/openapi.yaml) contiene el contrato HTTP compartido. No hay clientes generados ni tokens de diseño implementados.
- [Compose](../compose.yaml) mantiene PostgreSQL y su volumen. El puerto host predeterminado es 55433 y el puerto del contenedor es 5432.

## Mapas por app

| App | Mapa local | Estado |
| --- | --- | --- |
| iOS | [Mapa iOS](../apps/ios/docs/00-home.md) | Carpetas reservadas, sin proyecto Xcode |
| Android | [Mapa Android](../apps/android/docs/00-home.md) | Carpetas reservadas, sin proyecto Gradle compilable |
| Web | [Mapa web](../apps/web/docs/00-home.md) | Carpetas reservadas, sin paquete ni runtime |

Los detalles internos de cada app se documentan en su mapa local cuando se implementan. Los límites compartidos permanecen aquí. La UI no se comparte entre plataformas.

## Contexto y evidencia

- [PLAN.md](../PLAN.md) define fases y diseño previsto; no acredita implementación.
- [Decisión de bootstrap](decisions/0001-bootstrap.md) explica la separación de paquetes y dependencias.
- [Decisión de dominio F1](decisions/0002-f1-domain.md) explica transacciones, cantidades, calendario y la frontera pendiente de F2.
- [README](../README.md) contiene onboarding y comandos operacionales.
- [Verificación F0](runbooks/f0-verification.md) registra las pruebas locales realizadas; no acredita despliegue en producción.
- [Verificación F1](runbooks/f1-verification.md) registra pruebas de dominio, integración y reversibilidad de migraciones en una base desechable.
- [AGENTS.md](../AGENTS.md#living-architecture) define cómo mantener este mapa y los mapas locales.
