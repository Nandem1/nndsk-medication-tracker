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

/** Reglas de la hoja «Me lo tomé tarde». La hora nunca queda en el futuro. */
object LateTime {
    private val hourMinute = java.time.format.DateTimeFormatter.ofPattern("HH:mm")
    fun floorToMinute(value: Instant): Instant = value.truncatedTo(java.time.temporal.ChronoUnit.MINUTES)
    fun stepped(value: Instant, minutes: Long, now: Instant): Instant = minOf(value.plusSeconds(minutes * 60), floorToMinute(now))
    fun canAdvance(value: Instant, now: Instant): Boolean = value < floorToMinute(now)
    fun ago(minutes: Long, now: Instant): Instant = floorToMinute(now).minusSeconds(minutes * 60)
    fun label(value: Instant, timezone: String): String = value.atZone(ZoneId.of(timezone)).format(hourMinute)
    /** La misma hora local ocurre dos veces cuando se atrasa el reloj. */
    fun isRepeated(value: Instant, timezone: String): Boolean {
        val zone = ZoneId.of(timezone)
        return zone.rules.getValidOffsets(value.atZone(zone).toLocalDateTime()).size == 2
    }
}
