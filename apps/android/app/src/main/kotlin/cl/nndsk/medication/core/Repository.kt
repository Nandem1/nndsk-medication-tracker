package cl.nndsk.medication.core

import androidx.room.withTransaction
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import kotlinx.serialization.json.*
import java.util.UUID

sealed interface Session {
    data object SignedOut : Session
    data object Active : Session
    data object Expired : Session
}
data class AppState(val session: Session = Session.SignedOut, val own: Snapshot? = null,
    val patients: Map<String, Snapshot> = emptyMap(), val accesses: List<PatientAccess> = emptyList(),
    val operations: List<PendingOperation> = emptyList(), val busy: Boolean = false, val message: String? = null,
    val offline: Boolean = false, val rejected: Boolean = false, val informational: Boolean = false, val caregiverPreference: Boolean? = null) {
    fun patient(id: String): Snapshot? = own?.takeIf { it.context.patientId == id } ?: patients[id]
    fun screen(id: String? = own?.context?.patientId): PatientScreen = PatientScreen(
        id?.let(::patient), operations.filter { it.patient == id }, busy, offline)
}

class Repository(val identity: Identity, private val api: Api, private val db: LocalDatabase) {
    private val mutex = Mutex()
    /** Sólo protege escribir y limpiar la cola. Nunca se sostiene durante la red. */
    private val queue = Mutex()
    private val mutable = MutableStateFlow(AppState())
    val state = mutable.asStateFlow()
    private val dao = db.local()
    var onChanged: suspend () -> Unit = {}
    var onSignedIn: suspend () -> Unit = {}
    var onSigningOut: suspend () -> String? = { null }

    private suspend fun publish() {
        val uid = identity.uid ?: return
        val snapshots = dao.snapshots(uid).map { wireJson.decodeFromString<Snapshot>(it.json) }
        mutable.update { it.copy(
            own = snapshots.find { s -> s.context.actorId == s.context.patientId },
            patients = snapshots.filter { s -> s.context.actorId != s.context.patientId }.associateBy { s -> s.context.patientId },
            accesses = snapshots.mapNotNull { s -> s.access }, operations = dao.allOperations(uid), caregiverPreference = identity.caregiverPreference) }
    }
    private suspend fun save(snapshot: Snapshot) {
        dao.save(StoredSnapshot(snapshot.context.ownerUid, snapshot.context.patientId, wireJson.encodeToString(snapshot)))
        publish()
    }
    suspend fun restore() = action {
        if (identity.uid == null) {
            if (identity.storageFailure) mutable.value = AppState(session = Session.Expired, message = "No se pudo leer la sesión guardada. Vuelve a entrar con tu cuenta o cierra sesión.")
            return@action
        }
        mutable.update { it.copy(session = Session.Active) }
        publish()
        syncLocked()
    }
    suspend fun login(email: String, password: String, register: Boolean = false) = action {
        try { identity.signIn(email, password, register) } catch (e: ApiFailure) {
            if (e.status != 401) throw e
            mutable.update { it.copy(session = if (identity.uid == null) Session.SignedOut else Session.Expired,
                message = "Correo o contraseña incorrectos. Revisa tus datos.") }
            return@action
        }
        onSignedIn()
        mutable.value = AppState(session = Session.Active, busy = true)
        publish()
        syncLocked()
    }
    suspend fun resetPassword(email: String) = action {
        identity.resetPassword(email)
        mutable.update { it.copy(message = "Si existe una cuenta con ese correo, recibirás instrucciones para recuperar tu contraseña.", informational = true) }
    }
    suspend fun setUse(caregiver: Boolean) { identity.setCaregiverPreference(caregiver); publish() }
    suspend fun sync() = action { if (identity.uid != null) syncLocked() }

    private suspend fun deny(uid: String, patient: String) {
        queue.withLock { db.withTransaction { dao.denyPatient(uid, patient); dao.clearPatient(uid, patient) } }
        publish()
        mutable.update { it.copy(message = "Ya no tienes acceso a un paciente. Revisa sus registros pendientes en Ajustes.", rejected = true) }
    }
    private suspend fun syncLocked() {
        val uid = identity.uid ?: throw ApiFailure(401)
        for (op in dao.allOperations(uid).filter { it.status == "pending" }) {
            try {
                val result = wireJson.decodeFromString<DoseResult>(api.request(op.path, op.body))
                require(result.doseId == op.dose)
                queue.withLock { db.withTransaction {
                    dao.snapshot(uid, op.patient)?.let { stored ->
                        val previous = wireJson.decodeFromString<Snapshot>(stored.json)
                        val updated = previous.copy(doses = previous.doses.map { dose ->
                            if (dose.id == result.doseId && result.version >= dose.version) dose.copy(state = result.state, version = result.version, eventId = result.eventId) else dose
                        })
                        dao.save(stored.copy(json = wireJson.encodeToString(updated)))
                    }
                    dao.remove(uid, op.patient, op.id)
                } }
            } catch (e: ApiFailure) {
                when (e.status) {
                    403, 404 -> deny(uid, op.patient)
                    409 -> dao.mark(uid, op.patient, op.id, "conflict")
                    400, 413, 415, 422 -> dao.mark(uid, op.patient, op.id, "rejected")
                    else -> throw e
                }
            }
        }
        publish()
        val me = api.get<Me>("v1/me")
        val accesses = api.pages<PatientAccess>("v1/patients")
        val allowed = accesses.map { it.patientId }.toSet()
        for (stored in dao.snapshots(uid)) if (stored.patient !in allowed) deny(uid, stored.patient)
        val links = api.pages<Link>("v1/caregiver-links").filter { it.status == "active" }
        for (access in accesses) {
            val c = PatientContext(uid, me.userId, access.patientId)
            try {
                val day = LocalDate.now(ZoneId.of(access.timezone))
                val base = "v1/patients/${c.patientId}"
                val treatments = api.pages<Treatment>("$base/treatments")
                val doses = api.pages<Dose>("$base/doses", mapOf("from" to day.minusDays(7).toString(), "to" to day.plusDays(21).toString()))
                val inventory = api.pages<Inventory>("$base/inventory")
                val report = api.get<DailyReport>("$base/adherence", mapOf("from" to day.toString(), "to" to day.plusDays(1).toString()))
                val old = mutable.value.patient(c.patientId)?.doses.orEmpty().associateBy { it.id }
                save(Snapshot(c, doses.map { old[it.id]?.takeIf { previous -> previous.version > it.version } ?: it },
                    treatments, inventory, links.filter { it.patientId == c.patientId }, Instant.now().toString(), access,
                    if (c.patientId == me.userId) me else null, report))
            } catch (e: ApiFailure) {
                if (e.status == 403 || e.status == 404) deny(uid, c.patientId) else throw e
            }
        }
        mutable.update { it.copy(session = Session.Active) }
    }

    /** La escritura local no espera al mutex de red. */
    suspend fun record(context: PatientContext, doseId: String, command: Command) {
        val saved = queue.withLock {
            val current = mutable.value.patient(context.patientId) ?: return
            if (identity.uid != context.ownerUid || current.context != context ||
                (context.patientId != context.actorId && "doses" !in current.access?.scopes.orEmpty())) {
                mutable.update { it.copy(message = "No se pudo guardar el registro. Vuelve a abrir la dosis.") }
                return
            }
            val path = "v1/doses/$doseId/" + if (command.corrects != null) "corrections" else "events"
            dao.enqueue(PendingOperation(command.id, context.ownerUid, context.patientId, doseId, path, wireJson.encodeToString(command), System.currentTimeMillis())) != -1L
        }
        if (!saved) return
        publish()
        action { syncLocked() }
    }
    suspend fun discard(id: String) = action {
        val uid = identity.uid ?: return@action
        val op = dao.allOperations(uid).single { it.id == id }
        require(op.status != "pending") { "Una solicitud pendiente puede haberse aplicado; reintenta antes de descartarla." }
        dao.remove(uid, op.patient, id)
        publish()
    }
    suspend fun preview(text: String): Invitation = requestResult {
        wireJson.decodeFromString(api.request("v1/invitations/preview", wireJson.encodeToString(mapOf("token" to invitationToken(text)))))
    }
    suspend fun accept(text: String) = action {
        val token = invitationToken(text)
        val operationId = identity.invitationOperation(token)
        api.request("v1/invitations/accept", wireJson.encodeToString(mapOf("token" to token, "client_operation_id" to operationId)))
        identity.clearInvitation()
        syncLocked()
    }
    suspend fun createInvitation(scopes: List<String>, hint: String): CreatedInvitation = requestResult {
        val body = buildJsonObject {
            put("client_operation_id", UUID.randomUUID().toString())
            put("scopes", JsonArray(scopes.map(::JsonPrimitive)))
            if (hint.isNotBlank()) put("patient_name_hint", hint.trim())
        }
        wireJson.decodeFromString(api.request("v1/invitations", body.toString()))
    }
    suspend fun updateProfile(patientId: String, name: String, version: Int, operationId: String) = action(patientId) {
        val own = mutable.value.own?.context?.patientId == patientId
        api.request(if (own) "v1/me/profile" else "v1/patients/$patientId/profile", buildJsonObject {
            put("client_operation_id", operationId); put("expected_version", version); put("display_name", name.trim())
        }.toString(), put = true)
        syncLocked()
    }
    suspend fun movements(patientId: String, accountId: String): List<Movement> = requestResult(patientId) { api.pages("v1/inventory/$accountId/movements") }
    suspend fun inventory(patientId: String, accountId: String, quantity: String, count: Boolean, reason: String, operationId: String, expectedBalance: String) = action(patientId) {
        api.request("v1/inventory/$accountId/" + if (count) "counts" else "movements", buildJsonObject {
            put("client_operation_id", operationId)
            put(if (count) "counted_quantity" else "quantity", quantity)
            if (count) { put("reason", reason.trim()); put("expected_balance", expectedBalance) }
        }.toString())
        syncLocked()
    }
    suspend fun revoke(id: String) = action {
        api.request("v1/caregiver-links/$id", delete = true)
        syncLocked()
    }
    suspend fun logout() = mutex.withLock { withContext(NonCancellable) {
        mutable.value = AppState(busy = true)
        var warning: String? = null
        try { warning = onSigningOut() } catch (_: Exception) {
            warning = "No se pudo desactivar el registro remoto; podría llegar un aviso genérico hasta su vencimiento."
        }
        try { identity.clear() } catch (_: Exception) {
            warning = "No se pudo borrar la sesión guardada. Reinicia la app e intenta cerrar sesión nuevamente."
        }
        try { queue.withLock { db.withTransaction { dao.clearAllOperations(); dao.clearAllSnapshots() } } } catch (_: Exception) {
            warning = "La sesión se cerró, pero no se pudieron borrar los datos locales. Intenta cerrar sesión nuevamente."
        }
        mutable.value = AppState(message = warning)
        try { onChanged() } catch (_: Exception) {
            mutable.value = AppState(message = "La sesión se cerró. No se pudieron cancelar todos los recordatorios.")
        }
    } }
    private suspend fun <T> requestResult(patientId: String? = null, block: suspend () -> T): T = mutex.withLock {
        try { block() } catch (e: ApiFailure) {
            if (e.status == 401) mutable.update { it.copy(session = Session.Expired, message = "Vuelve a iniciar sesión con la misma cuenta. Tus pendientes se conservan.") }
            if (e.status in listOf(403, 404) && patientId != null) identity.uid?.let { deny(it, patientId) }
            throw e
        }
    }
    private suspend fun action(patientId: String? = null, block: suspend () -> Unit) = mutex.withLock {
        mutable.value = mutable.value.copy(busy = true, message = null, offline = false, rejected = false, informational = false)
        try { block() }
        catch (e: CancellationException) { throw e }
        catch (e: ApiFailure) {
            val message = when (e.status) {
                401 -> "Vuelve a iniciar sesión con la misma cuenta. Tus pendientes se conservan."
                403, 404 -> "Ya no tienes acceso a esta información."
                409 -> "La información cambió. Actualiza y revisa antes de continuar."
                400, 422 -> "Revisa los datos ingresados."
                else -> "No se pudo sincronizar. Tus pendientes se conservan; vuelve a intentarlo."
            }
            if (e.status in listOf(403, 404) && patientId != null) identity.uid?.let { deny(it, patientId) }
            if (e.status == 401) mutable.value = mutable.value.copy(session = Session.Expired)
            mutable.value = mutable.value.copy(message = message, rejected = e.status in listOf(400, 403, 404, 409, 422))
        } catch (_: java.io.IOException) {
            mutable.value = mutable.value.copy(offline = true)
        } catch (_: Exception) {
            mutable.value = mutable.value.copy(message = "No se pudo completar la operación. Los registros guardados se conservan. Revisa la conexión y los datos.")
        } finally {
            publish()
            mutable.value = mutable.value.copy(busy = false)
            try { onChanged() } catch (_: Exception) {
                mutable.value = mutable.value.copy(message = "No se pudieron renovar los recordatorios. Revisa permisos y vuelve a sincronizar.")
            }
        }
    }
}
