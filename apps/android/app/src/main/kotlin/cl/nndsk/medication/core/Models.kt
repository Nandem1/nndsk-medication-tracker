package cl.nndsk.medication.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.time.Instant
import java.time.ZoneId
import java.util.UUID

val wireJson = Json { ignoreUnknownKeys = true; encodeDefaults = true; explicitNulls = false }

@Serializable
data class PatientAccess(@SerialName("patient_id") val patientId: String, @SerialName("link_id") val linkId: String? = null, val scopes: List<String>, @SerialName("display_name") val displayName: String? = null, @SerialName("profile_version") val profileVersion: Int = 1, val timezone: String = "America/Santiago")
@Serializable
data class Me(@SerialName("user_id") val userId: String, val patients: List<PatientAccess>, @SerialName("next_cursor") val nextCursor: String = "", @SerialName("display_name") val displayName: String? = null, @SerialName("profile_version") val profileVersion: Int = 1, @SerialName("profile_complete") val profileComplete: Boolean = false)
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
data class Inventory(@SerialName("treatment_id") val treatmentId: String, val balance: String, val unit: String, @SerialName("account_id") val accountId: String = "", @SerialName("first_uncovered_at") val firstUncoveredAt: String? = null, @SerialName("replenish_on") val replenishOn: String? = null, @SerialName("low_stock") val lowStock: Boolean = false, val timezone: String = "America/Santiago", val from: String = "", val through: String = "")
@Serializable
data class Link(@SerialName("link_id") val id: String, @SerialName("patient_id") val patientId: String, @SerialName("caregiver_id") val caregiverId: String, val scopes: List<String>, val status: String, @SerialName("patient_display_name") val patientName: String? = null, @SerialName("caregiver_display_name") val caregiverName: String? = null)
@Serializable
data class Invitation(@SerialName("caregiver_id") val caregiverId: String, val scopes: List<String>, @SerialName("expires_at") val expiresAt: String, @SerialName("caregiver_display_name") val caregiverName: String? = null, @SerialName("patient_name_hint") val patientNameHint: String? = null)
@Serializable
data class DoseResult(@SerialName("dose_id") val doseId: String, @SerialName("event_id") val eventId: String, val version: Int, val state: String, val balance: String)
@Serializable
data class Snapshot(val context: PatientContext, val doses: List<Dose> = emptyList(), val treatments: List<Treatment> = emptyList(), val inventory: List<Inventory> = emptyList(), val links: List<Link> = emptyList(), val refreshedAt: String? = null, val access: PatientAccess? = null, val profile: Me? = null, val report: DailyReport? = null)
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

@Serializable data class CreatedInvitation(val token: String, @SerialName("expires_at") val expiresAt: String)
@Serializable data class DailyCounts(val confirmed: Int, val evaluable: Int, val unconfirmed: Int)
@Serializable data class DailyReport(val from: String, val to: String, @SerialName("as_of") val asOf: String, val summary: DailyCounts)
@Serializable data class Movement(@SerialName("quantity_delta") val quantity: String, val reason: String, @SerialName("created_at") val createdAt: String)

fun patientName(access: PatientAccess?) = access?.displayName ?: "Paciente sin nombre"
fun invitationToken(text: String): String = Regex("[A-Za-z0-9_-]{43}").find(text)?.value ?: throw IllegalArgumentException("Pega un código de invitación válido.")
fun invitationMessage(token: String) = "Hola, te invito a Mis tomas. Abre la app, entra en Ajustes › Acceso de cuidadores y pega este código: $token. Vence en 24 horas."
val invitationPresets = linkedMapOf("Sólo mirar" to listOf("read"), "Ayudar a registrar" to listOf("read", "doses"), "Administrar todo" to listOf("read", "treatments", "doses", "inventory"))
fun appTabs(accesses: List<PatientAccess>, own: Snapshot?, caregiverPreference: Boolean): List<String> {
    val linked = accesses.any { it.linkId != null } || caregiverPreference
    return if (!linked) listOf("Hoy", "Historial", "Ajustes")
    else if (own?.treatments.orEmpty().isEmpty()) listOf("Pacientes", "Ajustes")
    else listOf("Hoy", "Historial", "Pacientes", "Ajustes")
}
data class PatientScreen(val snapshot: Snapshot?, val operations: List<PendingOperation>, val busy: Boolean = false, val offline: Boolean = false) {
    val caregiver: Boolean get() = snapshot?.context?.let { it.actorId != it.patientId } == true
    fun permits(scope: String) = snapshot?.let { !caregiver || scope in it.access?.scopes.orEmpty() } == true
}

fun coverageLabel(stock: Inventory): String {
    if (stock.from.isBlank() || stock.through.isBlank()) return "Sin proyección disponible"
    val zone = ZoneId.of(stock.timezone)
    val start = Instant.parse(stock.from).atZone(zone).toLocalDate()
    val end = Instant.parse(stock.firstUncoveredAt ?: stock.through).atZone(zone).toLocalDate()
    val days = java.time.temporal.ChronoUnit.DAYS.between(start, end).coerceAtLeast(0)
    return if (stock.firstUncoveredAt == null) "Al menos $days días en la proyección" else "$days días según la pauta registrada"
}
fun movementLabel(reason: String) = when (reason) {
    "initial" -> "Stock inicial"
    "replenishment" -> "Reposición"
    "consumption" -> "Consumo declarado"
    "reversal" -> "Reversa de declaración"
    "manual_adjustment" -> "Conteo físico"
    else -> "Ajuste de inventario"
}
