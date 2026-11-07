package cl.nndsk.medication.core

import androidx.room.withTransaction
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.sync.withLock
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import kotlinx.serialization.json.*
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger

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
    private val dirtyInventory = mutableSetOf<String>()
    private val dirtyReports = mutableSetOf<String>()
    private val dirtyDoseDays = mutableMapOf<String, MutableSet<String>>()
    private val activeActions = AtomicInteger()
    private val syncRequests = SyncRequests(CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate), ::publishBusy)
    private fun publishBusy() { mutable.update { it.copy(busy = activeActions.get() != 0 || syncRequests.busy) } }
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
    suspend fun login(email: String, password: String, register: Boolean = false) {
        syncRequests.invalidate()
        action {
            val previousOwner = identity.uid
            try { identity.signIn(email, password, register) } catch (e: ApiFailure) {
                if (e.status != 401) throw e
                mutable.update { it.copy(session = if (identity.uid == null) Session.SignedOut else Session.Expired,
                    message = "Correo o contraseña incorrectos. Revisa tus datos.") }
                return@action
            }
            if (identity.uid != previousOwner) { dirtyInventory.clear(); dirtyReports.clear(); dirtyDoseDays.clear() }
            onSignedIn()
            mutable.value = AppState(session = Session.Active, busy = true)
            publish()
            syncLocked()
        }
    }
    suspend fun resetPassword(email: String) = action {
        identity.resetPassword(email)
        mutable.update { it.copy(message = "Si existe una cuenta con ese correo, recibirás instrucciones para recuperar tu contraseña.", informational = true) }
    }
    suspend fun setUse(caregiver: Boolean) { identity.setCaregiverPreference(caregiver); publish() }
    suspend fun sync() = syncRequests.request { begin ->
        action(coalesced = true, begin = begin) { if (identity.uid != null) syncLocked() }
    }

    private suspend fun deny(uid: String, patient: String) {
        queue.withLock { db.withTransaction { dao.denyPatient(uid, patient); dao.clearPatient(uid, patient) } }
        dirtyInventory.remove(patient); dirtyReports.remove(patient); dirtyDoseDays.remove(patient)
        publish()
        mutable.update { it.copy(message = "Ya no tienes acceso a un paciente. Revisa sus registros pendientes en Ajustes.", rejected = true) }
    }
    private suspend fun drainQueue() {
        val uid = identity.uid ?: throw ApiFailure(401)
        val operations = dao.allOperations(uid)
        operations.filter { it.status == "conflict" }.forEach(::rememberConflict)
        for (op in operations.filter { it.status == "pending" }) {
            try {
                val result = wireJson.decodeFromString<DoseResult>(api.request(op.path, op.body))
                require(result.doseId == op.dose)
                dirtyInventory += inventoryPatients(patients = setOf(op.patient))
                dirtyReports += op.patient
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
                    409 -> {
                        dao.mark(uid, op.patient, op.id, "conflict")
                        rememberConflict(op)
                        dirtyInventory += inventoryPatients(patients = setOf(op.patient))
                        dirtyReports += op.patient
                    }
                    400, 413, 415, 422 -> dao.mark(uid, op.patient, op.id, "rejected")
                    else -> throw e
                }
            }
        }
        publish()
    }

    private fun rememberConflict(operation: PendingOperation) {
        val snapshot = mutable.value.patient(operation.patient)
        val date = snapshot?.doses?.find { it.id == operation.dose }?.localDate
            ?: LocalDate.now(ZoneId.of(snapshot?.access?.timezone ?: "America/Santiago")).toString()
        dirtyDoseDays.getOrPut(operation.patient) { mutableSetOf() }.add(date)
    }

    private suspend fun syncLocked() {
        drainQueue()
        refreshDirectory(full = true)
        mutable.update { it.copy(session = Session.Active) }
    }

    private data class Directory(val me: Me, val accesses: List<PatientAccess>, val families: List<Family>)

    private suspend fun directory(): Directory = coroutineScope {
        val me = async { api.get<Me>("v1/me") }
        val accesses = async { api.pages<PatientAccess>("v1/patients") }
        val families = async { api.pages<Family>("v1/families") }
        Directory(me.await(), accesses.await(), families.await())
    }

    private fun snapshots(): List<Snapshot> = listOfNotNull(mutable.value.own) + mutable.value.patients.values

    private fun inventoryPatients(patients: Set<String> = emptySet(), accounts: Set<String> = emptySet(), pools: Set<String> = emptySet()): Set<String> {
        val snapshots = snapshots()
        val knownAccounts = snapshots.flatMap { it.inventory.map { item -> item.accountId } }.toSet()
        val knownPools = snapshots.flatMap { it.inventory.mapNotNull { item -> item.pool?.id } }.toSet()
        if (!knownAccounts.containsAll(accounts) || !knownPools.containsAll(pools)) return snapshots.map { it.context.patientId }.toSet() + patients
        val selected = snapshots.filter { it.context.patientId in patients || it.inventory.any { item -> item.accountId in accounts || item.pool?.id in pools } }
        val shared = pools + selected.flatMap { it.inventory.mapNotNull { item -> item.pool?.id } }
        return patients + selected.map { it.context.patientId } + snapshots.filter { it.inventory.any { item -> item.pool?.id in shared } }.map { it.context.patientId }
    }

    private suspend fun blockedInventory(): Set<String> {
        val uid = identity.uid ?: return emptySet()
        return inventoryPatients(patients = dao.allOperations(uid).filter { it.status == "pending" }.map { it.patient }.toSet())
    }

    private suspend fun refreshDirectory(full: Boolean = false) {
        val uid = identity.uid ?: throw ApiFailure(401)
        val directory = directory()
        val allowed = directory.accesses.map { it.patientId }.toSet()
        for (stored in dao.snapshots(uid)) if (stored.patient !in allowed) deny(uid, stored.patient)
        val blocked = blockedInventory()
        val reload = directory.accesses.filter { access ->
            val previous = mutable.value.patient(access.patientId)?.access
            full || previous == null || previous.linkId != access.linkId || previous.scopes.toSet() != access.scopes.toSet() || previous.timezone != access.timezone
        }.map { it.patientId }.toSet()
        val readers = Semaphore(4)
        val results = coroutineScope {
            directory.accesses.map { access -> async { readers.withPermit {
                val previous = mutable.value.patient(access.patientId)
                try {
                    Result.success(if (access.patientId in reload) readSnapshot(uid, directory, access, blocked) else previous!!.copy(
                        access = access, profile = if (access.patientId == directory.me.userId) directory.me else previous.profile,
                        families = if (access.patientId == directory.me.userId) directory.families else previous.families))
                } catch (e: CancellationException) { throw e }
                catch (e: Exception) { Result.failure(e) }
            } } }.awaitAll()
        }
        val denied = directory.accesses.zip(results).filter { (_, result) ->
            val error = result.exceptionOrNull()
            error is ApiFailure && error.status in listOf(403, 404)
        }.map { it.first.patientId }.toSet()
        for (patient in denied) deny(uid, patient)
        if (results.any { (it.exceptionOrNull() as? ApiFailure)?.status == 401 }) throw ApiFailure(401)
        for ((access, result) in directory.accesses.zip(results)) {
            if (access.patientId in denied) continue
            val snapshot = result.getOrThrow()
            queue.withLock {
                val previous = mutable.value.patient(access.patientId)
                val old = previous?.doses.orEmpty().associateBy { it.id }
                val blockedNow = blockedInventory()
                val unresolved = dao.operations(uid, access.patientId).map { it.dose }.toSet()
                val received = snapshot.doses.map { old[it.id]?.takeIf { previous -> previous.version > it.version } ?: it }
                val receivedIDs = received.map { it.id }.toSet()
                val retained = old.values.filter { it.id in unresolved && it.id !in receivedIDs }
                val updated = snapshot.copy(
                    doses = received + retained,
                    inventory = if (access.patientId in blockedNow) previous?.inventory.orEmpty() else snapshot.inventory,
                    report = if (access.patientId in blockedNow) previous?.report else snapshot.report)
                save(updated)
                if (access.patientId !in blocked && access.patientId !in blockedNow && access.patientId in reload) {
                    dirtyInventory.remove(access.patientId); dirtyReports.remove(access.patientId)
                }
            }
        }
        refreshChangedPatients()
    }

    private suspend fun readSnapshot(uid: String, directory: Directory, access: PatientAccess, blocked: Set<String>): Snapshot = coroutineScope {
        val patient = access.patientId
        val previous = mutable.value.patient(patient)
        val day = LocalDate.now(ZoneId.of(access.timezone))
        val base = "v1/patients/$patient"
        val treatments = async { api.pages<Treatment>("$base/treatments") }
        val doses = async { api.pages<Dose>("$base/doses", mapOf("from" to day.minusDays(7).toString(), "to" to day.plusDays(21).toString())) }
        val inventory = async { if (patient in blocked) previous?.inventory.orEmpty() else api.pages<Inventory>("$base/inventory") }
        val report = async {
            if (patient == directory.me.userId) null
            else if (patient in blocked) previous?.report
            else api.get<DailyReport>("$base/adherence", mapOf("from" to day.toString(), "to" to day.plusDays(1).toString()))
        }
        Snapshot(PatientContext(uid, directory.me.userId, patient), doses.await(), treatments.await(), inventory.await(),
            if (patient == directory.me.userId) directory.families else emptyList(), Instant.now().toString(), access,
            if (patient == directory.me.userId) directory.me else null, report.await())
    }

    private suspend fun refreshChangedPatients() {
        val uid = identity.uid ?: throw ApiFailure(401)
        val blocked = blockedInventory()
        for (patient in (dirtyInventory + dirtyReports + dirtyDoseDays.keys).toList()) {
            if (patient in blocked) continue
            val previous = mutable.value.patient(patient) ?: continue
            try {
                val (inventory, report, doses) = coroutineScope {
                    val inventory = async { if (patient in dirtyInventory) api.pages<Inventory>("v1/patients/$patient/inventory") else previous.inventory }
                    val report = async {
                        if (patient == previous.context.actorId || patient !in dirtyReports) previous.report else {
                            val day = LocalDate.now(ZoneId.of(previous.access?.timezone ?: "America/Santiago"))
                            api.get<DailyReport>("v1/patients/$patient/adherence", mapOf("from" to day.toString(), "to" to day.plusDays(1).toString()))
                        }
                    }
                    val doses = async {
                        dirtyDoseDays[patient]?.toList()?.flatMap { date ->
                            api.pages<Dose>("v1/patients/$patient/doses", mapOf("from" to date, "to" to LocalDate.parse(date).plusDays(1).toString()))
                        }.orEmpty()
                    }
                    Triple(inventory.await(), report.await(), doses.await())
                }
                queue.withLock {
                    if (patient !in blockedInventory()) {
                        val current = mutable.value.patient(patient) ?: return@withLock
                        val merged = current.doses.associateBy { it.id }.toMutableMap()
                        for (dose in doses) if ((merged[dose.id]?.version ?: 0) <= dose.version) merged[dose.id] = dose
                        save(current.copy(inventory = inventory, report = report, doses = merged.values.toList()))
                        dirtyInventory.remove(patient); dirtyReports.remove(patient); dirtyDoseDays.remove(patient)
                    }
                }
            } catch (e: ApiFailure) {
                if (e.status == 403 || e.status == 404) deny(uid, patient) else throw e
            }
        }
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
        action { drainQueue(); refreshChangedPatients() }
    }
    suspend fun discard(id: String) = action {
        val uid = identity.uid ?: return@action
        val op = dao.allOperations(uid).single { it.id == id }
        require(op.status != "pending") { "Una solicitud pendiente puede haberse aplicado; reintenta antes de descartarla." }
        dao.remove(uid, op.patient, id)
        publish()
    }
    suspend fun preview(text: String): FamilyInvitationPreview = requestResult {
        wireJson.decodeFromString(api.request("v1/family-invitations/preview", wireJson.encodeToString(mapOf("token" to invitationToken(text)))))
    }
    /** La operación se conserva por token: un reintento tras perder la respuesta es la misma aceptación. */
    suspend fun accept(text: String) = action {
        val token = invitationToken(text)
        val operationId = identity.invitationOperation(token)
        api.request("v1/family-invitations/accept", wireJson.encodeToString(mapOf("token" to token, "client_operation_id" to operationId)))
        identity.clearInvitation()
        refreshDirectory()
    }
    suspend fun createFamily(name: String, operationId: String) = action {
        api.request("v1/families", buildJsonObject { put("client_operation_id", operationId); put("name", name.trim()) }.toString())
        refreshDirectory()
    }
    /** Cada envío crea otra invitación: el token no se puede recuperar si se pierde la respuesta. */
    suspend fun invite(familyId: String, role: String, hint: String): CreatedInvitation = requestResult {
        val body = buildJsonObject {
            put("client_operation_id", UUID.randomUUID().toString())
            put("role", role)
            if (role == "patient" && hint.isNotBlank()) put("patient_name_hint", hint.trim())
        }
        wireJson.decodeFromString(api.request("v1/families/$familyId/invitations", body.toString()))
    }
    /** Salir de la familia o, para quien administra, quitar a otra persona. */
    suspend fun removeMember(familyId: String, userId: String) = action {
        api.request("v1/families/$familyId/members/$userId", delete = true)
        refreshDirectory()
    }
    suspend fun updateProfile(patientId: String, name: String, version: Int, operationId: String) = action(patientId) {
        val own = mutable.value.own?.context?.patientId == patientId
        api.request(if (own) "v1/me/profile" else "v1/patients/$patientId/profile", buildJsonObject {
            put("client_operation_id", operationId); put("expected_version", version); put("display_name", name.trim())
        }.toString(), put = true)
        refreshDirectory()
    }
    suspend fun movements(patientId: String, accountId: String): List<Movement> = requestResult(patientId) { api.pages("v1/inventory/$accountId/movements") }
    suspend fun inventory(patientId: String, accountId: String, quantity: String, count: Boolean, reason: String, operationId: String, expectedBalance: String) = action(patientId) {
        val affected = inventoryPatients(patients = setOf(patientId), accounts = setOf(accountId))
        api.request("v1/inventory/$accountId/" + if (count) "counts" else "movements", buildJsonObject {
            put("client_operation_id", operationId)
            put(if (count) "counted_quantity" else "quantity", quantity)
            if (count) { put("reason", reason.trim()); put("expected_balance", expectedBalance) }
        }.toString())
        dirtyInventory += affected
        refreshChangedPatients()
    }
    suspend fun poolCandidates(accountId: String): List<PoolCandidate> = requestResult { api.pages("v1/inventory/$accountId/pool-candidates") }
    /** Marca la misma caja: el saldo común parte de lo contado en la cuenta indicada. */
    suspend fun sharePool(accounts: List<String>, countedAccount: String, counted: String, operationId: String) = action {
        val affected = inventoryPatients(accounts = accounts.toSet())
        api.request("v1/inventory-pools", buildJsonObject {
            put("client_operation_id", operationId); put("account_ids", JsonArray(accounts.map(::JsonPrimitive)))
            put("counted_account_id", countedAccount); put("counted_quantity", counted)
        }.toString())
        dirtyInventory += affected
        refreshChangedPatients()
    }
    suspend fun leavePool(poolId: String, accountId: String, operationId: String) = action {
        val affected = inventoryPatients(accounts = setOf(accountId), pools = setOf(poolId))
        api.request("v1/inventory-pools/$poolId/leave", buildJsonObject {
            put("client_operation_id", operationId); put("account_id", accountId)
        }.toString())
        dirtyInventory += affected
        refreshChangedPatients()
    }
    /** El archivo contiene datos de salud: nunca se registra en logs. */
    suspend fun exportAccount(): String = requestResult { api.request("v1/me/export") }
    /** Con la identidad aún activa conserva la sesión, para que la persona pueda reintentar. */
    suspend fun deleteAccount(operationId: String): Boolean {
        val removed = requestResult {
            val body = buildJsonObject { put("client_operation_id", operationId); put("confirm", "BORRAR") }.toString()
            wireJson.parseToJsonElement(api.request("v1/me", body, delete = true)).jsonObject.getValue("identity_removed").jsonPrimitive.boolean
        }
        if (removed) logout()
        return removed
    }
    suspend fun logout() {
        syncRequests.invalidate()
        mutex.withLock { withContext(NonCancellable) {
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
            dirtyInventory.clear(); dirtyReports.clear(); dirtyDoseDays.clear()
            mutable.value = AppState(message = warning)
            try { onChanged() } catch (_: Exception) {
                mutable.value = AppState(message = "La sesión se cerró. No se pudieron cancelar todos los recordatorios.")
            }
        } }
    }
    private suspend fun <T> requestResult(patientId: String? = null, block: suspend () -> T): T {
        syncRequests.barrier()
        return mutex.withLock {
            try { block() } catch (e: ApiFailure) {
                if (e.status == 401) {
                    syncRequests.invalidate()
                    mutable.update { it.copy(session = Session.Expired, message = "Vuelve a iniciar sesión con la misma cuenta. Tus pendientes se conservan.") }
                }
                if (e.status in listOf(403, 404) && patientId != null) identity.uid?.let { deny(it, patientId) }
                throw e
            }
        }
    }
    private suspend fun action(patientId: String? = null, coalesced: Boolean = false, begin: (() -> Boolean)? = null, block: suspend () -> Unit) {
        if (!coalesced) syncRequests.barrier()
        mutex.withLock {
            if (begin != null && !begin()) return@withLock
            activeActions.incrementAndGet()
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
                if (e.status == 401) { syncRequests.invalidate(); mutable.value = mutable.value.copy(session = Session.Expired) }
                mutable.value = mutable.value.copy(message = message, rejected = e.status in listOf(400, 403, 404, 409, 422))
            } catch (_: java.io.IOException) {
                mutable.value = mutable.value.copy(offline = true)
            } catch (_: Exception) {
                mutable.value = mutable.value.copy(message = "No se pudo completar la operación. Los registros guardados se conservan. Revisa la conexión y los datos.")
            } finally {
                try { publish() } finally { activeActions.decrementAndGet(); publishBusy() }
                try { onChanged() } catch (_: Exception) {
                    mutable.value = mutable.value.copy(message = "No se pudieron renovar los recordatorios. Revisa permisos y vuelve a sincronizar.")
                }
            }
        }
    }
}
