# Verificación local de F4

La app iOS del paciente se implementó sin commits, push ni despliegue. **F4 se cerró el 2026-11-03 por decisión del usuario, con pendientes**: el flujo de la DoD pasó en simulador, pero la confirmación offline no se ejecutó en iPhone físico.

## Resultados observados

Xcode 27.2, simulador iPhone 17 con iOS 27.2 y PostgreSQL 18.6 en Docker.

| Comprobación | Resultado |
| --- | --- |
| `make test` | Go con `-race` y Vitest correctos |
| `make lint` | gofmt, go vet y TypeScript correctos |
| `make build` | API y portal compilados |
| `make test-integration` | Correcto con PostgreSQL real, en base desechable |
| `make test-web-e2e` | 4 pruebas Playwright correctas; regresión por el cambio en `cmd/e2e` |
| `sh scripts/smoke.sh` | healthz 200, readyz 200 y SIGTERM con salida 0 |
| `make test-ios` | 55 pruebas unitarias correctas, con dobles de red y Keychain y SQLite reales |
| `make lint-ios` | Compila app y pruebas con advertencias como errores |
| Release, `generic/platform=iOS`, sin firma | Compila para dispositivo con destino iOS 17.0; no se instaló |
| `make test-ios-e2e` | 6 XCUITest correctos, sin omitidos |

## En iPhone físico

iPhone 18 Pro, equipo personal gratuito de Apple, proyecto Firebase real y ejecutable productivo de la API en la red local.

- **Verificado:** `make run-ios-device` compila, firma e instala. La persona usuaria inició sesión con su cuenta y vio la app correctamente. La API registró 14 GET con 200, uno de ellos posiblemente una sonda local.
- **No ejecutado:** ningún tratamiento ni declaración en esa base (0 y 0). Por tanto, en dispositivo no se probaron agenda con dosis, modo avión, descuento de stock, entrega de recordatorios ni restricciones de notificación.

## Qué demuestra cada E2E

Son pruebas con simulador, HTTP y PostgreSQL reales. La identidad viene del emulador oficial de Firebase. El cuidador actúa por HTTP contra la API, no mediante el portal, que ya se verificó en F3. La falta de red se produce cerrando conexiones TCP en un proxy, no apagando la red del simulador.

1. **Flujo de la DoD.** El paciente acepta la invitación desde la app y el cuidador crea una pauta de 0,5 comprimidos. La agenda llega y el paciente confirma sin conexión. La operación sobrevive a cerrar la app y se ven por separado el saldo confirmado (10) y el estimado (9,5). Vuelve la red, pero se pierde la respuesta tras aplicar el POST: la API descuenta y la app sigue en «Pendiente». El reintento converge y la cuenta del cuidador lee saldo 9,500 con exactamente un consumo de −0,500.
2. **Conflicto.** Una declaración offline choca con la del cuidador. El 409 queda visible en «Por revisar», sin alterar el stock. Convertirla en corrección crea una reversa y conserva el consumo.
3. **Toma tarde y corrección desde Historial.** Inicial, consumo y reversa permanecen en el ledger.
4. **Revocación.** El paciente revoca y el cuidador deja de poder consultar la agenda.
5. **Recordatorio.** Se entrega de verdad a la hora prevista, sin el nombre del medicamento. Al tocarlo se abre la dosis y no se registra ninguna declaración.
6. **Accesibilidad.** Con el texto más grande, las tres acciones son alcanzables y miden al menos 44 pt. La auditoría de contraste, Dynamic Type, descripciones y áreas táctiles pasa. Sólo se ignoran hallazgos de contraste de elementos parcialmente bajo las barras translúcidas del sistema.

En una corrida intermedia se observó en la base `occurred_at` a la hora del toque y `recorded_at` 16 segundos después, a la hora de sincronización.

## Defectos encontrados al verificar

Las pruebas contra dobles no habrían visto ninguno de los tres primeros.

- **Caída de la app al tocar un recordatorio.** El delegado `async` reanudaba fuera del hilo principal. Sólo apareció con una entrega real.
- **La base local no abría en su ruta real.** `URL.path()` codificaba el espacio de `Application Support` como `%20`.
- **Contraste insuficiente** en estados y botones con los colores del sistema. Se detectó al revisar capturas; la auditoría inicial no incluía contraste.
- El teclado seguía abierto tras revisar una invitación y tapaba las pestañas.
- Una operación cuya dosis se canceló quedaba sin forma de resolverse.
- Una cuenta nueva podía heredar registros ajenos si la app se cerraba durante esa decisión.
- `go run` dejaba vivo un servidor de pruebas al terminar. El script compila el binario y rechaza puertos ocupados.

## Bloqueos y pendientes

| Pendiente | Motivo | Cómo cerrarlo |
| --- | --- | --- |
| DoD offline en iPhone físico | Se cerró la fase antes de ejecutarla | Pasos 5 a 7 de la prueba manual |
| Consentimiento en iPhone | La API rechaza aceptar una invitación propia; requiere dos cuentas | Repetir con una segunda cuenta |
| iOS 17 en ejecución | Sólo hay runtime 27.2; el destino 17.0 sólo está compilado | Instalar el runtime y confirmar la versión real de los teléfonos |
| Data Protection de la base local | El simulador no la implementa; la aserción sólo corre en dispositivo | Ejecutar `make test-ios` con destino iPhone |
| Límites reales de notificación | Batería, Focus, reinicio y permiso denegado no se probaron | Lista siguiente |
| VoiceOver | Sólo hay auditoría automática | Revisión manual |

No se probaron por UI: permiso de notificaciones denegado, cambio de zona horaria o de DST con la app instalada, el límite de 64 avisos (sólo en unidad) ni el aviso de otra cuenta (unidad para el almacén). No hay tarea en segundo plano: una declaración offline se envía al volver a abrir la app, y los recordatorios sólo se reponen entonces.

## Prueba manual en iPhone físico

1. Añadir la cuenta de Apple en Xcode, confiar en el Mac y activar el Modo de desarrollador en el iPhone.
2. Crear `apps/ios/Config/Local.xcconfig` como indica el README. `make dev` no sirve: `.env` fija `HTTP_ADDR` en loopback.
3. Iniciar `make dev-lan`, sólo en una red de confianza y con datos sintéticos.
4. Ejecutar `make run-ios-device`. La primera vez, autorizar al desarrollador en Ajustes del iPhone.
5. Repetir la DoD con el modo avión real: el cuidador crea desde el portal, el paciente confirma sin red, cierra la app, recupera la red y el saldo baja una sola vez.
6. Comprobar el recordatorio con el teléfono bloqueado, en modo Enfoque, con permiso denegado y tras reiniciar.
7. Ejecutar `make test-ios IOS_DESTINATION='platform=iOS,name=<iPhone>'` para la aserción de Data Protection.

## Reproducción

Crear una base desechable con prefijo `medication_f4_` y aplicar las migraciones. Asignar su conexión a `TEST_DATABASE_URL` sin imprimirla:

```sh
GOOSE_DRIVER=postgres GOOSE_DBSTRING="$TEST_DATABASE_URL" .bin/goose-v3.29.0 -dir infrastructure/migrations up
make test-ios
make lint-ios
make test-ios-e2e
```

La suite tarda unos ocho minutos y necesita red la primera vez, para `firebase-tools` y XcodeGen. Ocupa los puertos 9099, 18083 y 18084 y desinstala la app del simulador antes de empezar. Las bases contienen sólo datos sintéticos y se conservaron.

## Divergencias previas

`GET /v1/caregiver-links` devuelve también vínculos revocados, mientras que OpenAPI declara `status` como `active`. La app filtra en el cliente. No se cambió el contrato porque es ajeno a F4.

El evento de dosis no admite motivo y `Dose` no expone `occurred_at`. Por eso «No me lo tomé» no pide motivo opcional y el historial no muestra la hora efectiva de una toma tardía. El plan contempla ambas cosas; requieren ampliar la API.

`packages/design-tokens/tokens.json` no existe. Los colores viven en la app iOS y conviene compartirlos antes de F5.

## Architecture Impact

- Límites cambiados: se añade la app iOS como cliente de la API.
- Modelo de datos del servidor sin cambios y sin migraciones. Se añade almacenamiento local en el dispositivo.
- API sin cambios. Autorización backend sin cambios.
- Integración nueva: Firebase Authentication por REST desde iOS.
- Runtime de pruebas cambiado: `cmd/e2e` acepta el emulador y añade el proxy de fallos. El ejecutable productivo no cambia.
- Reglas de negocio del servidor sin cambios. Se añaden las de cola y reconciliación del cliente.
- Herramientas locales nuevas: `make dev-lan` expone la API en la red sólo mientras corre; `make run-ios-device` instala en el iPhone.
- Documentación: mapas general e iOS, README, PLAN, ADR 0005 y este runbook.
