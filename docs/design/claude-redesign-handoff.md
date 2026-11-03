# Rediseñar las tres interfaces sin cambiar el dominio

El usuario encarga a Claude el rediseño visual de iOS, Android y web después del endurecimiento F8. Busca más gráficos, una identidad reconocible y consistencia entre plataformas. F8 no decide paleta, tipografía, marca ni composición de pantallas.

Esta guía prepara la entrega, pero F8 sigue parcial. Completar primero el borrado de cuenta y los controles de privacidad pendientes, incluida la descarga de exportación desde las apps. Esas funciones corresponden al endurecimiento; no se delegan a Claude como si fueran sólo cambios de diseño.

## Alcance y arquitectura

Lee `PLAN.md`, `AGENTS.md`, [mapa general](../00-home.md) y el mapa local de cada app. Usa el [informe F8](../runbooks/f8-verification.md) como evidencia de lo verificado y sus bloqueos. No interpretes este encargo como autorización de despliegue o incorporación de F5b.

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
