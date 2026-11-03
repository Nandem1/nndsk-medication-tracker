package cl.nndsk.medication.ui

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation3.runtime.NavKey
import androidx.navigation3.runtime.entryProvider
import androidx.navigation3.runtime.rememberNavBackStack
import androidx.navigation3.ui.NavDisplay
import cl.nndsk.medication.PatientViewModel
import cl.nndsk.medication.core.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable
import java.time.*
import java.util.UUID

@Serializable data class Tab(val name: String) : NavKey
@Serializable data class Detail(val id: String) : NavKey
private val tabs = listOf("Hoy", "Historial", "Ajustes")

@Composable
fun PatientApp(model: PatientViewModel, incoming: StateFlow<Uri?>) {
    val state by model.state.collectAsStateWithLifecycle()
    val requested by incoming.collectAsStateWithLifecycle()
    val stack = rememberNavBackStack(Tab("Hoy"))
    var confirmClearLocal by remember { mutableStateOf(false) }
    var now by remember { mutableStateOf(Instant.now()) }
    LaunchedEffect(Unit) { while (true) { now = Instant.now(); delay(30_000) } }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { model.run { model.repository.sync() } }
    LaunchedEffect(state.session) {
        if (state.session == Session.SignedOut) { stack.clear(); stack.add(Tab("Hoy")) }
    }
    LaunchedEffect(requested, state.snapshot?.context) {
        val parts = requested?.pathSegments.orEmpty()
        val c = state.snapshot?.context
        if (parts.size == 3 && c != null && parts[0] == c.ownerUid && parts[1] == c.patientId && state.snapshot?.doses?.any { it.id == parts[2] } == true) {
            stack.clear(); stack.add(Tab("Hoy")); stack.add(Detail(parts[2]))
        }
    }
    Scaffold(bottomBar = {
        if (state.session == Session.Active) NavigationBar {
            tabs.forEach { name -> NavigationBarItem(selected = stack.lastOrNull() == Tab(name), onClick = { stack.clear(); stack.add(Tab(name)) }, icon = {}, label = { Text(name) }) }
        }
    }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).padding(horizontal = 16.dp)) {
            Text("Mis tomas", style = MaterialTheme.typography.headlineMedium, modifier = Modifier.padding(vertical = 12.dp))
            if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            state.message?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(vertical = 8.dp)) }
            if (state.session != Session.Active) {
                Login(state.busy, state.session == Session.Expired) { email, password -> model.run { model.repository.login(email, password) } }
                TextButton(enabled = !state.busy, onClick = { confirmClearLocal = true }) { Text("Cerrar sesión y borrar datos locales") }
            } else {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text("${state.operations.size} pendientes", modifier = Modifier.weight(1f))
                    TextButton(enabled = !state.busy, onClick = { model.run { model.repository.sync() } }) { Text("Sincronizar") }
                }
                state.snapshot?.refreshedAt?.let { Text("Última actualización: ${formatInstant(it)}", style = MaterialTheme.typography.bodySmall) }
                NavDisplay(backStack = stack, onBack = { if (stack.size > 1) stack.removeLastOrNull() }, modifier = Modifier.weight(1f), entryProvider = entryProvider {
                    entry<Tab> { tab -> when (tab.name) {
                        "Hoy" -> Agenda(state, now, false) { stack.add(Detail(it)) }
                        "Historial" -> Agenda(state, now, true) { stack.add(Detail(it)) }
                        else -> PatientSettings(model, state) { stack.add(Detail(it)) }
                    } }
                    entry<Detail> { detail -> DoseDetail(model, state, detail.id) }
                })
            }
        }
    }
    if (confirmClearLocal) AlertDialog(onDismissRequest = { confirmClearLocal = false }, title = { Text("Borrar datos locales") },
        text = { Text("Se borrarán los datos de este dispositivo y todas las declaraciones pendientes de sincronizar, aunque no se puedan mostrar en esta pantalla. No se enviarán con otra cuenta.") },
        confirmButton = { TextButton(onClick = { confirmClearLocal = false; model.run { model.repository.logout() } }) { Text("Cerrar y borrar") } },
        dismissButton = { TextButton(onClick = { confirmClearLocal = false }) { Text("Volver") } })
}

@Composable private fun Login(busy: Boolean, expired: Boolean, submit: (String, String) -> Unit) {
    var email by remember { mutableStateOf("") }; var password by remember { mutableStateOf("") }
    Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(if (expired) "Renueva tu sesión con la misma cuenta" else "Inicia sesión")
        OutlinedTextField(email, { email = it }, label = { Text("Correo") }, singleLine = true, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(password, { password = it }, label = { Text("Contraseña") }, singleLine = true, visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth())
        Action("Entrar", enabled = !busy && email.isNotBlank() && password.isNotEmpty()) { submit(email, password); password = "" }
        Text("Cada persona usa su propia cuenta. Los registros son declaraciones y no demuestran ingestión.")
    }
}

@Composable private fun Agenda(state: AppState, now: Instant, history: Boolean, open: (String) -> Unit) {
    val snapshot = state.snapshot
    val doses = snapshot?.doses.orEmpty().filter { if (history) !it.today(now) && Instant.parse(it.scheduledAt) < now else it.today(now) }
        .sortedBy { it.scheduledAt }.let { if (history) it.reversed() else it }
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(if (history) "Historial de los últimos 7 días" else "Hoy", style = MaterialTheme.typography.titleLarge)
        if (doses.isEmpty()) Text(if (snapshot?.refreshedAt == null) "Sin agenda guardada. Conéctate y sincroniza para cargar tus tomas." else "No hay dosis en este período.")
        doses.forEach { dose ->
            val treatment = snapshot?.treatments?.find { it.id == dose.treatmentId }
            val pending = state.operations.find { it.dose == dose.id }
            Card(modifier = Modifier.fillMaxWidth(), onClick = { open(dose.id) }) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(treatment?.name ?: "Tratamiento", style = MaterialTheme.typography.titleLarge)
                    Text("${quantityText(dose.quantity)} ${unitLabel(treatment?.unit)} · ${dose.localTime} · ${dose.timezone}")
                    if (history) Text(dose.localDate)
                    Text(pending?.let { operationLabel(it.status) } ?: stateLabel(dose, now))
                    if (dose.dstAdjusted) Text("Horario ajustado por cambio de hora. Revisa la pauta con tu profesional.")
                    Text("Abrir detalle")
                }
            }
        }
        Spacer(Modifier.height(12.dp))
    }
}

@Composable private fun DoseDetail(model: PatientViewModel, state: AppState, id: String) {
    val snapshot = state.snapshot
    val dose = snapshot?.doses?.find { it.id == id }
    if (dose == null) { Text("Esta dosis ya no está en la agenda actual. Revisa los pendientes en Ajustes."); return }
    val treatment = snapshot.treatments.find { it.id == dose.treatmentId }
    val pending = state.operations.find { it.dose == id }
    var selected by remember(id) { mutableStateOf<String?>(null) }
    var date by remember(id) { mutableStateOf("") }; var time by remember(id) { mutableStateOf("") }
    var selectedOffset by remember(id, date, time) { mutableStateOf<String?>(null) }
    val offsets = runCatching { effectiveOffsets(date, time, dose.timezone) }.getOrDefault(emptyList())
    var reason by remember(id) { mutableStateOf("") }; var error by remember(id) { mutableStateOf<String?>(null) }
    var confirmation by remember(id) { mutableStateOf<Command?>(null) }
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(treatment?.name ?: "Tratamiento", style = MaterialTheme.typography.headlineSmall)
        Text("${quantityText(dose.quantity)} ${unitLabel(treatment?.unit)} · ${treatment?.strength.orEmpty()}")
        Text("${dose.localDate} ${dose.localTime} · ${dose.timezone}")
        Text(stateLabel(dose)); Text(treatment?.instructions.orEmpty())
        snapshot.inventory.find { it.treatmentId == dose.treatmentId }?.let {
            Text("Stock confirmado en la última actualización: ${quantityText(it.balance)} ${unitLabel(it.unit)}")
            if (state.operations.isNotEmpty()) {
                val estimate = estimatedBalance(snapshot, state.operations, dose.treatmentId)
                Text(if (estimate == null) "Stock estimado no disponible hasta revisar los pendientes." else "Stock estimado con pendientes: ${quantityText(estimate)} ${unitLabel(it.unit)}. Aún no confirmado por el servidor.")
            }
        }
        if (pending != null) {
            Text(operationLabel(pending.status))
            Text("Tu declaración está guardada. El stock confirmado no incluye cambios sin sincronizar.")
        } else {
            if (dose.declared()) Text("Corregir registro", style = MaterialTheme.typography.titleLarge)
            listOf("taken" to "Me lo tomé", "taken_late" to "Me lo tomé tarde", "skipped" to "No me lo tomé").forEach { (type, label) ->
                Action(if (selected == type) "✓ $label" else label, enabled = !state.busy) { selected = type; error = null }
            }
            if (selected == "taken_late") {
                Text("Indica cuándo la tomaste, en la zona ${dose.timezone}.")
                OutlinedTextField(date, { date = it }, label = { Text("Fecha (AAAA-MM-DD)") }, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(time, { time = it }, label = { Text("Hora (HH:mm)") }, modifier = Modifier.fillMaxWidth())
                if (offsets.size == 2) {
                    Text("Esta hora ocurrió dos veces por el cambio horario. Elige cuándo la tomaste.")
                    offsets.forEachIndexed { index, offset ->
                        Action("${if (selectedOffset == offset.id) "✓ " else ""}${if (index == 0) "Primera" else "Segunda"} vez · UTC${offset.id}") { selectedOffset = offset.id }
                    }
                }
            }
            if (dose.declared()) OutlinedTextField(reason, { reason = it }, label = { Text("Motivo de la corrección") }, modifier = Modifier.fillMaxWidth())
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            if (selected != null) Action("Revisar declaración", enabled = !state.busy) {
                try {
                    val occurred = if (selected == "taken_late") {
                        effectiveInstant(date, time, dose.timezone, selectedOffset)
                    } else null
                    confirmation = declaration(dose, selected!!, occurred, reason)
                } catch (e: IllegalArgumentException) { error = e.message ?: "Revisa la fecha, hora y motivo." }
                catch (_: Exception) { error = "Usa una fecha y hora válidas." }
            }
        }
        Text("Si olvidaste una dosis o la tomaste tarde, sigue las instrucciones de tu profesional o consulta a un profesional o farmacéutico. Esta app no indica cambiar ni compensar dosis.")
        Spacer(Modifier.height(12.dp))
    }
    confirmation?.let { command ->
        AlertDialog(onDismissRequest = { confirmation = null }, title = { Text("Confirmar declaración") },
            text = { Text("${declarationLabel(command.eventType)}${command.occurredAt?.let { " · ${formatInstant(it)}" }.orEmpty()}. Se guardará para sincronizar. ${if (dose.declared()) "La corrección conserva el historial." else ""}") },
            confirmButton = { TextButton(onClick = {
                confirmation = null
                model.run { model.repository.record(snapshot.context, id, command) }
            }) { Text("Guardar") } }, dismissButton = { TextButton(onClick = { confirmation = null }) { Text("Volver") } })
    }
}

@Composable private fun PatientSettings(model: PatientViewModel, state: AppState, open: (String) -> Unit) {
    val context = LocalContext.current
    var diagnostic by remember { mutableStateOf(model.app.reminders.diagnostic()) }
    val pushDiagnostic by model.app.remotePush.diagnostic.collectAsStateWithLifecycle()
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        model.run { model.app.reminders.reconcile(); model.app.remotePush.reconcile(); diagnostic = model.app.reminders.diagnostic() }
    }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { diagnostic = model.app.reminders.diagnostic() }
    var logout by remember { mutableStateOf(false) }
    var discard by remember { mutableStateOf<PendingOperation?>(null) }
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Recordatorios", style = MaterialTheme.typography.titleLarge)
        Text(diagnostic)
        Text("Los permisos, Doze y el ahorro de batería pueden retrasar o impedir avisos. Abre la app y sincroniza para renovar la agenda guardada.")
        Action("Permitir notificaciones") {
            if (Build.VERSION.SDK_INT >= 33) permission.launch(Manifest.permission.POST_NOTIFICATIONS)
            else context.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName))
        }
        Action("Ajustes de notificaciones") { context.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)) }
        if (Build.VERSION.SDK_INT >= 31 && !model.app.reminders.exact()) Action("Permitir mayor precisión") {
            context.startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:${context.packageName}")))
        }
        Text("Avisos remotos del cuidador", style = MaterialTheme.typography.titleLarge)
        Text(pushDiagnostic)
        Text("Registros pendientes", style = MaterialTheme.typography.titleLarge)
        state.operations.forEach { op ->
            val body = wireJson.decodeFromString<Command>(op.body)
            Card(Modifier.fillMaxWidth()) { Column(Modifier.padding(12.dp)) {
                val dose = state.snapshot?.doses?.find { it.id == op.dose }
                val treatment = state.snapshot?.treatments?.find { it.id == dose?.treatmentId }
                Text(treatment?.name ?: "Dosis fuera de la agenda guardada · ${op.dose.take(8)}")
                dose?.let {
                    Text("${it.localDate} ${it.localTime} · ${it.timezone}")
                    TextButton(onClick = { open(it.id) }) { Text("Abrir dosis") }
                }
                Text(declarationLabel(body.eventType)); Text(body.occurredAt?.let(::formatInstant).orEmpty())
                Text(operationLabel(op.status))
                if (op.status != "pending") {
                    Text("Sincroniza para revisar el estado actual. Puedes conservar el registro del servidor y descartar esta declaración; para corregirlo, abre la dosis en el historial.")
                    TextButton(onClick = { discard = op }) { Text("Descartar declaración local") }
                }
            } }
        }
        Consent(model, state)
        Text("Estos registros son autodeclarados y no demuestran ingestión.")
        Action("Cerrar sesión", enabled = !state.busy) { logout = true }
        Spacer(Modifier.height(16.dp))
    }
    if (logout) AlertDialog(onDismissRequest = { logout = false }, title = { Text("Cerrar sesión") },
        text = { Text("Se borrarán la agenda, los recordatorios y ${state.operations.size} declaraciones locales pendientes de este teléfono. Sincroniza primero si deseas conservarlas en el servidor.") },
        confirmButton = { TextButton(onClick = { logout = false; model.run { model.repository.logout() } }) { Text("Cerrar y borrar datos locales") } },
        dismissButton = { TextButton(onClick = { logout = false }) { Text("Volver") } })
    discard?.let { op -> AlertDialog(onDismissRequest = { discard = null }, title = { Text("Descartar declaración local") },
        text = { Text("El registro del servidor se conserva. Esta declaración local no se volverá a enviar.") },
        confirmButton = { TextButton(onClick = { discard = null; model.run { model.repository.discard(op.id) } }) { Text("Descartar") } },
        dismissButton = { TextButton(onClick = { discard = null }) { Text("Volver") } }) }
}

@Composable private fun Consent(model: PatientViewModel, state: AppState) {
    var token by remember { mutableStateOf("") }; var preview by remember { mutableStateOf<Pair<String, Invitation>?>(null) }
    var previewBusy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }; var revoke by remember { mutableStateOf<Link?>(null) }
    Text("Acceso de cuidadores", style = MaterialTheme.typography.titleLarge)
    Text("Tú autorizas el acceso y puedes revocarlo. Un teléfono sin conexión puede conservar su copia hasta volver a conectarse.")
    OutlinedTextField(token, { token = it; preview = null; error = null }, label = { Text("Código de invitación") }, enabled = !previewBusy, modifier = Modifier.fillMaxWidth())
    Action("Revisar invitación", enabled = token.isNotBlank() && !state.busy && !previewBusy) {
        val requestedToken = token.trim()
        previewBusy = true
        model.run {
            try {
                val result = model.repository.preview(requestedToken)
                if (token.trim() == requestedToken) { preview = requestedToken to result; error = null }
            } catch (_: Exception) { error = "No se pudo revisar la invitación. Comprueba el código y la conexión." }
            finally { previewBusy = false }
        }
    }
    error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
    preview?.let { (reviewedToken, invitation) ->
        Text("Cuidador: ${invitation.caregiverId}")
        Text("Permisos solicitados: ${invitation.scopes.joinToString { scopeLabel(it) }}")
        Text("Vence: ${formatInstant(invitation.expiresAt)}")
        Action("Autorizar estos permisos", enabled = !state.busy) { model.run { model.repository.accept(reviewedToken); preview = null } }
    }
    state.snapshot?.links.orEmpty().forEach { link ->
        Text("Cuidador ${link.caregiverId} · ${link.scopes.joinToString { scopeLabel(it) }}")
        Action("Revocar acceso", enabled = !state.busy) { revoke = link }
    }
    revoke?.let { link -> AlertDialog(onDismissRequest = { revoke = null }, title = { Text("Revocar acceso") },
        text = { Text("El cuidador dejará de tener acceso al servidor. Un teléfono offline puede conservar su copia hasta detectar la revocación.") },
        confirmButton = { TextButton(onClick = { revoke = null; model.run { model.repository.revoke(link.id) } }) { Text("Revocar") } },
        dismissButton = { TextButton(onClick = { revoke = null }) { Text("Volver") } }) }
}

@Composable private fun Action(label: String, enabled: Boolean = true, action: () -> Unit) {
    Button(onClick = action, enabled = enabled, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text(label) }
}
private fun formatInstant(value: String): String = runCatching { Instant.parse(value).atZone(ZoneId.systemDefault()).format(java.time.format.DateTimeFormatter.ofPattern("dd-MM-yyyy HH:mm")) }.getOrDefault(value)
private fun declarationLabel(value: String) = when (value) { "taken" -> "Me lo tomé"; "taken_late" -> "Me lo tomé tarde"; else -> "No me lo tomé" }
private fun operationLabel(value: String) = when (value) { "conflict" -> "Necesita revisión: cambió en el servidor"; "rejected" -> "Necesita revisión: datos rechazados"; "denied" -> "Necesita revisión: acceso denegado"; else -> "Pendiente de sincronizar" }
private fun unitLabel(value: String?) = when (value) { "tablet" -> "comprimidos"; "capsule" -> "cápsulas"; "dose" -> "dosis"; "ml" -> "ml"; else -> "unidades" }
private fun scopeLabel(value: String) = when (value) { "read" -> "Consultar información"; "doses" -> "Registrar y corregir tomas"; "inventory" -> "Administrar inventario"; "treatments" -> "Administrar tratamientos"; else -> value }
