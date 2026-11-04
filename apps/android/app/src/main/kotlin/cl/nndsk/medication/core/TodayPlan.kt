package cl.nndsk.medication.core

import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * Pasado este plazo una dosis deja de presentarse como «Ahora toca», para no sugerir tomarla.
 * Es una decisión de presentación, no clínica: sigue sin confirmar y se puede registrar.
 */
val currentWindow: Duration = Duration.ofHours(4)

/** Reparte las dosis de la pantalla Hoy. Sólo presenta: no cambia estados ni cola. */
data class TodayPlan(val review: List<Dose>, val current: Dose?, val later: List<Dose>, val overdue: List<Dose>, val registered: List<Dose>, val registeredCount: Int, val total: Int)

fun todayPlan(doses: List<Dose>, operations: List<PendingOperation>, now: Instant): TodayPlan {
    val byDose = operations.associateBy { it.dose }
    val sorted = doses.sortedWith(compareBy({ Instant.parse(it.scheduledAt) }, { it.id }))
    val needsReview = { dose: Dose -> byDose[dose.id]?.let { it.status != "pending" } ?: false }
    val today = sorted.filter { it.today(now) }
    val rest = today.filterNot(needsReview)
    val open = rest.filter { !it.declared() && byDose[it.id] == null }
    val (overdue, active) = open.partition { Instant.parse(it.scheduledAt) < now.minus(currentWindow) }
    val registered = rest.filter { it.declared() || byDose[it.id] != null }
    // Toda declaración cuenta, incluida la omisión y la guardada sin enviar.
    // Un conflicto sólo cuenta si el servidor ya tiene una declaración de hoy.
    val count = registered.size + today.count { needsReview(it) && it.declared() }
    return TodayPlan(sorted.filter(needsReview), active.firstOrNull(), active.drop(1), overdue, registered, count, today.size)
}

private val spanish = Locale.forLanguageTag("es-CL")

fun longDate(now: Instant, zone: ZoneId): String =
    now.atZone(zone).format(DateTimeFormatter.ofPattern("EEEE, d 'de' MMMM", spanish)).replaceFirstChar { it.titlecase(spanish) }
