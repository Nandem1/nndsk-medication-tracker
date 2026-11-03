# Seguridad y privacidad antes del lanzamiento

F8 endurece los flujos existentes. No añade la vista móvil de cuidador de F5b ni cambia la identidad visual. La aprobación de fases anteriores no acredita publicación, cumplimiento legal ni cobertura física pendiente.

## Modelo de amenazas

| Activo y amenaza | Control existente o cambio F8 | Evidencia y límite |
| --- | --- | --- |
| Historial de otro paciente por manipulación de IDs | El backend resuelve el propietario desde el recurso y comprueba vínculo y alcance dentro de la transacción | `application/access.go`; integración IDOR y carrera revocación. No confiar en controles de la UI |
| Reintento después de revocar cuidador | Autorizar antes de consultar respuesta idempotente; bloqueo compartido del vínculo | `application/service.go`, `access_integration_test.go` |
| Token robado, cuenta deshabilitada o refresh revocado | F8 consulta revocación Firebase además de validar firma y claims | `auth/firebase.go`. Requiere credenciales administrativas; prueba local no acredita permisos del proyecto remoto |
| Respuesta de red que revive caché tras logout | Serializar trabajos y cierre; invalidar la sesión antes de esperar red | Ver verificación F8 para resultado de tests nativos |
| Teléfono perdido desbloqueado | Sandbox del SO, Keychain/Keystore, exclusión de backups, logout con limpieza | No hay bloqueo biométrico propio ni protección del selector de apps. Cifrado del dispositivo no protege una sesión abierta |
| Copia local después de revocar acceso | Web limpia sesión/caché ante rechazo. Móviles sólo implementan cuenta propia | Un dispositivo offline no recibe revocación inmediata. F5b debe probar invalidación de cachés por paciente al reconectar |
| Exposición en pantalla bloqueada o push | Texto genérico; revalidación antes de reservar entrega; TTL y deduplicación | `application/alerts.go`, `internal/push`. Un envío ya reservado puede llegar después de revocar |
| Exfiltración mediante exportación | Cuenta propia, campos permitidos y snapshot consistente | Nunca exportar secretos, replay bodies ni historia de pacientes a cargo |
| Logs, informes de fallos y artefactos de CI | Logs sin cuerpos, tokens, URLs ni nombres médicos; datos de pruebas sintéticos | No adjuntar exportaciones, dumps o capturas reales a incidencias. Métricas privadas |
| Restauración que recupera datos eliminados | Mantener destino aislado y reaplicar supresiones antes de habilitar tráfico | El mecanismo de borrado y supresiones debe verificarse antes de declarar esta garantía |
| Borrado que corrompe historia de otra persona | Separar titular de historia y autor de eventos | Política de borrado pendiente de confirmar. Los triggers append-only no son una justificación para retención indefinida |

## Identidad y dispositivo perdido

F8 cambia la API para usar `VerifyIDTokenAndCheckRevoked`. Configura Application Default Credentials mediante un archivo externo o identidad de workload con permisos mínimos para consultar usuarios de Firebase Authentication. No pongas claves administrativas en apps, repositorio o imágenes. La API falla cerrada si Firebase no permite comprobar la cuenta. Esto añade una consulta remota por validación; mide latencia antes de aumentar tráfico.

Para un teléfono perdido, revoca refresh tokens desde la administración autorizada de Firebase y desregistra sus dispositivos. Prueba que un ID token emitido antes de la revocación recibe 401. No basta cambiar la contraseña o borrar una fila local sin verificar el efecto. La revocación del cuidador sigue siendo independiente y se comprueba en PostgreSQL.

La salida local no equivale a revocar todas las sesiones de Firebase. El borrado lógico de SQLite/Room tampoco acredita eliminación forense de páginas libres o capturas del SO. Documenta ese límite sin prometer borrado remoto de un teléfono desconectado.

## Auditoría pendiente

No existe todavía un registro persistente de lecturas administrativas sensibles. Los logs HTTP minimizados no sustituyen esa auditoría. Definir retención y acceso antes de implementarla, con identificadores y clase de recurso, sin cuerpos ni nombres de medicamentos. Este punto permanece abierto para lanzamiento con datos reales.

## Decisiones de retención

La propuesta pendiente de aceptación es eliminar historia propia y credenciales de cuenta, revocar vínculos y dispositivos, y conservar sólo referencias sin identidad a acciones sobre historia ajena. Backups cifrados con caducidad máxima de 30 días; restauraciones sujetas a reaplicar supresiones.

No hay política automática de caducidad configurada en el proveedor por esta entrega. Hasta implementar y ensayar la purga, no anunciar borrado completo ni incorporar datos reales. No usar una marca `deleted` como sustituto de eliminación de contenido.

Los archivos de exportación pertenecen a quien los descarga. El servidor no debe guardarlos en almacenamiento público ni enviarlos a terceros. La interfaz futura debe advertir que contienen datos sensibles antes de compartirlos.

## Responder a un incidente

1. Registra hora, entorno, versión y categoría del fallo sin contenido médico ni tokens.
2. Restringe el acceso afectado y detén push si puede exponer información. Conserva métricas y evidencia mínima con acceso limitado.
3. Revoca sesiones o credenciales comprometidas. No borres el ledger para esconder el incidente.
4. Determina las cuentas y períodos afectados en una sesión administrativa autorizada. No copies resultados sensibles a tickets o chat.
5. Consulta al responsable legal sobre comunicación a titulares y autoridad según la ley vigente y los hechos. No se fija aquí un plazo universal sin determinar el régimen aplicable.
6. Restaura sólo en un entorno aislado, aplica supresiones e invalida dispositivos/outbox antes de servir tráfico. Sigue el [runbook de recuperación](f6-recovery.md).
7. Verifica acceso denegado, ausencia de doble consumo y reconciliación. Registra causa, reparación y prueba que impide repetición.

Antes de lanzamiento, el responsable debe nombrar quién opera backups, quién responde incidentes y cuál es el canal de contacto. Son decisiones operativas pendientes, no roles creados por el software.
