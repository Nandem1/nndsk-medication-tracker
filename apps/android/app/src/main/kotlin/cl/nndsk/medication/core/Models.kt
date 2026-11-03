package cl.nndsk.medication.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.time.Instant
import java.time.ZoneId
import java.util.UUID

val wireJson = Json { ignoreUnknownKeys = true; encodeDefaults = true; explicitNulls = false }

@Serializable
data class PatientAccess(@SerialName("patient_id") val patientId: String, @SerialName("link_id") val linkId: String? = null, val scopes: List<String>)
@Serializable
data class Me(@SerialName("user_id") val userId: String, val patients: List<PatientAccess>, @SerialName("next_cursor") val nextCursor: String = "")
@Serializable
data class PatientContext(val ownerUid: String, val actorId: String, val patientId: String)
@Serializable
data class Page<T>(val items: List<T>, @SerialName("next_cursor") val nextCursor: String = "")
@Serializable
data class Dose(
    @SerialName("dose_id") val id: String,
    @SerialName("treatment_id") val treatmentId: String,
    @SerialName("scheduled_at") val scheduledAt: String,
    @SerialName("local_date") val localDate: String,
    @SerialName("local_time") val localTime: String,
    val timezone: String,
    @SerialName("dst_adjusted") val dstAdjusted: Boolean,
    val quantity: String, val state: String, val version: Int,
    @SerialName("event_id") val eventId: String? = null,
) {
    fun today(now: Instant) = localDate == now.atZone(ZoneId.of(timezone)).toLocalDate().toString()
    fun declared() = state in listOf("taken", "taken_late", "skipped")
}
@Serializable
data class Treatment(@SerialName("treatment_id") val id: String, val name: String, @SerialName("strength_label") val strength: String, val instructions: String, val unit: String)
@Serializable
data class Inventory(@SerialName("treatment_id") val treatmentId: String, val balance: String, val unit: String)
@Serializable
data class Link(@SerialName("link_id") val id: String, @SerialName("patient_id") val patientId: String, @SerialName("caregiver_id") val caregiverId: String, val scopes: List<String>, val status: String)
@Serializable
data class Invitation(@SerialName("caregiver_id") val caregiverId: String, val scopes: List<String>, @SerialName("expires_at") val expiresAt: String)
@Serializable
data class DoseResult(@SerialName("dose_id") val doseId: String, @SerialName("event_id") val eventId: String, val version: Int, val state: String, val balance: String)
@Serializable
data class Snapshot(val context: PatientContext, val doses: List<Dose> = emptyList(), val treatments: List<Treatment> = emptyList(), val inventory: List<Inventory> = emptyList(), val links: List<Link> = emptyList(), val refreshedAt: String? = null)
@Serializable
data class Command(
    @SerialName("client_operation_id") val id: String,
    @SerialName("expected_version") val version: Int,
    @SerialName("event_type") val eventType: String,
    @SerialName("occurred_at") val occurredAt: String? = null,
    @SerialName("corrects_event_id") val corrects: String? = null,
    val reason: String? = null,
)

fun declaration(dose: Dose, type: String, occurredAt: Instant?, reason: String?, now: Instant = Instant.now()): Command {
    require(type in listOf("taken", "taken_late", "skipped"))
    require(type != "taken_late" || occurredAt != null) { "Indica la hora efectiva de la toma." }
    require(occurredAt == null || !occurredAt.isAfter(now)) { "La hora de toma no puede estar en el futuro." }
    require(!dose.declared() || (!reason.isNullOrBlank() && dose.eventId != null)) { "La corrección requiere motivo e historial." }
    return Command(UUID.randomUUID().toString(), dose.version, type,
        if (type == "skipped") null else (occurredAt ?: now).toString(),
        if (dose.declared()) dose.eventId else null, if (dose.declared()) reason?.trim() else null)
}

fun stateLabel(dose: Dose, now: Instant = Instant.now()): String = when (dose.state) {
    "taken" -> "Tomada"
    "taken_late" -> "Tomada tarde"
    "skipped" -> "No tomada"
    else -> if (Instant.parse(dose.scheduledAt) <= now) "Sin confirmar" else "Programada"
}
