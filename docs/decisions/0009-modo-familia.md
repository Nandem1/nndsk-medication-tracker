# Modo familia

Estado: decisiones aceptadas en PLAN-FAMILIA.md. Implementación por fases desde P0.

## Producto e identidad

Los vínculos paciente-cuidador modelan los permisos. No se añade una entidad familia. Cada persona tiene su propia cuenta Firebase, con registro y recuperación dentro de las apps y del portal, y un único nombre visible para todos. El backend autoriza cada operación. La preferencia local de uso sólo modifica la navegación.

Las invitaciones se comparten como código que se pega, sin enlaces con token ni QR. Pueden sugerir un nombre, que la aceptación aplica sólo si el paciente aún no completó su perfil. Los cambios de nombre usan versión esperada, idempotencia y auditoría.

La vista cuidador incluye nombres, vista conjunta, declaraciones e inventario. Crear y editar tratamientos sigue reservado al portal. La UI iOS del paciente conserva su diseño. Android sigue su estructura con componentes nativos. Los avisos remotos se ocultan mientras push no esté configurado.

## Inventario compartido

Cada tratamiento conserva su cuenta y sus movimientos. Un inventario compartido agrupa cuentas y, cuando todos los pacientes consienten, su saldo es la suma de los movimientos de esas cuentas. Mientras haya consentimientos pendientes, los saldos siguen separados. El cuidador no acepta por el paciente.

El servidor exige el mismo nombre, concentración y forma tras normalizar espacios y mayúsculas, y unidad idéntica. No elimina acentos ni aplica coincidencia aproximada. Los permisos de inventario deben cubrir todas las cuentas propuestas.

Se conserva la relación única entre tratamiento y cuenta, las claves foráneas compuestas y el consumo único por evento. Cambiar a una cuenta con varios tratamientos rompería esas relaciones y complicaría la exportación propia. Los traspasos manuales entre cuentas tampoco representan una caja común.

Las operaciones bloquean primero el inventario activo y después sus cuentas ordenadas por identificador. Vuelven a comprobar la membresía bajo bloqueo. El conteo compara el saldo común. La proyección combina las dosis de los tratamientos miembros y distingue cada dosis por tratamiento e instante, respetando su zona horaria.

Al salir, el saldo de la cuenta se transfiere mediante movimientos compensatorios a la primera cuenta que permanece. La cuenta saliente queda en cero. Una sola cuenta restante disuelve el inventario. Las correcciones posteriores pertenecen a la cuenta original de la dosis.

Sin acceso a otro paciente, el servidor oculta su nombre, autor, nota, tratamiento y hora de movimientos. Sólo entrega cantidad, fecha y motivo genérico. La exportación incluye exclusivamente movimientos propios. Las alertas usan una cuenta representante para evitar duplicados.

### Diferencias con el plan al implementar P5

- **Candado de membresía.** Además de bloquear inventario y cuentas, un candado consultivo global ordena los cambios de membresía frente a los bloqueos: toda mutación lo comparte antes de tomar filas, y quien crea, decide, sale o borra una cuenta lo toma en exclusiva. Evita que una cuenta se incorpore a un inventario activo mientras otra transacción ya decidió bloquear sólo esa cuenta. Sustituye a la relectura de membresía del plan, innecesaria con el candado. Los cambios de membresía son poco frecuentes, así que el costo es bajo.
- **Movimientos de otros miembros.** Sólo se listan desde la activación. Los anteriores son previos al consentimiento y no se exponen. El saldo común sí los suma, así que la lista puede no explicar el saldo completo.
- **Quién ve nombres.** Los miembros vigentes, con decisión pendiente o aceptada, ven el nombre de los demás, porque la propuesta debe decir con quién se comparte. Quien rechazó o salió deja de verlos. Sus movimientos siguen en formato neutro si no tienen vínculo con esa persona.
- **Alerta de stock.** La cuenta representante es la de menor identificador entre las que ese cuidador sigue, no entre todas las del inventario. Con el menor absoluto, un cuidador que sigue sólo al otro paciente nunca recibiría el aviso.
- **Campos añadidos al contrato.** `current` y `status` en cada miembro permiten decir «Compartido con» y «Esperando a» sin exponer identificadores.
- **«Ahora no» es un rechazo.** La API sólo distingue aceptar y rechazar. Compartir de nuevo requiere otra propuesta.
- **Segundo movimiento del traspaso.** `inventory_movements` exige una operación única por actor, así que el segundo movimiento usa una clave derivada de la operación original.

### Desfase de reloj en declaraciones

Las declaraciones envían la hora del teléfono para que funcionen sin conexión, y el servidor rechazaba cualquier hora posterior a la suya. Un reloj adelantado 0,48 s en el emulador dejó «Me lo tomé» como «Necesita revisión: datos rechazados». El servidor acepta ahora hasta 5 minutos de adelanto y guarda su propia hora, de modo que `occurred_at` nunca supera a `recorded_at`. Con más adelanto sigue rechazando y el registro queda visible para la persona. No cambia el consumo ni el estado de la dosis.

## Exportación y eliminación

Las apps exportan a un archivo temporal privado que comparten y eliminan después. El borrado sale de inventarios compartidos, revoca vínculos y elimina la historia propia en una transacción. Conserva anonimizado al autor de historia ajena. La eliminación en Firebase admite reintento. Las supresiones tras restaurar backups y la aceptación de retención siguen pendientes.

### Diferencias con el plan al implementar P6

- **Append-only con una sola excepción.** La migración 8 hace que los triggers de historia permitan cambios sólo si la transacción declara `app.account_deletion`. Sólo `DeleteAccount` lo hace. Las FK `RESTRICT` no cambian.
- **Sin fila de replay.** El borrado no usa la tabla `operations`, porque conservaría datos de la cuenta eliminada. La idempotencia es de efecto: un reintento encuentra una cuenta vacía y vuelve a responder bien.
- **Operaciones de terceros.** También se borran las respuestas de replay de otras personas que nombran a quien se va o sus dosis, tratamientos, cuentas, movimientos, conteos o cambios de nombre. Una petición que llega entre el commit y la baja de Firebase puede recrear una fila vacía, y se elimina tras la baja.
- **Vínculos.** Como paciente se eliminan con su historia de consentimiento. Como cuidador se revocan y auditan, porque pertenecen a la historia del otro paciente.
- **Fila de usuario.** Se anonimiza y se intenta eliminar. Si la historia ajena la referencia, queda como «Cuenta eliminada».
- **Identidad.** Firebase se elimina después del commit. `identity_removed=false` indica que los datos se borraron y que el acceso sigue activo, para reintentar.
- **Web.** Tiene eliminar cuenta, pero no descarga: la sección 10.1 pide exportación desde las apps.

## Entrega y límites

La ejecución sigue P0 a P7, con pruebas en verde antes de cada cierre y de avanzar. El usuario autoriza commits, merge y push en main y la rama de trabajo, y migraciones y despliegues en staging con datos de prueba. Producción, tiendas y creación de credenciales quedan fuera.

El escenario completo y las pruebas obligatorias están en [PLAN-FAMILIA.md](../../PLAN-FAMILIA.md). Esta decisión registra el diseño aprobado; no acredita su implementación ni verificación.
