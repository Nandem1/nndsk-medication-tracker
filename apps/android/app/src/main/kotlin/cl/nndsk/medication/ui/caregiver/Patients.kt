package cl.nndsk.medication.ui.caregiver

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import cl.nndsk.medication.ui.theme.MedicationTrackerTheme
import cl.nndsk.medication.PatientViewModel
import cl.nndsk.medication.R
import cl.nndsk.medication.core.*
import cl.nndsk.medication.ui.components.*
import cl.nndsk.medication.ui.account.ProfileEditor
import cl.nndsk.medication.ui.today.Today
import cl.nndsk.medication.ui.today.History
import cl.nndsk.medication.ui.theme.GraphiteTokens
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.util.UUID

@Composable internal fun Patients(model: PatientViewModel, state: AppState, open: (String) -> Unit) {
    var invite by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.md)) {
        if (state.patients.isEmpty()) SectionCard("Aún no sigues a ningún paciente") { Note("Invita a una persona. Su agenda aparecerá aquí cuando autorice el acceso.") }
        state.patients.values.forEach { snapshot -> PatientCard(snapshot, state) { open(snapshot.context.patientId) } }
        DoseAction("Invitar a alguien", prominent = true) { invite = true }
        if (state.patients.isNotEmpty()) Note("Los registros son declaraciones. No demuestran que el medicamento se haya tomado.")
        Spacer(Modifier.height(GraphiteTokens.Space.sm))
    }
    if (invite) InviteSheet(model) { invite = false }
}

/** Toda la tarjeta abre al paciente. Cada aviso aparece sólo si hay algo que revisar. */
@Composable private fun PatientCard(snapshot: Snapshot, state: AppState, open: () -> Unit) {
    val colors = MedicationTrackerTheme.colors
    val name = patientName(snapshot.access)
    val low = snapshot.inventory.count { it.lowStock }
    val review = state.operations.any { it.patient == snapshot.context.patientId && it.status != "pending" }
    Surface(color = colors.surface, shape = RoundedCornerShape(GraphiteTokens.Radius.lg), border = BorderStroke(1.dp, colors.border), modifier = Modifier.fillMaxWidth()) {
        Row(Modifier.clickable(onClickLabel = "Ver a $name", role = Role.Button, onClick = open).padding(GraphiteTokens.Space.lg), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.sm)) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.sm)) {
                Text(name, style = GraphiteTokens.Type.patientTitle, modifier = Modifier.semantics { heading() })
                snapshot.report?.let { report ->
                    val zone = runCatching { ZoneId.of(snapshot.access?.timezone.orEmpty()) }.getOrDefault(ZoneId.systemDefault())
                    Note(reportPeriodLabel(report.from, LocalDate.now(zone)))
                    Text("${report.summary.confirmed} de ${report.summary.evaluable} registradas", style = GraphiteTokens.Type.patientLabel)
                    if (report.summary.unconfirmed > 0) StatusChip(Chip("${report.summary.unconfirmed} sin confirmar", R.drawable.ic_unconfirmed, colors.unconfirmedFg, colors.unconfirmedBg))
                }
                if (low > 0) StatusChip(Chip(if (low == 1) "1 reposición por revisar" else "$low reposiciones por revisar", R.drawable.ic_inventory, colors.scheduledFg, colors.scheduledBg))
                if (review) StatusChip(Chip("Registros por revisar", R.drawable.ic_warning, colors.dangerFg, colors.dangerBg))
                if (state.offline) snapshot.refreshedAt?.let { Note("Datos guardados de: ${formatInstant(it)}") }
            }
            Icon(painterResource(R.drawable.ic_chevron), contentDescription = null, tint = colors.textMuted)
        }
    }
}

/** Acciones sobre el vínculo, separadas de la navegación entre secciones. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable internal fun PatientMenu(model: PatientViewModel, state: AppState, id: String) {
    val snapshot = state.patients[id] ?: return
    var open by remember { mutableStateOf(false) }
    var leave by remember { mutableStateOf(false) }
    var rename by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { open = true }) { Icon(painterResource(R.drawable.ic_more), contentDescription = "Opciones del paciente") }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            if (state.screen(id).permits("treatments")) DropdownMenuItem(text = { Text("Cambiar nombre") }, onClick = { open = false; rename = true })
            DropdownMenuItem(text = { Text("Dejar de seguir") }, onClick = { open = false; leave = true })
        }
    }
    if (rename) ModalBottomSheet(onDismissRequest = { rename = false }) {
        Column(Modifier.fillMaxWidth().padding(GraphiteTokens.Space.lg), verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.md)) {
            ProfileEditor(model, snapshot, state.busy, "Nombre del paciente")
            SecondaryAction("Cerrar") { rename = false }
        }
    }
    if (leave) AlertDialog(onDismissRequest = { leave = false }, title = { Text("Dejar de seguir a ${patientName(snapshot.access)}") },
        text = { Text("Perderás el acceso a su información. Para volver necesitarás una nueva autorización.") },
        confirmButton = { TextButton(onClick = { leave = false; snapshot.access?.linkId?.let { model.run { model.repository.revoke(it) } } }) { Text("Dejar de seguir") } },
        dismissButton = { TextButton(onClick = { leave = false }) { Text("Volver") } })
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable internal fun Patient(model: PatientViewModel, state: AppState, id: String, now: Instant, open: (String) -> Unit) {
    if (state.patients[id] == null) { Text("Ya no tienes acceso a este paciente."); return }
    val screen = state.screen(id)
    val sections = listOf("Hoy", "Historial", "Inventario")
    var section by remember(id) { mutableStateOf(sections.first()) }
    val colors = MedicationTrackerTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.sm)) {
        if (state.patients[id]?.access?.scopes == listOf("read")) Note("Tu acceso permite sólo mirar")
        SecondaryTabRow(selectedTabIndex = sections.indexOf(section), containerColor = colors.bg, contentColor = colors.text) {
            sections.forEach { label -> Tab(selected = section == label, onClick = { section = label }, selectedContentColor = colors.text, unselectedContentColor = colors.textMuted, text = { Text(label, style = GraphiteTokens.Type.caregiverBody) }) }
        }
        when (section) {
            "Hoy" -> Today(model, screen, now, open = open)
            "Historial" -> History(screen, now, open)
            else -> InventoryScreen(model, screen)
        }
    }
}

@Composable private fun InventoryScreen(model: PatientViewModel, screen: PatientScreen) {
    val snapshot = screen.snapshot ?: return
    var edit by remember { mutableStateOf<Pair<Inventory, Boolean>?>(null) }
    var ledgers by remember { mutableStateOf<Map<String, List<Movement>>>(emptyMap()) }
    var error by remember { mutableStateOf<String?>(null) }
    val colors = MedicationTrackerTheme.colors
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.md)) {
        if (snapshot.inventory.isEmpty()) Note("No hay inventario para mostrar.")
        snapshot.inventory.forEach { stock ->
            SectionCard(snapshot.treatments.find { it.id == stock.treatmentId }?.name ?: "Tratamiento") {
                Column(Modifier.semantics(mergeDescendants = true) {}) {
                    Note(balanceLabel(stock))
                    Text("${quantityText(stock.balance)} ${unitLabel(stock.unit)}", style = GraphiteTokens.Type.patientTitle)
                }
                if (screen.operations.isNotEmpty()) estimatedBalance(snapshot, screen.operations, stock.treatmentId)?.let {
                    val border = colors.syncFg
                    Box(Modifier.fillMaxWidth().drawBehind {
                        drawRoundRect(border, style = Stroke(1.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(6.dp.toPx(), 4.dp.toPx()))))
                    }.padding(GraphiteTokens.Space.sm)) {
                        InfoRow("Estimado con registros sin enviar", "${quantityText(it)} ${unitLabel(stock.unit)}")
                    }
                }
                InfoRow("Cobertura", coverageLabel(stock))
                if (stock.lowStock) StatusChip(Chip("Reposición por revisar", R.drawable.ic_inventory, colors.scheduledFg, colors.scheduledBg))
                stock.replenishOn?.let { InfoRow("Fecha de revisión", sharedActivityDate(it)) }
                stock.firstUncoveredAt?.let { InfoRow("Primera toma sin cobertura", formatInstant(it)) }
                if (screen.offline) snapshot.refreshedAt?.let { Note("Datos guardados de: ${formatInstant(it)}") }
                SharedInventory(model, stock, screen.permits("inventory"), screen.offline || screen.busy)
                if (screen.permits("inventory")) {
                    SecondaryAction("Registrar reposición", enabled = !screen.offline && !screen.busy) { edit = stock to false }
                    SecondaryAction("Conteo físico", enabled = !screen.offline && !screen.busy) { edit = stock to true }
                    if (screen.offline) Note("Conéctate para registrar una reposición o un conteo físico.")
                }
                val rows = ledgers[stock.accountId]
                TextButton(enabled = rows != null || (!screen.offline && !screen.busy), modifier = Modifier.heightIn(min = GraphiteTokens.Size.minTouchAndroid), onClick = {
                    if (rows != null) ledgers = ledgers - stock.accountId
                    else model.run { try { ledgers = ledgers + (stock.accountId to model.repository.movements(snapshot.context.patientId, stock.accountId)); error = null }
                    catch (_: Exception) { error = "No se pudieron cargar los movimientos." } }
                }) { Text(if (rows == null) "Ver movimientos" else "Ocultar movimientos") }
                rows?.let { list ->
                    if (list.isEmpty()) Note("Sin movimientos.")
                    list.sortedByDescending { it.createdAt }.forEach { MovementRow(it, stock.unit) }
                }
            }
        }
        error?.let { ErrorText(it) }
        Spacer(Modifier.height(GraphiteTokens.Space.sm))
    }
    edit?.let { (stock, count) -> InventorySheet(model, snapshot.context.patientId, stock, count, screen.busy, screen.offline) { edit = null } }
}

@Composable private fun MovementRow(item: Movement, unit: String) {
    Column(Modifier.fillMaxWidth().semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.xxs)) {
        HorizontalDivider(color = MedicationTrackerTheme.colors.border)
        Text(movementLabel(item.reason), style = GraphiteTokens.Type.caregiverBody.copy(fontWeight = FontWeight.SemiBold))
        Text("${quantityText(item.quantity)} ${unitLabel(unit)}", style = GraphiteTokens.Type.caregiverBody)
        Note(listOfNotNull(item.patientName, movementDate(item)).joinToString(" · "))
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable private fun InventorySheet(model: PatientViewModel, patientId: String, stock: Inventory, count: Boolean, busy: Boolean, offline: Boolean, dismiss: () -> Unit) {
    var quantity by remember { mutableStateOf("") }
    var reason by remember { mutableStateOf("") }
    var failure by remember { mutableStateOf<String?>(null) }
    val operation = remember(quantity, reason) { UUID.randomUUID().toString() }
    val normalized = normalizedQuantity(quantity)
    val valid = normalized != null && (count || normalized.toBigDecimal().signum() == 1)
    ModalBottomSheet(onDismissRequest = dismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(GraphiteTokens.Space.lg), verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.md)) {
            Text(if (count) "Conteo físico" else "Registrar reposición", style = GraphiteTokens.Type.patientTitle)
            InfoRow(balanceLabel(stock), "${quantityText(stock.balance)} ${unitLabel(stock.unit)}")
            OutlinedTextField(quantity, { quantity = it }, label = { Text(if (count) "Cantidad contada" else "Cantidad recibida") }, singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal), modifier = Modifier.fillMaxWidth())
            if (count) OutlinedTextField(reason, { reason = it }, label = { Text("Motivo del ajuste") }, modifier = Modifier.fillMaxWidth())
            Note(if (offline) "Conéctate y sincroniza para guardar. El formulario conserva la operación para reintentar." else "Se guardará en el historial. Requiere conexión.")
            failure?.let { ErrorText(it) }
            DoseAction("Guardar", prominent = true, enabled = valid && !busy && !offline && (!count || reason.isNotBlank())) { model.run {
                model.repository.inventory(patientId, stock.accountId, normalized.orEmpty(), count, reason, operation, stock.balance)
                val result = model.repository.state.value
                // El aviso general queda detrás de la hoja: el rechazo se muestra aquí.
                if (result.message == null && !result.offline) dismiss() else failure = result.message ?: "No hay conexión. Conéctate e inténtalo de nuevo."
            } }
        }
    }
}
