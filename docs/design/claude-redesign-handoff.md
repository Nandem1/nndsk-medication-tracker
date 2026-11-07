# Rediseñar las tres interfaces sin cambiar el dominio

El usuario encarga a Claude el rediseño visual de iOS, Android y web después del endurecimiento F8. Busca más gráficos, una identidad reconocible y consistencia entre plataformas. F8 no decide paleta, tipografía, marca ni composición de pantallas.

Esta guía prepara la entrega, pero F8 sigue parcial. Completar primero el borrado de cuenta y los controles de privacidad pendientes, incluida la descarga de exportación desde las apps. Esas funciones corresponden al endurecimiento; no se delegan a Claude como si fueran sólo cambios de diseño.

## Alcance y arquitectura

Consulta el [estado actual](../../PLAN.md), `AGENTS.md`, [mapa general](../00-home.md) y el mapa local de cada app. Usa el [informe F8](../runbooks/f8-verification.md) como evidencia de lo verificado y sus bloqueos. No interpretes este encargo como autorización de despliegue o incorporación de F5b.

`packages/design-tokens` está reservado para valores visuales compartidos. Actualmente no hay una canalización que haga consumir tokens a las tres apps. Define tokens semánticos y adaptadores para SwiftUI, Compose y CSS cuando se acuerde la dirección visual. Mantén la UI nativa y evita una capa compartida de renderizado. Documenta cuál archivo es la fuente de verdad y cómo se comprueba que los adaptadores coinciden.

Los puntos de entrada actuales son `apps/ios/MedicationTracker/DesignSystem`, `apps/android/app/src/main/kotlin/cl/nndsk/medication/ui` y `apps/web/src`. No muevas autorización, almacenamiento, colas o cálculos del backend a componentes visuales. No hace falta una reestructuración completa para cambiar el diseño.

## Comportamientos que debe preservar

- Las tres declaraciones siguen disponibles sin penalización visual. Una toma tardía requiere hora real; nunca recomendar compensar dosis.
- Sin confirmar, omitida y tomada tarde son estados distintos. Una declaración no prueba ingestión.
- Una acción offline se guarda antes de enviar. Reintentos conservan UUID, cuerpo y hora. Conflictos requieren resolución explícita.
- Saldo estimado local y saldo confirmado del servidor se distinguen. Cantidades decimales no se convierten en floats para cálculos.
- Los gráficos usan las métricas de API, muestran período, denominador y datos sin confirmar. No calcular estadísticas con una página parcial ni premiar consumo sobre registro honesto.
- Logout y cambio de cuenta limpian estado visible y no permiten que respuestas anteriores lo repueblen.
- Alcances efectivos gobiernan las acciones visibles, pero el backend sigue siendo quien autoriza. No añadir selector de cuidador móvil mientras F5b siga fuera de alcance.
- Las notificaciones abren la dosis; nunca declaran por abrirlas. Conserva texto discreto y advertencia de entrega no garantizada.
- Consentimiento, privacidad, exportación y borrado deben explicar consecuencias con lenguaje claro. No ocultar acciones destructivas bajo iconos ambiguos.

## Verificar el rediseño

Ejecuta `make test`, `make lint`, build web y los flujos Playwright con una base desechable. Para cambios nativos ejecuta unitarias, lint/build y E2E del stack afectado. Consulta README para requisitos del entorno; nunca uses una conexión de producción.

Compara los recorridos de paciente y cuidador con texto máximo, modo oscuro, estados vacíos/carga/error y permisos denegados. Repite VoiceOver/TalkBack y contraste con el diseño final. Cada gráfico necesita una alternativa textual comprensible y no debe depender sólo del color.

Entrega dirección visual, tokens y adaptadores, pantallas implementadas, evidencia de pruebas y pendientes. No marques el lanzamiento listo si siguen abiertos los controles de [release F8](../runbooks/f8-release.md).

## Estado de la entrega

Rama `design/graphite-tokens`. Nada de esto está desplegado ni acredita el lanzamiento: los controles de [release F8](../runbooks/f8-release.md) siguen abiertos.

### Implementado

- **Tokens:** Graphite en `packages/design-tokens`, con generador y comprobación de contraste. `chartTakenLate` claro y `chartSkipped` oscuro cambiaron para separar las series, y `chartSkipped` entró en `contrast.nonText`.
- **Paciente iOS y Android:** Hoy con fecha larga, «X de N registradas», tarjeta «Ahora toca», «Más tarde», «Ya registradas» y «Por revisar» primero. Hoja «Me lo tomé tarde» con −/+ 5 min, atajos, «Otra fecha u hora» y «Guardar con las HH:MM». Chips sobre pares Fg/Bg, banner sin conexión, aviso de recordatorios desactivados e iconos reales en la barra de Android.
- **Android, además:** barra superior con botón de volver, Detalle y Ajustes agrupados en secciones, corrección en una hoja aparte, e Historial con las tomas de hoy.
- **Cuidador web:** pestañas de paciente en el encabezado, secciones como navegación con `?section=`, alertas, panel Hoy, 4 KPI con denominador, barras apiladas con trama, leyenda, resumen y tabla. Inventario con lista, detalle, saldo confirmado y estimado, fecha de revisión, ventana de 30 días y tabla de movimientos.

### Decisiones

- Si la toma aún no vence, la tarjeta dice «Próxima toma» y no ofrece acciones: la API rechaza dosis futuras.
- Las demás dosis vencidas sin registrar quedan en «Más tarde», con su chip «Sin confirmar». Suben a la tarjeta una a una.
- Por decisión del usuario, una dosis con más de 4 horas de atraso sale de la tarjeta y pasa a «Pasaron sin registrar», sin que la app sugiera tomarla. Sigue siendo «Sin confirmar», cuenta en el total y se puede registrar al abrirla: no se marca como omitida. Las 4 horas son un valor de presentación, no clínico, y están en `currentWindow` de iOS y Android.
- Por decisión del usuario, Android guarda la declaración en disco de inmediato aunque haya una sincronización en curso, y los botones no se desactivan. Un segundo toque sobre la misma dosis no crea otra declaración.
- Android declara directamente desde Hoy, como iOS. Antes pedía revisar y confirmar. Las correcciones conservan motivo y revisión.
- El estado omitido se rotula «No tomada» para el paciente. La web mantiene «Declarada omitida».
- Se conservan el calendario de constancia, los filtros y el historial aceptados en F7.
- La API no entrega saldo por día. La proyección muestra la parte cubierta de la ventana, y el saldo estimado es `balance − scheduled_quantity` con resta exacta.
- El informe web espera a la consulta de hoy: en paralelo, ambas materializan dosis y chocan con 409.

### Validado

Con datos sintéticos y bases desechables.

- `make tokens-check`, `make test`, `make lint` y build web.
- `make test-web-e2e`: 7 pruebas con API y PostgreSQL reales.
- iOS en simulador: 71 unitarias y 7 pruebas UI E2E con `make test-ios-e2e`, con emulador de Auth, API y PostgreSQL reales.
- Android en emulador: 27 unitarias, 7 instrumentadas, lint Debug y Release, y `make test-android-e2e` con API y PostgreSQL reales. El E2E comprueba que una declaración llega a disco mientras la red está retenida.

### Pendiente

- Revisión manual de VoiceOver, TalkBack, modo oscuro nativo, texto máximo en Android y teléfono físico. En iOS sólo corre la auditoría automática con texto máximo.
- El E2E de Android abre la hoja tardía y comprueba que no admite horas futuras, pero no guarda desde ella. Ese guardado sólo se ejercita de punta a punta en iOS.
- Las alertas y el panel Hoy de la web usan la fecha del navegador, como la Agenda, no la zona del paciente.
- La web cae a la fuente del sistema mientras Geist no se aloje localmente.
- Confirmar con la familia si 4 horas es el plazo adecuado para «Pasaron sin registrar».
- Borrado de cuenta y descarga de exportación desde las apps. Esta guía los ubicaba antes del rediseño; el usuario decidió terminar primero el rediseño. Siguen bloqueando el lanzamiento.
