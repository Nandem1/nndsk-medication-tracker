package cl.nndsk.medication.ui.caregiver

import androidx.compose.material3.*
import androidx.compose.runtime.*
import cl.nndsk.medication.PatientViewModel
import cl.nndsk.medication.R
import cl.nndsk.medication.core.*
import cl.nndsk.medication.ui.components.*
import cl.nndsk.medication.ui.theme.MedicationTrackerTheme
import java.util.UUID

internal fun balanceLabel(stock: Inventory) = if (stock.pool?.status == "active") "Saldo común confirmado" else "Saldo confirmado"
internal fun movementLine(item: Movement): String {
    val date = if (item.reason == "shared_activity") sharedActivityDate(item.createdAt) else formatInstant(item.createdAt)
    return listOfNotNull(quantityText(item.quantity), movementLabel(item.reason), item.patientName, date).joinToString(" · ")
}

/** Sólo el propio paciente decide. Un cuidador nunca ve esta tarjeta por otra persona. */
@Composable internal fun PendingPoolCard(model: PatientViewModel, pool: PendingPool, disabled: Boolean) {
    val accept = remember(pool.id) { UUID.randomUUID().toString() }
    val decline = remember(pool.id) { UUID.randomUUID().toString() }
    SectionCard("Inventario compartido") {
        Text(poolProposal(pool))
        DoseAction("Aceptar", enabled = !disabled) { model.run { model.repository.decidePool(pool.id, true, accept) } }
        DoseAction("Ahora no", enabled = !disabled) { model.run { model.repository.decidePool(pool.id, false, decline) } }
    }
}

@Composable internal fun SharedInventory(model: PatientViewModel, stock: Inventory, canEdit: Boolean, disabled: Boolean, propose: Boolean = true) {
    val colors = MedicationTrackerTheme.colors
    val pool = stock.pool
    var leaving by remember(stock.accountId) { mutableStateOf(false) }
    var candidates by remember(stock.accountId) { mutableStateOf<List<PoolCandidate>?>(null) }
    var error by remember(stock.accountId) { mutableStateOf<String?>(null) }
    val leave = remember(pool?.id, stock.accountId) { UUID.randomUUID().toString() }
    val proposal = remember(stock.accountId) { UUID.randomUUID().toString() }
    if (pool?.status == "active") {
        StatusChip(Chip("Inventario compartido con ${poolOthers(pool)}", R.drawable.ic_shared, colors.scheduledFg, colors.scheduledBg))
        Note("El saldo es común: suma lo que registra cada persona. Si recién empezaron a compartir, conviene hacer un conteo físico.")
        if (canEdit) DoseAction("Dejar de compartir", enabled = !disabled) { leaving = true }
        if (disabled && canEdit) Note("Conéctate para dejar de compartir.")
    } else if (pool != null) {
        StatusChip(Chip("Esperando a ${poolOthers(pool, "pending")}", R.drawable.ic_shared, colors.scheduledFg, colors.scheduledBg))
        Note("Cada paciente decide por sí mismo. Mientras tanto, los saldos siguen separados.")
        if (canEdit) DoseAction("Retirar esta cuenta de la propuesta", enabled = !disabled) { model.run { model.repository.leavePool(pool.id, stock.accountId, leave) } }
    } else if (propose && canEdit) {
        DoseAction("Compartir con…", enabled = !disabled) {
            model.run {
                try { candidates = model.repository.poolCandidates(stock.accountId); error = null }
                catch (_: Exception) { error = "No se pudieron cargar las personas con este medicamento." }
            }
        }
        error?.let { Note(it) }
    }
    if (leaving && pool != null) AlertDialog(onDismissRequest = { leaving = false }, title = { Text("Dejar de compartir") },
        text = { Text("El saldo se queda con ${poolOthers(pool)}. Esta cuenta quedará en 0: después registra el stock que tengas.") },
        confirmButton = { TextButton(onClick = { leaving = false; model.run { model.repository.leavePool(pool.id, stock.accountId, leave) } }) { Text("Confirmar") } },
        dismissButton = { TextButton(onClick = { leaving = false }) { Text("Volver") } })
    candidates?.let { rows -> AlertDialog(onDismissRequest = { candidates = null }, title = { Text("Compartir con…") },
        text = {
            if (rows.isEmpty()) Text("No hay otra persona con el mismo medicamento, concentración, forma y unidad.")
            else androidx.compose.foundation.layout.Column {
                Note("Si usan físicamente la misma caja, pueden compartir el saldo. Cada paciente debe aceptar.")
                rows.forEach { candidate ->
                    DoseAction(candidate.name ?: "Paciente sin nombre") {
                        candidates = null
                        model.run { model.repository.proposePool(listOf(stock.accountId, candidate.accountId), proposal) }
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = { candidates = null }) { Text("Cerrar") } }) }
}
