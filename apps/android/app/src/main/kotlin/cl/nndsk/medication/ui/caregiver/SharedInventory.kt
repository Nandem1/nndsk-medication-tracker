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
/** La actividad ajena no trae hora: el servidor sólo entrega su fecha. */
internal fun movementDate(item: Movement) = if (item.reason == "shared_activity") sharedActivityDate(item.createdAt) else formatInstant(item.createdAt)

@Composable internal fun SharedInventory(model: PatientViewModel, stock: Inventory, canEdit: Boolean, disabled: Boolean, propose: Boolean = true) {
    val colors = MedicationTrackerTheme.colors
    val pool = stock.pool
    var leaving by remember(stock.accountId) { mutableStateOf(false) }
    var candidates by remember(stock.accountId) { mutableStateOf<List<PoolCandidate>?>(null) }
    var partner by remember(stock.accountId) { mutableStateOf<PoolCandidate?>(null) }
    var error by remember(stock.accountId) { mutableStateOf<String?>(null) }
    val leave = remember(pool?.id, stock.accountId) { UUID.randomUUID().toString() }
    if (pool != null) {
        StatusChip(Chip("Misma caja que ${poolOthers(pool)}", R.drawable.ic_shared, colors.scheduledFg, colors.scheduledBg))
        Note("El saldo es común: suma lo que registra cada persona.")
        if (canEdit) SecondaryAction("Dejar de compartir", enabled = !disabled) { leaving = true }
        if (disabled && canEdit) Note("Conéctate para dejar de compartir.")
    } else if (propose && canEdit) {
        SecondaryAction("¿Usan la misma caja?", enabled = !disabled) {
            model.run {
                try { candidates = model.repository.poolCandidates(stock.accountId); error = null }
                catch (_: Exception) { error = "No se pudieron cargar las personas con este medicamento." }
            }
        }
        error?.let { ErrorText(it) }
    }
    if (leaving && pool != null) AlertDialog(onDismissRequest = { leaving = false }, title = { Text("Dejar de compartir") },
        text = { Text("El saldo se queda con ${poolOthers(pool)}. Esta cuenta quedará en 0: después registra el stock que tengas.") },
        confirmButton = { TextButton(onClick = { leaving = false; model.run { model.repository.leavePool(pool.id, stock.accountId, leave) } }) { Text("Confirmar") } },
        dismissButton = { TextButton(onClick = { leaving = false }) { Text("Volver") } })
    candidates?.let { rows -> AlertDialog(onDismissRequest = { candidates = null }, title = { Text("¿Con quién comparten la caja?") },
        text = {
            if (rows.isEmpty()) Text("No hay otra persona con el mismo medicamento, concentración, forma y unidad.")
            else androidx.compose.foundation.layout.Column {
                Note("Si usan físicamente la misma caja, el saldo será uno solo.")
                rows.forEach { candidate ->
                    SecondaryAction("Misma caja que ${candidate.name ?: "Paciente sin nombre"}") { candidates = null; partner = candidate }
                }
            }
        },
        confirmButton = { TextButton(onClick = { candidates = null }) { Text("Cerrar") } }) }
    partner?.let { candidate -> CountSharedBox(model, stock, candidate) { partner = null } }
}

/** Sumar dos saldos de una misma caja la contaría dos veces: el saldo común parte de lo contado. */
@Composable private fun CountSharedBox(model: PatientViewModel, stock: Inventory, partner: PoolCandidate, dismiss: () -> Unit) {
    var counted by remember { mutableStateOf("") }
    val operation = remember(counted) { UUID.randomUUID().toString() }
    val quantity = normalizedQuantity(counted)
    AlertDialog(onDismissRequest = dismiss, title = { Text("Misma caja que ${partner.name ?: "Paciente sin nombre"}") },
        text = { androidx.compose.foundation.layout.Column {
            Note("El saldo común partirá de lo que cuentes ahora.")
            OutlinedTextField(counted, { counted = it }, label = { Text("¿Cuántos ${unitLabel(stock.unit)} hay en la caja?") }, singleLine = true,
                keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = androidx.compose.ui.text.input.KeyboardType.Decimal))
        } },
        confirmButton = { TextButton(enabled = quantity != null, onClick = { dismiss(); model.run { model.repository.sharePool(listOf(stock.accountId, partner.accountId), stock.accountId, quantity.orEmpty(), operation) } }) { Text("Compartir la caja") } },
        dismissButton = { TextButton(onClick = dismiss) { Text("Volver") } })
}
