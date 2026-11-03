package cl.nndsk.medication.core

import java.time.*

fun effectiveOffsets(date: String, time: String, timezone: String): List<ZoneOffset> =
    ZoneId.of(timezone).rules.getValidOffsets(LocalDateTime.of(LocalDate.parse(date), LocalTime.parse(time)))

fun effectiveInstant(date: String, time: String, timezone: String, selectedOffset: String?): Instant {
    val offsets = effectiveOffsets(date, time, timezone)
    require(offsets.isNotEmpty()) { "Esa hora no existió por el cambio horario. Revisa la hora efectiva." }
    val offset = if (offsets.size == 1) offsets.single() else offsets.find { it.id == selectedOffset }
    requireNotNull(offset) { "Elige la primera o segunda vez que ocurrió esta hora." }
    return LocalDateTime.of(LocalDate.parse(date), LocalTime.parse(time)).toInstant(offset)
}
