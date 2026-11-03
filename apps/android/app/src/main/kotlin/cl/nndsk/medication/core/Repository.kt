package cl.nndsk.medication.core

import androidx.room.withTransaction
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.time.Instant
import java.time.LocalDate
import java.util.UUID

sealed interface Session {
    data object SignedOut : Session
    data object Active : Session
    data object Expired : Session
}
data class AppState(val session: Session = Session.SignedOut, val snapshot: Snapshot? = null,
    val operations: List<PendingOperation> = emptyList(), val busy: Boolean = false, val message: String? = null)

class Repository(val identity: Identity, private val api: Api, private val db: LocalDatabase) {
    private val mutex = Mutex()
    private val mutable = MutableStateFlow(AppState())
    val state = mutable.asStateFlow()
    private val dao = db.local()
    var onChanged: suspend () -> Unit = {}
    var onSignedIn: suspend () -> Unit = {}
    var onSigningOut: suspend () -> String? = { null }

    private suspend fun publish(snapshot: Snapshot?) {
        val c = snapshot?.context
        mutable.value = mutable.value.copy(snapshot = snapshot,
            operations = if (c == null) emptyList() else dao.operations(c.ownerUid, c.patientId))
    }
    private suspend fun save(snapshot: Snapshot) {
        dao.save(StoredSnapshot(snapshot.context.ownerUid, snapshot.context.patientId, wireJson.encodeToString(snapshot)))
        publish(snapshot)
    }
    suspend fun restore() = action(invalidateOnDenied = true) {
        val uid = identity.uid ?: run {
            if (identity.storageFailure) mutable.value = AppState(session = Session.Expired, message = "No se pudo leer la sesión guardada. Vuelve a entrar con tu cuenta para recuperar sus pendientes o cierra sesión para borrar los datos locales.")
            return@action
        }
        mutable.value = mutable.value.copy(session = Session.Active)
        val saved = dao.snapshots(uid).singleOrNull()?.let { wireJson.decodeFromString<Snapshot>(it.json) }
        publish(saved)
        syncLocked()
    }
    suspend fun login(email: String, password: String) = action(invalidateOnDenied = true) {
        val uid = try { identity.signIn(email, password) } catch (e: ApiFailure) {
            if (e.status != 401) throw e
            mutable.value = mutable.value.copy(
                session = if (identity.uid == null && !identity.storageFailure) Session.SignedOut else Session.Expired,
                message = "Correo o contraseña incorrectos. Revisa tus datos.")
            return@action
        }
        onSignedIn()
        mutable.value = AppState(session = Session.Active, busy = true)
        publish(dao.snapshots(uid).singleOrNull()?.let { wireJson.decodeFromString<Snapshot>(it.json) })
        syncLocked()
    }
    suspend fun sync() = action(invalidateOnDenied = true) { if (identity.uid != null) syncLocked() }

    private suspend fun syncLocked() {
        val c = mutable.value.snapshot?.context ?: api.context().also { save(Snapshot(it)) }
        check(identity.uid == c.ownerUid)
        for (op in dao.operations(c.ownerUid, c.patientId).filter { it.status == "pending" }) {
            try {
                val result = wireJson.decodeFromString<DoseResult>(api.request(op.path, op.body))
                require(result.doseId == op.dose)
                db.withTransaction {
                    val previous = dao.snapshot(c.ownerUid, c.patientId)?.let { wireJson.decodeFromString<Snapshot>(it.json) } ?: Snapshot(c)
                    val updated = previous.copy(doses = previous.doses.map { dose ->
                        if (dose.id == result.doseId && result.version >= dose.version) dose.copy(state = result.state, version = result.version, eventId = result.eventId) else dose
                    })
                    dao.save(StoredSnapshot(c.ownerUid, c.patientId, wireJson.encodeToString(updated)))
                    dao.remove(c.ownerUid, c.patientId, op.id)
                }
            } catch (e: ApiFailure) {
                val status = when (e.status) { 409 -> "conflict"; 400, 413, 415, 422 -> "rejected"; 403, 404 -> "denied"; else -> throw e }
                dao.mark(c.ownerUid, c.patientId, op.id, status)
            }
        }
        publish(dao.snapshot(c.ownerUid, c.patientId)?.let { wireJson.decodeFromString<Snapshot>(it.json) })
        val start = LocalDate.now().minusDays(7).toString()
        val end = LocalDate.now().plusDays(21).toString()
        val treatments = api.pages<Treatment>("v1/patients/${c.patientId}/treatments")
        val doses = api.pages<Dose>("v1/patients/${c.patientId}/doses", mapOf("from" to start, "to" to end))
        val inventory = api.pages<Inventory>("v1/patients/${c.patientId}/inventory")
        val links = api.pages<Link>("v1/caregiver-links").filter { it.patientId == c.patientId && it.status == "active" }
        val old = mutable.value.snapshot?.doses.orEmpty().associateBy { it.id }
        save(Snapshot(c, doses.map { new -> old[new.id]?.takeIf { it.version > new.version } ?: new }, treatments, inventory, links, Instant.now().toString()))
        mutable.value = mutable.value.copy(session = Session.Active)
    }

    suspend fun record(context: PatientContext, doseId: String, command: Command) = action {
        val snapshot = mutable.value.snapshot ?: return@action
        val c = snapshot.context
        check(identity.uid == c.ownerUid && c == context)
        val path = "v1/doses/$doseId/" + if (command.corrects != null) "corrections" else "events"
        val op = PendingOperation(command.id, c.ownerUid, c.patientId, doseId, path, wireJson.encodeToString(command), System.currentTimeMillis())
        if (dao.enqueue(op) == -1L) throw IllegalArgumentException("Esta dosis ya tiene una declaración pendiente de revisión o sincronización.")
        publish(snapshot)
        onChanged()
        syncLocked()
    }
    suspend fun discard(id: String) = action {
        val c = mutable.value.snapshot?.context ?: return@action
        val op = dao.operations(c.ownerUid, c.patientId).single { it.id == id }
        require(op.status != "pending") { "Una solicitud pendiente puede haberse aplicado; reintenta antes de descartarla." }
        dao.remove(c.ownerUid, c.patientId, id)
        publish(mutable.value.snapshot)
    }
    suspend fun preview(token: String): Invitation = mutex.withLock {
        wireJson.decodeFromString(api.request("v1/invitations/preview", wireJson.encodeToString(mapOf("token" to token.trim()))))
    }
    suspend fun accept(token: String) = action {
        val operationId = identity.invitationOperation(token.trim())
        api.request("v1/invitations/accept", wireJson.encodeToString(mapOf("token" to token.trim(), "client_operation_id" to operationId)))
        identity.clearInvitation()
        syncLocked()
    }
    suspend fun revoke(id: String) = action {
        api.request("v1/caregiver-links/$id", delete = true)
        syncLocked()
    }
    suspend fun logout() = action {
        val pushWarning = onSigningOut()
        identity.clear()
        db.withTransaction { dao.clearAllOperations(); dao.clearAllSnapshots() }
        mutable.value = AppState(message = pushWarning)
    }
    private suspend fun action(invalidateOnDenied: Boolean = false, block: suspend () -> Unit) = mutex.withLock {
        mutable.value = mutable.value.copy(busy = true, message = null)
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
            if (e.status == 401) mutable.value = mutable.value.copy(session = Session.Expired)
            if (invalidateOnDenied && (e.status == 403 || e.status == 404)) {
                mutable.value.snapshot?.context?.let { c ->
                    dao.clearSnapshots(c.ownerUid)
                    publish(Snapshot(c))
                }
            }
            mutable.value = mutable.value.copy(message = message)
        } catch (_: Exception) {
            mutable.value = mutable.value.copy(message = "No se pudo completar la operación. Los registros guardados se conservan. Revisa la conexión y los datos.")
        } finally {
            mutable.value.snapshot?.context?.let { c ->
                publish(dao.snapshot(c.ownerUid, c.patientId)?.let { wireJson.decodeFromString<Snapshot>(it.json) } ?: mutable.value.snapshot)
            }
            mutable.value = mutable.value.copy(busy = false)
            try { onChanged() } catch (_: Exception) {
                mutable.value = mutable.value.copy(message = "No se pudieron renovar los recordatorios. Revisa permisos y vuelve a sincronizar.")
            }
        }
    }
}
