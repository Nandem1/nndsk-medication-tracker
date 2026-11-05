package cl.nndsk.medication.ui.caregiver

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp
import cl.nndsk.medication.ui.theme.MedicationTrackerTheme
import cl.nndsk.medication.PatientViewModel
import cl.nndsk.medication.core.*
import cl.nndsk.medication.ui.components.*
import cl.nndsk.medication.ui.account.ProfileEditor
import cl.nndsk.medication.ui.today.Today
import cl.nndsk.medication.ui.today.History
import cl.nndsk.medication.ui.theme.GraphiteTokens
import java.time.Instant
import java.util.UUID

@Composable internal fun Patients(model: PatientViewModel, state: AppState, open: (String) -> Unit) {
    var invite by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.md)) {
        if (state.patients.isEmpty()) SectionCard("Aún no sigues a ningún paciente") { Note("Invita a una persona. Su agenda aparecerá aquí cuando autorice el acceso.") }
        state.patients.values.forEach { snapshot ->
            SectionCard(patientName(snapshot.access)) {
                Summary(snapshot, state.offline)
                if (snapshot.inventory.any { it.lowStock }) Note("${snapshot.inventory.count { it.lowStock }} reposiciones por revisar")
                if (state.operations.any { it.patient == snapshot.context.patientId && it.status != "pending" }) Note("Hay registros por revisar")
                DoseAction("Ver paciente", description = "Ver a ${patientName(snapshot.access)}") { open(snapshot.context.patientId) }
            }
        }
        DoseAction("Invitar paciente", prominent = true) { invite = true }
    }
    if (invite) InviteSheet(model) { invite = false }
}

@Composable private fun Summary(snapshot: Snapshot, offline: Boolean) {
    snapshot.report?.let { report ->
        Text("${report.summary.confirmed} de ${report.summary.evaluable} dosis evaluables declaradas")
        Text("${report.summary.unconfirmed} sin confirmar")
        Note("Período: ${report.from} a ${report.to} (fin excluido). Registros autodeclarados.")
    }
    snapshot.refreshedAt?.let { Note((if (offline) "Datos guardados de: " else "Datos actualizados: ") + formatInstant(it)) }
}

@Composable internal fun Patient(model: PatientViewModel, state: AppState, id: String, now: Instant, open: (String) -> Unit) {
    val snapshot = state.patients[id] ?: run { Text("Ya no tienes acceso a este paciente."); return }
    val screen = state.screen(id)
    var section by remember(id) { mutableStateOf("Hoy") }
    var leave by remember { mutableStateOf(false) }
    var rename by remember { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.sm)) {
        Text(patientName(snapshot.access), style = GraphiteTokens.Type.patientTitle)
        if (snapshot.access?.scopes == listOf("read")) Note("Tu acceso permite sólo mirar")
        Row {
            listOf("Hoy", "Historial", "Inventario").forEach { label -> TextButton(onClick = { section = label }) { Text(label) } }
        }
        Row {
            if (screen.permits("treatments")) TextButton(onClick = { rename = !rename }) { Text("Cambiar nombre") }
            TextButton(onClick = { leave = true }) { Text("Dejar de seguir") }
        }
        if (rename) ProfileEditor(model, snapshot, state.busy, "Nombre del paciente")
        when (section) {
            "Hoy" -> Today(model, screen, now, open)
            "Historial" -> History(screen, now, open)
            else -> InventoryScreen(model, screen)
        }
    }
    if (leave) AlertDialog(onDismissRequest = { leave = false }, title = { Text("Dejar de seguir a ${patientName(snapshot.access)}") },
        text = { Text("Perderás el acceso a su información. Para volver necesitarás una nueva autorización.") },
        confirmButton = { TextButton(onClick = { leave = false; snapshot.access?.linkId?.let { model.run { model.repository.revoke(it) } } }) { Text("Dejar de seguir") } },
        dismissButton = { TextButton(onClick = { leave = false }) { Text("Volver") } })
}

@Composable private fun InventoryScreen(model: PatientViewModel, screen: PatientScreen) {
    val snapshot = screen.snapshot ?: return
    var edit by remember { mutableStateOf<Pair<Inventory, Boolean>?>(null) }
    var ledger by remember { mutableStateOf<List<Movement>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.md)) {
        if (snapshot.inventory.isEmpty()) Note("No hay inventario para mostrar.")
        snapshot.inventory.forEach { stock ->
            SectionCard(snapshot.treatments.find { it.id == stock.treatmentId }?.name ?: "Tratamiento") {
                InfoRow(balanceLabel(stock), "${quantityText(stock.balance)} ${unitLabel(stock.unit)}")
                SharedInventory(model, stock, screen.permits("inventory"), screen.offline || screen.busy)
                if (screen.operations.isNotEmpty()) estimatedBalance(snapshot, screen.operations, stock.treatmentId)?.let {
                    val border = MedicationTrackerTheme.colors.syncFg
                    Box(Modifier.fillMaxWidth().drawBehind {
                        drawRoundRect(border, style = Stroke(1.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(6.dp.toPx(), 4.dp.toPx()))))
                    }.padding(GraphiteTokens.Space.sm)) {
                        InfoRow("Estimado con registros sin enviar", "${quantityText(it)} ${unitLabel(stock.unit)}")
                    }
                }
                InfoRow("Cobertura", coverageLabel(stock))
                snapshot.refreshedAt?.let { InfoRow("Fecha de revisión", formatInstant(it)) }
                stock.firstUncoveredAt?.let { InfoRow("Primera toma sin cobertura", formatInstant(it)) }
                stock.replenishOn?.let { InfoRow("Reponer antes de", it) }
                DoseAction("Ver movimientos", enabled = !screen.offline && !screen.busy) {
                    model.run { try { ledger = model.repository.movements(snapshot.context.patientId, stock.accountId); error = null }
                    catch (_: Exception) { error = "No se pudieron cargar los movimientos." } }
                }
                if (screen.permits("inventory")) {
                    DoseAction("Registrar reposición", enabled = !screen.offline && !screen.busy) { edit = stock to false }
                    DoseAction("Conteo físico", enabled = !screen.offline && !screen.busy) { edit = stock to true }
                    if (screen.offline) Note("Conéctate para registrar una reposición o un conteo físico.")
                }
            }
        }
        error?.let { Note(it) }
    }
    edit?.let { (stock, count) -> InventorySheet(model, snapshot.context.patientId, stock, count, screen.busy, screen.offline) { edit = null } }
    ledger?.let { rows -> AlertDialog(onDismissRequest = { ledger = null }, title = { Text("Movimientos") },
        text = { Column(Modifier.verticalScroll(rememberScrollState())) { if (rows.isEmpty()) Text("Sin movimientos."); rows.forEach { Text(movementLine(it)) } } },
        confirmButton = { TextButton(onClick = { ledger = null }) { Text("Cerrar") } }) }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable private fun InventorySheet(model: PatientViewModel, patientId: String, stock: Inventory, count: Boolean, busy: Boolean, offline: Boolean, dismiss: () -> Unit) {
    var quantity by remember { mutableStateOf("") }
    var reason by remember { mutableStateOf("") }
    val operation = remember(quantity, reason) { UUID.randomUUID().toString() }
    val valid = Regex("[0-9]{1,9}(\\.[0-9]{1,3})?").matches(quantity) && (count || quantity.toBigDecimalOrNull()?.signum() == 1)
    ModalBottomSheet(onDismissRequest = dismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(GraphiteTokens.Space.lg), verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.md)) {
            Text(if (count) "Conteo físico" else "Registrar reposición", style = GraphiteTokens.Type.patientTitle)
            InfoRow("Saldo confirmado", quantityText(stock.balance))
            OutlinedTextField(quantity, { quantity = it }, label = { Text(if (count) "Cantidad contada" else "Cantidad recibida") }, singleLine = true)
            if (count) OutlinedTextField(reason, { reason = it }, label = { Text("Motivo del ajuste") })
            Note(if (offline) "Conéctate y sincroniza para guardar. El formulario conserva la operación para reintentar." else "Se guardará en el historial. Requiere conexión.")
            DoseAction("Guardar", prominent = true, enabled = valid && !busy && !offline && (!count || reason.isNotBlank())) { model.run {
                model.repository.inventory(patientId, stock.accountId, quantity, count, reason, operation, stock.balance)
                if (model.repository.state.value.message == null && !model.repository.state.value.offline) dismiss()
            } }
        }
    }
}
