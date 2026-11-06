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
data class Inventory(@SerialName("treatment_id") val treatmentId: String, val balance: String, val unit: String, @SerialName("account_id") val accountId: String = "", @SerialName("first_uncovered_at") val firstUncoveredAt: String? = null, @SerialName("replenish_on") val replenishOn: String? = null, @SerialName("low_stock") val lowStock: Boolean = false, val timezone: String = "America/Santiago", val from: String = "", val through: String = "", val pool: InventoryPool? = null)
@Serializable
data class FamilyMember(@SerialName("user_id") val userId: String, @SerialName("display_name") val name: String? = null, val role: String, @SerialName("joined_at") val joinedAt: String, val you: Boolean = false)
@Serializable
data class Family(@SerialName("family_id") val id: String, val name: String, val role: String, val members: List<FamilyMember> = emptyList())
@Serializable
data class FamilyInvitationPreview(@SerialName("family_name") val familyName: String, @SerialName("inviter_display_name") val inviterName: String? = null, val role: String, @SerialName("patient_name_hint") val patientNameHint: String? = null, val members: List<FamilyMember> = emptyList(), @SerialName("expires_at") val expiresAt: String)
@Serializable
data class DoseResult(@SerialName("dose_id") val doseId: String, @SerialName("event_id") val eventId: String, val version: Int, val state: String, val balance: String)
@Serializable
data class Snapshot(val context: PatientContext, val doses: List<Dose> = emptyList(), val treatments: List<Treatment> = emptyList(), val inventory: List<Inventory> = emptyList(), val families: List<Family> = emptyList(), val refreshedAt: String? = null, val access: PatientAccess? = null, val profile: Me? = null, val report: DailyReport? = null)
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
@Serializable data class Movement(@SerialName("quantity_delta") val quantity: String, val reason: String, @SerialName("created_at") val createdAt: String, val shared: Boolean = false, @SerialName("patient_display_name") val patientName: String? = null)
@Serializable data class PoolMember(@SerialName("patient_display_name") val name: String? = null, val you: Boolean = false, val current: Boolean = false, val status: String = "accepted")
@Serializable data class InventoryPool(@SerialName("pool_id") val id: String, val status: String, val members: List<PoolMember> = emptyList())
@Serializable data class PoolCandidate(@SerialName("account_id") val accountId: String, @SerialName("patient_display_name") val name: String? = null, val you: Boolean = false)

/** Los demás miembros del inventario, sin la persona dueña de esta cuenta. */
fun poolOthers(pool: InventoryPool, status: String? = null) = pool.members.filter { !it.current && (status == null || it.status == status) }
    .map { it.name ?: "Paciente sin nombre" }.distinct().joinToString(", ").ifEmpty { "otra persona" }
/** El servidor anula la hora de la actividad ajena: se muestra sólo la fecha, sin convertir de zona. */
fun sharedActivityDate(createdAt: String) = createdAt.take(10).split("-").reversed().joinToString("-")

fun patientName(access: PatientAccess?) = access?.displayName ?: "Paciente sin nombre"
fun invitationToken(text: String): String = Regex("[A-Za-z0-9_-]{43}").find(text)?.value ?: throw IllegalArgumentException("Pega un código de invitación válido.")
/** El enlace abre la app. El token va en el fragmento: ningún servidor lo recibe por la URL. */
fun invitationLink(token: String) = "mistomas://unirse#$token"
fun invitationMessage(token: String, family: String) = "Hola, te invito a «$family» en Mis tomas. En tu teléfono, toca este enlace:\n\n${invitationLink(token)}\n\nSi no se abre, entra en la app, ve a Ajustes › Familia y pega este código: $token\n\nVence en 7 días."
val familyRoles = linkedMapOf("patient" to "Paciente", "caregiver" to "Cuidar", "observer" to "Sólo mirar", "admin" to "Administrar")
fun roleLabel(role: String) = familyRoles[role] ?: role
fun roleDescription(role: String) = when (role) {
    "patient" -> "Registra sus propias tomas. Quienes cuidan en la familia verán su agenda."
    "caregiver" -> "Ve a cada paciente, registra tomas y repone stock."
    "observer" -> "Ve agendas, historial e inventario. No cambia nada."
    else -> "Todo lo anterior, más tratamientos e invitar o quitar personas."
}
fun memberName(member: FamilyMember) = member.name ?: "Persona sin nombre"
fun initials(name: String?): String {
    val words = name.orEmpty().trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
    if (words.isEmpty()) return "?"
    return (words.first().take(1) + if (words.size > 1) words.last().take(1) else "").uppercase()
}
/** Un miembro es nuevo durante su primera semana, para que el paciente sepa quién se unió. */
fun isNewMember(member: FamilyMember, now: Instant = Instant.now()) =
    !member.you && runCatching { java.time.Duration.between(Instant.parse(member.joinedAt), now) < java.time.Duration.ofDays(7) }.getOrDefault(false)
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

/** El informe guardado puede ser de otro día: sólo se llama «hoy» si lo es, en la zona del paciente. */
fun reportPeriodLabel(from: String, today: java.time.LocalDate) =
    if (from == today.toString()) "Hoy hasta ahora" else "Datos del ${sharedActivityDate(from)}"
/** El teclado chileno escribe coma. La API recibe punto y hasta tres decimales. */
fun normalizedQuantity(text: String) = text.trim().replace(',', '.').takeIf { Regex("[0-9]{1,9}(\\.[0-9]{1,3})?").matches(it) }
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
    "pool_transfer" -> "Traspaso por inventario compartido"
    "shared_activity" -> "Actividad compartida"
    else -> "Ajuste de inventario"
}
