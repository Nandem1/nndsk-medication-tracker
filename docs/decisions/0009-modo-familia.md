# Modo familia

Estado: decisiones aceptadas en PLAN-FAMILIA.md. Implementación por fases desde P0.

## Producto e identidad

Los vínculos paciente-cuidador modelan los permisos. No se añade una entidad familia. Cada persona tiene su propia cuenta Firebase, con registro y recuperación dentro de las apps y del portal, y un único nombre visible para todos. El backend autoriza cada operación. La preferencia local de uso sólo modifica la navegación.

Las invitaciones se comparten como código que se pega, sin enlaces con token ni QR. Pueden sugerir un nombre, que la aceptación aplica sólo si el paciente aún no completó su perfil. Los cambios de nombre usan versión esperada, idempotencia y auditoría.

La vista cuidador incluye nombres, vista conjunta, declaraciones e inventario. Crear y editar tratamientos sigue reservado al portal. La UI iOS del paciente conserva su diseño. Android sigue su estructura con componentes nativos. Los avisos remotos se ocultan mientras push no esté configurado.

## Inventario compartido previsto para P5

Cada tratamiento conserva su cuenta y sus movimientos. Un inventario compartido agrupa cuentas y, cuando todos los pacientes consienten, su saldo es la suma de los movimientos de esas cuentas. Mientras haya consentimientos pendientes, los saldos siguen separados. El cuidador no acepta por el paciente.

El servidor exige el mismo nombre, concentración y forma tras normalizar espacios y mayúsculas, y unidad idéntica. No elimina acentos ni aplica coincidencia aproximada. Los permisos de inventario deben cubrir todas las cuentas propuestas.

Se conserva la relación única entre tratamiento y cuenta, las claves foráneas compuestas y el consumo único por evento. Cambiar a una cuenta con varios tratamientos rompería esas relaciones y complicaría la exportación propia. Los traspasos manuales entre cuentas tampoco representan una caja común.

Las operaciones bloquean primero el inventario activo y después sus cuentas ordenadas por identificador. Vuelven a comprobar la membresía bajo bloqueo. El conteo compara el saldo común. La proyección combina las dosis de los tratamientos miembros y distingue cada dosis por tratamiento e instante, respetando su zona horaria.

Al salir, el saldo de la cuenta se transfiere mediante movimientos compensatorios a la primera cuenta que permanece. La cuenta saliente queda en cero. Una sola cuenta restante disuelve el inventario. Las correcciones posteriores pertenecen a la cuenta original de la dosis.

Sin acceso a otro paciente, el servidor oculta su nombre, autor, nota, tratamiento y hora de movimientos. Sólo entrega cantidad, fecha y motivo genérico. La exportación incluye exclusivamente movimientos propios. Las alertas usan una cuenta representante para evitar duplicados.

## Exportación y eliminación previstas para P6

Las apps exportan a un archivo temporal privado que comparten y eliminan después. El borrado sale de inventarios compartidos, revoca vínculos y elimina la historia propia en una transacción. Conserva anonimizado al autor de historia ajena. La eliminación en Firebase admite reintento. Las supresiones tras restaurar backups y la aceptación de retención siguen pendientes.

## Entrega y límites

La ejecución sigue P0 a P7, con pruebas en verde antes de cada cierre y de avanzar. El usuario autoriza commits, merge y push en main y la rama de trabajo, y migraciones y despliegues en staging con datos de prueba. Producción, tiendas y creación de credenciales quedan fuera.

El escenario completo y las pruebas obligatorias están en [PLAN-FAMILIA.md](../../PLAN-FAMILIA.md). Esta decisión registra el diseño aprobado; no acredita su implementación ni verificación.
