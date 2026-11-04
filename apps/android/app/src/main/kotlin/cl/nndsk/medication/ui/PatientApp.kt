package cl.nndsk.medication.ui

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation3.runtime.NavKey
import androidx.navigation3.runtime.entryProvider
import androidx.navigation3.runtime.rememberNavBackStack
import androidx.navigation3.ui.NavDisplay
import cl.nndsk.medication.PatientViewModel
import cl.nndsk.medication.R
import cl.nndsk.medication.core.*
import cl.nndsk.medication.ui.theme.GraphiteTokens
import cl.nndsk.medication.ui.theme.MedicationTrackerTheme
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable
import java.time.*
import java.util.UUID

@Serializable data class Tab(val name: String) : NavKey
@Serializable data class Detail(val id: String) : NavKey
private val tabs = listOf("Hoy" to R.drawable.ic_today, "Historial" to R.drawable.ic_history, "Ajustes" to R.drawable.ic_settings)
private const val overdueHint = "Abre una toma para registrar lo que ocurrió. Esta app no indica tomarla ahora."
private const val missedGuidance = "Si olvidaste una dosis o la tomaste tarde, sigue lo que te indicó tu profesional de salud o pregunta a un farmacéutico. Esta app no te indica cambiar ni reponer dosis."

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
            tabs.forEach { (name, icon) -> NavigationBarItem(selected = stack.lastOrNull { it is Tab } == Tab(name), onClick = { stack.clear(); stack.add(Tab(name)) },
                icon = { Icon(painterResource(icon), contentDescription = null) }, label = { Text(name) }) }
        }
    }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).padding(horizontal = 16.dp)) {
            if (state.session != Session.Active) Text("Mis tomas", style = MaterialTheme.typography.headlineMedium, modifier = Modifier.padding(vertical = 12.dp))
            if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            StatusBanner(state)
            if (state.session != Session.Active) {
                Login(state.busy, state.session == Session.Expired) { email, password -> model.run { model.repository.login(email, password) } }
                TextButton(enabled = !state.busy, onClick = { confirmClearLocal = true }) { Text("Cerrar sesión y borrar datos locales") }
            } else {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                    Text(state.snapshot?.refreshedAt?.let { "Última actualización: ${formatInstant(it)}" }.orEmpty(),
                        style = GraphiteTokens.Type.caregiverCaption, color = MedicationTrackerTheme.colors.textMuted, modifier = Modifier.weight(1f))
                    TextButton(enabled = !state.busy, onClick = { model.run { model.repository.sync() } }, modifier = Modifier.heightIn(min = GraphiteTokens.Size.minTouchAndroid)) { Text("Sincronizar") }
                }
                NavDisplay(backStack = stack, onBack = { if (stack.size > 1) stack.removeLastOrNull() }, modifier = Modifier.weight(1f), entryProvider = entryProvider {
                    entry<Tab> { tab -> when (tab.name) {
                        "Hoy" -> Today(model, state, now) { stack.add(Detail(it)) }
                        "Historial" -> History(state, now) { stack.add(Detail(it)) }
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

/** Cuenta registros, no tomas: una omisión también suma. Sin rachas ni metas. */
@Composable private fun Today(model: PatientViewModel, state: AppState, now: Instant, open: (String) -> Unit) {
    val snapshot = state.snapshot
    val context = LocalContext.current
    val plan = todayPlan(snapshot?.doses.orEmpty(), state.operations, now)
    var permitted by remember { mutableStateOf(model.app.reminders.permitted()) }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { permitted = model.app.reminders.permitted() }
    val colors = MedicationTrackerTheme.colors
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.md)) {
        val zone = snapshot?.doses?.firstOrNull()?.let { ZoneId.of(it.timezone) } ?: ZoneId.systemDefault()
        Text(longDate(now, zone), style = GraphiteTokens.Type.patientBody, color = colors.textMuted, modifier = Modifier.semantics { heading() })
        if (plan.total > 0) Column(Modifier.semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.sm)) {
            Text("${plan.registeredCount} de ${plan.total} registradas", style = GraphiteTokens.Type.patientLabel)
            LinearProgressIndicator({ plan.registeredCount.toFloat() / plan.total }, Modifier.fillMaxWidth(), color = colors.action, trackColor = colors.border, drawStopIndicator = {})
        }
        if (plan.review.isNotEmpty()) {
            SectionTitle("Por revisar")
            plan.review.forEach { DoseRow(it, state, now, open = open) }
        }
        plan.current?.let { NowCard(model, state, it, now, open) } ?: run {
            if (plan.total == 0) Text(when {
                snapshot?.refreshedAt != null -> "No hay tomas programadas para hoy."
                state.busy -> "Cargando tu agenda…"
                else -> "Sin agenda guardada. Conéctate y sincroniza para cargar tus tomas."
            }, style = GraphiteTokens.Type.patientBody)
            else if (plan.later.isEmpty() && plan.overdue.isEmpty()) Text("No quedan tomas por registrar hoy.", style = GraphiteTokens.Type.patientBody)
        }
        if (plan.later.isNotEmpty()) {
            SectionTitle("Más tarde")
            plan.later.forEach { DoseRow(it, state, now, open = open) }
        }
        if (plan.overdue.isNotEmpty()) {
            SectionTitle("Pasaron sin registrar")
            Text(overdueHint, color = colors.textMuted)
            plan.overdue.forEach { DoseRow(it, state, now, open = open) }
        }
        if (plan.registered.isNotEmpty()) {
            SectionTitle("Ya registradas")
            plan.registered.forEach { DoseRow(it, state, now, open = open) }
        }
        if (!permitted) {
            StatusChip(Chip("Recordatorios desactivados", R.drawable.ic_notifications_off, colors.unconfirmedFg, colors.unconfirmedBg))
            Text("Este teléfono no te avisará de tus tomas. Puedes activarlos en los ajustes de notificaciones.")
            DoseAction("Abrir ajustes de notificaciones") { context.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)) }
        }
        Spacer(Modifier.height(GraphiteTokens.Space.md))
    }
}

/** La toma que falta registrar, con las tres declaraciones a la vista. */
@Composable private fun NowCard(model: PatientViewModel, state: AppState, dose: Dose, now: Instant, open: (String) -> Unit) {
    val treatment = state.snapshot?.treatments?.find { it.id == dose.treatmentId }
    val due = Instant.parse(dose.scheduledAt) <= now
    Card(Modifier.fillMaxWidth(), shape = RoundedCornerShape(GraphiteTokens.Radius.lg), colors = CardDefaults.cardColors(containerColor = MedicationTrackerTheme.colors.surface), border = BorderStroke(1.dp, MedicationTrackerTheme.colors.border)) {
        Column(Modifier.padding(GraphiteTokens.Space.lg), verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.md)) {
            Text(if (due) "Ahora toca" else "Próxima toma", style = GraphiteTokens.Type.patientLabel, color = MedicationTrackerTheme.colors.textMuted, modifier = Modifier.semantics { heading() })
            Column(Modifier.fillMaxWidth().clickable(onClickLabel = "Abrir detalle") { open(dose.id) }, verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.xs)) {
                Text(doseTime(dose), style = GraphiteTokens.Type.patientDisplay)
                Text(treatment?.name ?: "Tratamiento", style = GraphiteTokens.Type.patientTitle)
                if (!treatment?.strength.isNullOrEmpty()) Text(treatment!!.strength, style = GraphiteTokens.Type.patientBody, color = MedicationTrackerTheme.colors.textMuted)
                Text("${quantityText(dose.quantity)} ${unitLabel(treatment?.unit)}", style = GraphiteTokens.Type.patientBody)
                if (dose.dstAdjusted) Text("Hora ajustada por el cambio de horario.", color = MedicationTrackerTheme.colors.textMuted)
                StatusChip(doseChip(dose, null, now))
            }
            DeclarationActions(model, state, dose, now)
        }
    }
}

/** Las tres declaraciones, sin penalización visual. Las dosis futuras no admiten registro, igual que en la API. */
@Composable private fun DeclarationActions(model: PatientViewModel, state: AppState, dose: Dose, now: Instant) {
    var late by remember(dose.id) { mutableStateOf(false) }
    if (Instant.parse(dose.scheduledAt) > now) {
        Text("Podrás registrarla desde las ${dose.localTime}.", style = GraphiteTokens.Type.patientLabel, color = MedicationTrackerTheme.colors.textMuted)
        return
    }
    val context = state.snapshot?.context ?: return
    val declare = { type: String, occurred: Instant? -> model.run { model.repository.record(context, dose.id, declaration(dose, type, occurred, null)) } }
    Column(verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.sm)) {
        DoseAction("Me lo tomé", prominent = true) { declare("taken", null) }
        DoseAction("Me lo tomé tarde") { late = true }
        DoseAction("No me lo tomé") { declare("skipped", null) }
    }
    if (late) LateSheet(dose, onDismiss = { late = false }) { late = false; declare("taken_late", it) }
}

/** Pide la hora efectiva. El botón muestra la hora que se guardará y nunca admite una futura. */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable private fun LateSheet(dose: Dose, onDismiss: () -> Unit, save: (Instant) -> Unit) {
    var occurred by remember { mutableStateOf(LateTime.floorToMinute(Instant.now())) }
    var manual by remember { mutableStateOf(false) }
    var date by remember { mutableStateOf("") }; var time by remember { mutableStateOf("") }
    var selectedOffset by remember(date, time) { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    val offsets = runCatching { effectiveOffsets(date, time, dose.timezone) }.getOrDefault(emptyList())
    val label = LateTime.label(occurred, dose.timezone)
    val colors = MedicationTrackerTheme.colors
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = colors.surface) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = GraphiteTokens.Space.lg), verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.md), horizontalAlignment = Alignment.CenterHorizontally) {
            Text("¿A qué hora lo tomaste?", style = GraphiteTokens.Type.patientBody, modifier = Modifier.semantics { heading() })
            Text(label, style = GraphiteTokens.Type.patientDisplay, modifier = Modifier.semantics { contentDescription = "Hora de la toma: $label" })
            Text(longDate(occurred, ZoneId.of(dose.timezone)), style = GraphiteTokens.Type.patientLabel, color = colors.textMuted)
            if (dose.timezone != ZoneId.systemDefault().id) Text("Hora de ${dose.timezone}", color = colors.textMuted)
            if (LateTime.isRepeated(occurred, dose.timezone)) Text("Esta hora ocurrió dos veces por el cambio de horario. Usa −5 min o +5 min para elegir la correcta.", color = colors.textMuted, textAlign = TextAlign.Center)
            Row(horizontalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.sm)) {
                DoseAction("−5 min", description = "Restar 5 minutos", modifier = Modifier.weight(1f)) { occurred = LateTime.stepped(occurred, -5, Instant.now()) }
                DoseAction("+5 min", description = "Sumar 5 minutos", enabled = LateTime.canAdvance(occurred, Instant.now()), modifier = Modifier.weight(1f)) { occurred = LateTime.stepped(occurred, 5, Instant.now()) }
            }
            FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.sm), verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.sm)) {
                listOf("Recién" to 0L, "Hace 30 min" to 30L, "Hace 1 hora" to 60L).forEach { (text, minutes) ->
                    OutlinedButton(onClick = { occurred = LateTime.ago(minutes, Instant.now()) }, colors = ButtonDefaults.outlinedButtonColors(contentColor = colors.text), border = BorderStroke(1.dp, colors.borderStrong),
                        contentPadding = PaddingValues(horizontal = GraphiteTokens.Space.sm), modifier = Modifier.weight(1f).heightIn(min = GraphiteTokens.Size.minTouchAndroid)) { Text(text, style = GraphiteTokens.Type.patientLabel, textAlign = TextAlign.Center) }
                }
            }
            TextButton(onClick = { manual = !manual }, modifier = Modifier.heightIn(min = GraphiteTokens.Size.minTouchAndroid)) { Text(if (manual) "Ocultar otra fecha u hora" else "Otra fecha u hora") }
            if (manual) {
                OutlinedTextField(date, { date = it; error = null }, label = { Text("Fecha (AAAA-MM-DD)") }, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(time, { time = it; error = null }, label = { Text("Hora (HH:mm)") }, modifier = Modifier.fillMaxWidth())
                if (offsets.size == 2) {
                    Text("Esta hora ocurrió dos veces por el cambio horario. Elige cuándo la tomaste.")
                    offsets.forEachIndexed { index, offset ->
                        Action("${if (selectedOffset == offset.id) "✓ " else ""}${if (index == 0) "Primera" else "Segunda"} vez · UTC${offset.id}") { selectedOffset = offset.id }
                    }
                }
                error?.let { Text(it, color = colors.dangerFg) }
                DoseAction("Usar esta fecha y hora") {
                    try {
                        val chosen = effectiveInstant(date, time, dose.timezone, selectedOffset)
                        require(!chosen.isAfter(Instant.now())) { "La hora de toma no puede estar en el futuro." }
                        occurred = chosen; manual = false
                    } catch (e: IllegalArgumentException) { error = e.message ?: "Revisa la fecha y la hora." }
                    catch (_: Exception) { error = "Usa una fecha y hora válidas." }
                }
            }
            DoseAction("Guardar con las $label", prominent = true) { save(occurred) }
            Text(missedGuidance, color = colors.textMuted)
            Spacer(Modifier.height(GraphiteTokens.Space.lg))
        }
    }
}

@Composable private fun History(state: AppState, now: Instant, open: (String) -> Unit) {
    val snapshot = state.snapshot
    val doses = snapshot?.doses.orEmpty().filter { !it.today(now) && Instant.parse(it.scheduledAt) < now }.sortedByDescending { it.scheduledAt }
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.md)) {
        SectionTitle("Historial de los últimos 7 días")
        if (doses.isEmpty()) Text(if (snapshot?.refreshedAt == null) "Sin agenda guardada. Conéctate y sincroniza para cargar tus tomas." else "No hay dosis en este período.")
        doses.forEach { DoseRow(it, state, now, showDate = true, open = open) }
        Spacer(Modifier.height(GraphiteTokens.Space.md))
    }
}

/** Fila de al menos 64 dp que abre el detalle; crece con la escala de fuente. */
@Composable private fun DoseRow(dose: Dose, state: AppState, now: Instant, showDate: Boolean = false, open: (String) -> Unit) {
    val colors = MedicationTrackerTheme.colors
    val treatment = state.snapshot?.treatments?.find { it.id == dose.treatmentId }
    Surface(onClick = { open(dose.id) }, shape = RoundedCornerShape(GraphiteTokens.Radius.md), color = colors.surface, border = BorderStroke(1.dp, colors.border), modifier = Modifier.fillMaxWidth().heightIn(min = GraphiteTokens.Size.patientAction)) {
        Row(Modifier.padding(GraphiteTokens.Space.md), horizontalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.md), verticalAlignment = Alignment.CenterVertically) {
            Text(doseTime(dose), style = GraphiteTokens.Type.patientLabel)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.xs)) {
                Text(treatment?.name ?: "Tratamiento", style = GraphiteTokens.Type.patientLabel)
                if (showDate) Text("${dose.localDate} · ${quantityText(dose.quantity)} ${unitLabel(treatment?.unit)}", color = colors.textMuted)
                StatusChip(doseChip(dose, state.operations.find { it.dose == dose.id }, now))
                if (dose.dstAdjusted) Text("Hora ajustada por el cambio de horario.", color = colors.textMuted)
            }
            Icon(painterResource(R.drawable.ic_chevron), contentDescription = null, tint = colors.textMuted)
        }
    }
}

@Composable private fun DoseDetail(model: PatientViewModel, state: AppState, id: String) {
    val snapshot = state.snapshot
    val dose = snapshot?.doses?.find { it.id == id }
    if (dose == null) { Text("Esta dosis ya no está en la agenda actual. Revisa los pendientes en Ajustes."); return }
    val treatment = snapshot.treatments.find { it.id == dose.treatmentId }
    val pending = state.operations.find { it.dose == id }
    val now = Instant.now()
    var selected by remember(id) { mutableStateOf<String?>(null) }
    var date by remember(id) { mutableStateOf("") }; var time by remember(id) { mutableStateOf("") }
    var selectedOffset by remember(id, date, time) { mutableStateOf<String?>(null) }
    val offsets = runCatching { effectiveOffsets(date, time, dose.timezone) }.getOrDefault(emptyList())
    var reason by remember(id) { mutableStateOf("") }; var error by remember(id) { mutableStateOf<String?>(null) }
    var confirmation by remember(id) { mutableStateOf<Command?>(null) }
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.md)) {
        Text(treatment?.name ?: "Tratamiento", style = MaterialTheme.typography.headlineSmall, modifier = Modifier.semantics { heading() })
        Text("${quantityText(dose.quantity)} ${unitLabel(treatment?.unit)} · ${treatment?.strength.orEmpty()}")
        Text("${dose.localDate} ${dose.localTime} · ${dose.timezone}")
        StatusChip(doseChip(dose, pending, now))
        if (!treatment?.instructions.isNullOrEmpty()) Text(treatment!!.instructions)
        snapshot.inventory.find { it.treatmentId == dose.treatmentId }?.let {
            Text("Stock confirmado en la última actualización: ${quantityText(it.balance)} ${unitLabel(it.unit)}")
            if (state.operations.isNotEmpty()) {
                val estimate = estimatedBalance(snapshot, state.operations, dose.treatmentId)
                Text(if (estimate == null) "Stock estimado no disponible hasta revisar los pendientes." else "Stock estimado con pendientes: ${quantityText(estimate)} ${unitLabel(it.unit)}. Aún no confirmado por el servidor.")
            }
        }
        if (pending != null) {
            Text("Tu declaración está guardada. El stock confirmado no incluye cambios sin sincronizar.")
        } else if (!dose.declared()) {
            DeclarationActions(model, state, dose, now)
        } else {
            SectionTitle("Corregir registro")
            listOf("taken" to "Me lo tomé", "taken_late" to "Me lo tomé tarde", "skipped" to "No me lo tomé").forEach { (type, label) ->
                DoseAction(if (selected == type) "✓ $label" else label) { selected = type; error = null }
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
            OutlinedTextField(reason, { reason = it }, label = { Text("Motivo de la corrección") }, modifier = Modifier.fillMaxWidth())
            error?.let { Text(it, color = MedicationTrackerTheme.colors.dangerFg) }
            if (selected != null) Action("Revisar corrección") {
                try {
                    val occurred = if (selected == "taken_late") {
                        effectiveInstant(date, time, dose.timezone, selectedOffset)
                    } else null
                    confirmation = declaration(dose, selected!!, occurred, reason)
                } catch (e: IllegalArgumentException) { error = e.message ?: "Revisa la fecha, hora y motivo." }
                catch (_: Exception) { error = "Usa una fecha y hora válidas." }
            }
        }
        Text(missedGuidance)
        Spacer(Modifier.height(GraphiteTokens.Space.md))
    }
    confirmation?.let { command ->
        AlertDialog(onDismissRequest = { confirmation = null }, title = { Text("Confirmar corrección") },
            text = { Text("${declarationLabel(command.eventType)}${command.occurredAt?.let { " · ${formatInstant(it)}" }.orEmpty()}. Se guardará para sincronizar. La corrección conserva el historial.") },
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
        SectionTitle("Recordatorios")
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
        SectionTitle("Avisos remotos del cuidador")
        Text(pushDiagnostic)
        SectionTitle("Registros pendientes")
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
                StatusChip(operationChip(op.status))
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
    SectionTitle("Acceso de cuidadores")
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
    error?.let { Text(it, color = MedicationTrackerTheme.colors.dangerFg) }
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
    Button(onClick = action, enabled = enabled, modifier = Modifier.fillMaxWidth().heightIn(min = GraphiteTokens.Size.minTouchAndroid)) { Text(label) }
}
@Composable private fun SectionTitle(text: String) {
    Text(text, style = GraphiteTokens.Type.patientLabel, modifier = Modifier.semantics { heading() })
}

/** Las tres declaraciones comparten alto y forma; sólo «Me lo tomé» va relleno. */
@Composable private fun DoseAction(label: String, modifier: Modifier = Modifier.fillMaxWidth(), prominent: Boolean = false, enabled: Boolean = true, description: String? = null, action: () -> Unit) {
    val shape = RoundedCornerShape(GraphiteTokens.Radius.lg)
    val sized = modifier.heightIn(min = GraphiteTokens.Size.patientAction).let { base -> description?.let { text -> base.semantics { contentDescription = text } } ?: base }
    if (prominent) Button(onClick = action, enabled = enabled, shape = shape, modifier = sized) { Text(label, style = GraphiteTokens.Type.patientLabel, textAlign = TextAlign.Center) }
    else OutlinedButton(onClick = action, enabled = enabled, shape = shape, colors = ButtonDefaults.outlinedButtonColors(contentColor = MedicationTrackerTheme.colors.text), border = BorderStroke(GraphiteTokens.Size.borderWidth, if (enabled) MedicationTrackerTheme.colors.action else MedicationTrackerTheme.colors.borderStrong), modifier = sized) {
        Text(label, style = GraphiteTokens.Type.patientLabel, textAlign = TextAlign.Center)
    }
}

private data class Chip(val text: String, val icon: Int, val foreground: Color, val background: Color)

/** Chip de estado: icono y texto, nunca sólo color. */
@Composable private fun StatusChip(chip: Chip) {
    Surface(color = chip.background, contentColor = chip.foreground, shape = RoundedCornerShape(GraphiteTokens.Radius.lg)) {
        Row(Modifier.padding(horizontal = GraphiteTokens.Space.md, vertical = GraphiteTokens.Space.xs), horizontalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.xs), verticalAlignment = Alignment.CenterVertically) {
            Icon(painterResource(chip.icon), contentDescription = null, modifier = Modifier.size(20.dp))
            Text(chip.text, style = GraphiteTokens.Type.patientLabel)
        }
    }
}

@Composable private fun doseChip(dose: Dose, operation: PendingOperation?, now: Instant): Chip {
    if (operation != null) return operationChip(operation.status)
    val colors = MedicationTrackerTheme.colors
    val label = stateLabel(dose, now)
    return when (dose.state) {
        "taken" -> Chip(label, R.drawable.ic_taken, colors.takenFg, colors.takenBg)
        "taken_late" -> Chip(label, R.drawable.ic_taken_late, colors.takenLateFg, colors.takenLateBg)
        "skipped" -> Chip(label, R.drawable.ic_skipped, colors.skippedFg, colors.skippedBg)
        else -> if (Instant.parse(dose.scheduledAt) <= now) Chip(label, R.drawable.ic_unconfirmed, colors.unconfirmedFg, colors.unconfirmedBg)
        else Chip(label, R.drawable.ic_scheduled, colors.scheduledFg, colors.scheduledBg)
    }
}

@Composable private fun operationChip(status: String): Chip {
    val colors = MedicationTrackerTheme.colors
    return if (status == "pending") Chip(operationLabel(status), R.drawable.ic_sync, colors.syncFg, colors.syncBg)
    else Chip(operationLabel(status), R.drawable.ic_warning, colors.dangerFg, colors.dangerBg)
}

/** Sin conexión en lenguaje simple. El rojo sólo marca lo que el servidor rechazó. */
@Composable private fun StatusBanner(state: AppState) {
    val colors = MedicationTrackerTheme.colors
    val text = state.message
    if (!state.offline && text == null) return
    val danger = text != null && (state.rejected || state.session != Session.Active)
    val foreground = if (danger) colors.dangerFg else colors.syncFg
    Surface(color = if (danger) colors.dangerBg else colors.syncBg, contentColor = foreground, shape = RoundedCornerShape(GraphiteTokens.Radius.md), modifier = Modifier.fillMaxWidth().padding(vertical = GraphiteTokens.Space.sm)) {
        Row(Modifier.padding(GraphiteTokens.Space.md).semantics(mergeDescendants = true) {}, horizontalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.sm)) {
            Icon(painterResource(if (state.offline) R.drawable.ic_offline else R.drawable.ic_warning), contentDescription = null)
            Column {
                if (state.offline) {
                    Text("Sin conexión", style = GraphiteTokens.Type.patientLabel)
                    Text(if (state.session == Session.Active) "Tus registros quedan guardados en este teléfono. Se enviarán cuando vuelva la conexión y sincronices." else "Revisa la conexión e intenta de nuevo.")
                } else Text(text.orEmpty())
            }
        }
    }
}

private fun formatInstant(value: String): String = runCatching { Instant.parse(value).atZone(ZoneId.systemDefault()).format(java.time.format.DateTimeFormatter.ofPattern("dd-MM-yyyy HH:mm")) }.getOrDefault(value)
private fun declarationLabel(value: String) = when (value) { "taken" -> "Me lo tomé"; "taken_late" -> "Me lo tomé tarde"; else -> "No me lo tomé" }
private fun operationLabel(value: String) = when (value) { "conflict" -> "Necesita revisión: cambió en el servidor"; "rejected" -> "Necesita revisión: datos rechazados"; "denied" -> "Necesita revisión: acceso denegado"; else -> "Guardada, falta enviar" }
private fun doseTime(dose: Dose) = if (dose.timezone == ZoneId.systemDefault().id) dose.localTime else "${dose.localTime} (${dose.timezone})"
private fun unitLabel(value: String?) = when (value) { "tablet" -> "comprimidos"; "capsule" -> "cápsulas"; "dose" -> "dosis"; "ml" -> "ml"; else -> "unidades" }
private fun scopeLabel(value: String) = when (value) { "read" -> "Consultar información"; "doses" -> "Registrar y corregir tomas"; "inventory" -> "Administrar inventario"; "treatments" -> "Administrar tratamientos"; else -> value }
