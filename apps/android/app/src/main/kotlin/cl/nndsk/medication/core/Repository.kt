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
import java.util.UUID

sealed interface Session {
    data object SignedOut : Session
    data object Active : Session
    data object Expired : Session
}
data class AppState(val session: Session = Session.SignedOut, val snapshot: Snapshot? = null,
    val operations: List<PendingOperation> = emptyList(), val busy: Boolean = false, val message: String? = null,
    /** Sólo presentación: el último intento no llegó al servidor. */
    val offline: Boolean = false,
    /** Sólo presentación: el mensaje es un rechazo que exige revisar. */
    val rejected: Boolean = false)

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

    private suspend fun publish(snapshot: Snapshot?) {
        val c = snapshot?.context
        val operations = if (c == null) emptyList() else dao.operations(c.ownerUid, c.patientId)
        mutable.update { it.copy(snapshot = snapshot, operations = operations) }
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

    /** La declaración queda en disco de inmediato, aunque haya una sincronización en curso. Después se envía. */
    suspend fun record(context: PatientContext, doseId: String, command: Command) {
        val saved = queue.withLock {
            val c = mutable.value.snapshot?.context ?: return
            if (identity.uid != c.ownerUid || c != context) {
                mutable.update { it.copy(message = "No se pudo guardar el registro. Vuelve a abrir la dosis.") }
                return
            }
            val path = "v1/doses/$doseId/" + if (command.corrects != null) "corrections" else "events"
            dao.enqueue(PendingOperation(command.id, c.ownerUid, c.patientId, doseId, path, wireJson.encodeToString(command), System.currentTimeMillis())) != -1L
        }
        // Un segundo toque sobre la misma dosis no crea otra declaración.
        if (!saved) return
        val operations = dao.operations(context.ownerUid, context.patientId)
        mutable.update { it.copy(operations = operations) }
        action { syncLocked() }
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
    private suspend fun action(invalidateOnDenied: Boolean = false, block: suspend () -> Unit) = mutex.withLock {
        mutable.value = mutable.value.copy(busy = true, message = null, offline = false, rejected = false)
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
            mutable.value = mutable.value.copy(message = message, rejected = e.status in listOf(400, 403, 404, 409, 422))
        } catch (_: java.io.IOException) {
            mutable.value = mutable.value.copy(offline = true)
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
