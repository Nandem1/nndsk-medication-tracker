# Preparar el lanzamiento familiar

Este checklist no autoriza publicación ni despliegue. La distribución de pruebas y la publicación en tiendas necesitan decisiones y configuración propias. No se introducen datos reales hasta resolver los bloqueos de privacidad.

## Revisar requisitos oficiales

Consulta realizada el 2026-11-03. Repite la revisión antes de distribuir, porque las políticas pueden cambiar.

- Apple exige política de privacidad y declaraciones de datos coherentes con lo que recoge la app. Si permite crear cuentas, debe permitir iniciar su eliminación dentro de la app. Revisa [App Review Guidelines, sección 5.1](https://developer.apple.com/app-store/review/guidelines/), [eliminación de cuenta](https://developer.apple.com/support/offering-account-deletion-in-your-app/) y [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/). Salud y medicamentos aportados por el usuario también son datos de salud.
- Google Play exige declarar las funciones de salud y cumplir sus reglas de privacidad. La declaración aplica también a pistas de pruebas cerradas y abiertas. Revisa [Health apps declaration](https://support.google.com/googleplay/android-developer/answer/14738291?hl=en) y [Health Content and Services](https://support.google.com/googleplay/android-developer/answer/16679511). Si la app permite crear cuentas, revisa las vías dentro y fuera de la app para solicitar borrado en [account deletion requirements](https://support.google.com/googleplay/android-developer/answer/13327111?hl=en-EN).
- En Chile, revisa la [Ley 19.628](https://www.bcn.cl/leychile/Navegar?dt=open&idLey=19628) y la [Ley 21.719](https://www.bcn.cl/leychile/Navegar?idNorma=1209272&idParte=10527471&idVersion=2026-12-01). El texto BCN consultado indica entrada en vigor de esta última el 1 de diciembre de 2026. El Ministerio de Economía publicó una [propuesta de postergación](https://www.economia.gob.cl/2026/09/01/gobierno-propone-ampliar-plazo-para-implementar-nueva-ley-de-proteccion-de-datos-y-institucionalidad.htm). Una propuesta no acredita una modificación promulgada; confirmar la versión vigente al publicar.

Esta revisión identifica requisitos técnicos y preguntas de lanzamiento. No certifica cumplimiento legal. Determinar responsable, base del tratamiento, consentimiento, transferencias internacionales, proveedores, atención de derechos y obligaciones sobre incidentes con revisión jurídica. No asumir exención por uso familiar.

## Verificar antes de distribuir

- [ ] Elegir canal de distribución y responsables operativos.
- [ ] Publicar política de privacidad y contacto reales, coherentes con Firebase, hosting, backups y datos locales.
- [ ] Completar y ensayar exportación y borrado de cuenta, identidad Firebase y supresiones después de restore.
- [ ] Configurar caducidad de backups y verificar borrado de copias vencidas. Completar restore cloud/PITR pendiente de F6 si forma parte del servicio elegido.
- [ ] Verificar Firebase con credenciales administrativas del entorno y token previo a revocación. No sustituirlo por un mock.
- [ ] Ejecutar workflows remotos Go, web y Android. Habilitar iOS sólo con runner y simulador disponibles.
- [ ] Revisar dependencias, secretos, firmas, permisos, URLs y configuración Release.
- [ ] Probar accesibilidad y flujo offline en los teléfonos objetivo con fixtures sintéticos.
- [ ] Repetir auditoría visual después del rediseño de Claude.
- [ ] Completar fichas App Privacy/Data safety y declaración de salud según el canal.
- [ ] Verificar entrega APNs/FCM antes de activarla. Push permanece desactivado mientras ese ensayo esté pendiente.
- [ ] Autorizar explícitamente despliegue/publicación después de revisar evidencia.

## Auditar móviles y accesibilidad

La evidencia anterior incluye Android 13 en Xiaomi 2107113SG y simuladores. No acredita todos los modelos ni una prueba manual con lectores de pantalla. Registra modelo, versión del SO, build, fecha, pasos y resultado de cada caso.

| Caso | Verificación necesaria |
| --- | --- |
| VoiceOver y TalkBack | Orden de foco, nombre/estado de cada acción, lectura de dosis y errores, consentimiento completo |
| Tamaño de texto máximo | Sin recortar dosis, unidades, hora ni botones; formularios desplazables y teclado accesible |
| Contraste y modo oscuro | Diferencias mediante texto/icono además del color; verificar de nuevo con los tokens definitivos |
| Logout con red lenta | Historial en vuelo no reaparece; no quedan agenda, cola ni recordatorios accesibles |
| Sesión expirada | Permite borrar datos locales con explicación de declaraciones pendientes |
| Offline 24 horas | Cola durable, hora real de toma tardía y consumo único al recuperar conexión |
| Permisos y batería | Notificaciones denegadas, alarmas aproximadas, Doze, reboot y ahorro del fabricante |
| Privacidad física | Pantalla bloqueada y selector de apps; documentar límites de capturas y dispositivo desbloqueado |

No marcar accesibilidad completa con un build o un test de contraste solamente. Tampoco cerrar compatibilidad usando únicamente el minSdk o deployment target.

## CI por stack

Go compila API/worker/backup y ejecuta race tests, vet, integración PostgreSQL y smoke. Web instala las versiones fijadas, ejecuta tipos, unitarias, build y Playwright con API/PostgreSQL sintéticos. Android compila y ejecuta unitarias y lint en Linux con JDK 21 y SDK 37.

iOS usa un workflow manual en macOS. `ENABLE_IOS_CI=true` habilita su ejecución en pull requests; el destino de simulador debe existir en ese runner. No hay secretos ni firma de distribución en estos jobs. Su presencia en YAML no acredita ejecución remota exitosa. Las pruebas nativas de dispositivo siguen siendo una puerta adicional al release.
