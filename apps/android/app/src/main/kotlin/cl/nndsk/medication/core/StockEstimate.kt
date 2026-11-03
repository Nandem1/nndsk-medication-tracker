package cl.nndsk.medication.core

import java.math.BigDecimal

fun estimatedBalance(snapshot: Snapshot, operations: List<PendingOperation>, treatmentId: String): String? {
    val inventory = snapshot.inventory.find { it.treatmentId == treatmentId } ?: return null
    var balance = BigDecimal(inventory.balance)
    for (operation in operations) {
        val dose = snapshot.doses.find { it.id == operation.dose } ?: return null
        if (dose.treatmentId != treatmentId) continue
        if (operation.status != "pending") return null
        val command = wireJson.decodeFromString<Command>(operation.body)
        if (command.version != dose.version) return null
        val before = dose.state == "taken" || dose.state == "taken_late"
        val after = command.eventType == "taken" || command.eventType == "taken_late"
        if (before != after) balance = if (after) balance.subtract(BigDecimal(dose.quantity)) else balance.add(BigDecimal(dose.quantity))
    }
    return balance.setScale(3).toPlainString()
}

fun quantityText(value: String): String = BigDecimal(value).stripTrailingZeros().toPlainString().replace('.', ',')
