import Foundation
import Network
import Observation

enum SessionPhase: Equatable {
    case loading
    case misconfigured
    /// La base local no abrió. No se ofrece registrar nada que no se pueda guardar.
    case storageUnavailable
    case signingOut
    case signedOut
    /// Las credenciales vencieron. La caché y la cola se conservan para la misma cuenta.
    case expired
    case signedIn
}

enum AppTab: Hashable {
    case today, history, patients, settings
}

@Observable
@MainActor
final class AppModel {
    private(set) var phase: SessionPhase = .loading
    private(set) var snapshot = LocalSnapshot()
    private(set) var patients: [String: LocalSnapshot] = [:]
    private(set) var accesses: [PatientAccess] = []
    /// Se leen en línea en cada sincronización; nil mientras no hay respuesta.
    private(set) var families: [Family]?
    /// Código que llegó por un enlace mistomas://unirse#…, a la espera de una sesión.
    var pendingJoinToken: String?
    private(set) var allOperations: [PendingOperation] = []
    private(set) var profile: Me?
    private(set) var email = ""
    private(set) var caregiverPreference: Bool?
    var patientPath: [String] = []
    var tabs: [AppTab] {
        let linked = !patients.isEmpty || caregiverPreference == true
        return !linked ? [.today, .history, .settings] : snapshot.treatments.isEmpty ? [.patients, .settings] : [.today, .history, .patients, .settings]
    }
    var needsOnboarding: Bool { syncProblem != .transport && profile != nil && (profile?.profileComplete == false || caregiverPreference == nil) }
    var pushConfigured: Bool { RemotePush.enabled }

    private(set) var reminders = ReminderDiagnostic()
    private(set) var isSyncing = false
    private(set) var syncProblem: APIError?
    /// Cuentas con declaraciones sin sincronizar en este dispositivo, al entrar con otra cuenta.
    private(set) var foreignPendingCount = 0
    var selectedTab: AppTab = .today
    var todayPath: [String] = []
    var alertMessage: String?

    private let identity: IdentityStore?
    private let store: LocalStore?
    private let api: APIClient?
    private let sync: SyncEngine?
    private let scheduler = ReminderScheduler()
    private let push: PushRegistration?
    private(set) var pushDiagnostic = "Avisos remotos sin configurar."
    private var pendingCredentialsUID: String?
    private var sessionGeneration = 0
    private var retryTask: Task<Void, Never>?
    private var retryDelay: Duration = .seconds(15)
    private let pathMonitor = NWPathMonitor()

    init() {
        var failure = SessionPhase.loading
        var parts: (IdentityStore, LocalStore, APIClient, SyncEngine)?
        do {
            let config = try AppConfig.load()
            do {
                let transport = URLSessionTransport()
                let identity = IdentityStore(client: FirebaseIdentityClient(config: config, transport: transport), secrets: KeychainStore())
                let store = try LocalStore(directory: LocalStore.defaultDirectory())
                let api = APIClient(baseURL: config.apiBaseURL, transport: transport, tokens: identity)
                parts = (identity, store, api, SyncEngine(api: api, store: store))
            } catch {
                failure = .storageUnavailable
            }
        } catch {
            failure = .misconfigured
        }
        identity = parts?.0
        store = parts?.1
        api = parts?.2
        push = parts.map { PushRegistration(api: $0.2) }
        sync = parts?.3
        phase = failure
    }

    init(identity: IdentityStore, store: LocalStore, api: APIClient, sync: SyncEngine) {
        self.identity = identity
        self.store = store
        self.api = api
        self.sync = sync
        push = nil
    }

    // MARK: Ciclo de vida

    func start() async {
        guard phase == .loading, let identity else { return }
        NotificationRouter.shared.connect { [weak self] dose in self?.open(dose: dose) }
        RemotePush.shared.onChange = { [weak self] in Task { await self?.refreshPush() } }
        watchNetwork()
        // Una decisión pendiente sobre otra cuenta puede haber quedado abierta al cerrar la app:
        // sin este control, sus registros se enviarían con la identidad nueva.
        guard let uid = await identity.uid else {
            phase = .signedOut
            return
        }
        await enter(uid: uid)
    }

    func becameActive() async {
        guard phase == .signedIn else {
            await refreshReminderStatus()
            return
        }
        await syncNow()
    }

    private func watchNetwork() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in
                guard let self, self.phase == .signedIn, self.syncProblem == .transport else { return }
                await self.syncNow()
            }
        }
        pathMonitor.start(queue: .global(qos: .utility))
    }

    // MARK: Sesión

    func signIn(email: String, password: String, register: Bool = false) async -> String? {
        guard phase == .signedOut || phase == .expired, let identity else { return nil }
        let generation = sessionGeneration
        await sync?.stop()
        guard generation == sessionGeneration else { return IdentityError.sessionExpired.message }
        do {
            let uid = try await identity.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password, register: register)
            guard generation == sessionGeneration else { return IdentityError.sessionExpired.message }
            await enter(uid: uid)
            return nil
        } catch let error as IdentityError {
            return error.message
        } catch {
            return "No se pudo iniciar sesión. Intenta nuevamente."
        }
    }

    private func enter(uid: String) async {
        guard let store else { return }
        do {
            switch try await store.claim(ownerUID: uid) {
            case .ready:
                await completeSignIn()
            case let .otherOwnerHasPending(count):
                // Nada se borra hasta que la persona lo decida en pantalla.
                pendingCredentialsUID = uid
                foreignPendingCount = count
                phase = .signedOut
            }
        } catch {
            phase = .signedOut
            alertMessage = "No se pudieron abrir los datos de este dispositivo."
        }
    }

    func discardForeignPendingAndContinue() async {
        guard let store, let uid = pendingCredentialsUID else { return }
        do {
            _ = try await store.claim(ownerUID: uid, discardingOtherOwner: true)
            pendingCredentialsUID = nil
            foreignPendingCount = 0
            await scheduler.removeAll()
            await completeSignIn()
        } catch {
            alertMessage = "No se pudieron descartar los registros."
        }
    }

    func cancelForeignSignIn() async {
        await identity?.signOut()
        pendingCredentialsUID = nil
        foreignPendingCount = 0
    }

    private func completeSignIn() async {
        sessionGeneration += 1
        await sync?.resume()
        await scheduler.resume()
        phase = .signedIn
        push?.signedIn()
        syncProblem = nil
        await refreshLocal()
        await syncNow()
    }

    /// Borra sesión, caché, cola y recordatorios de este dispositivo.
    func signOut() async {
        guard phase != .signingOut else { return }
        guard let store, let identity else {
            alertMessage = "No se pudo abrir el almacenamiento para borrar los datos. Reinicia la app y revisa el espacio disponible. El borrado no se ha completado."
            return
        }
        phase = .signingOut
        sessionGeneration += 1
        snapshot = LocalSnapshot()
        patients = [:]; accesses = []; families = nil; allOperations = []; profile = nil; patientPath = []
        email = ""; caregiverPreference = nil
        retryTask?.cancel()
        await sync?.stop()
        let removedPush = if let uid = await identity.uid { await push?.signOut(owner: uid) ?? true } else { true }
        await scheduler.removeAll()
        var cleanupFailed = false
        do { try await store.wipe() } catch { cleanupFailed = true }
        if await identity.signOut() == false { cleanupFailed = true }
        snapshot = LocalSnapshot()
        patients = [:]; accesses = []; families = nil; allOperations = []; profile = nil; patientPath = []
        email = ""; caregiverPreference = nil
        isSyncing = false
        reminders = ReminderDiagnostic()
        syncProblem = nil
        todayPath = []
        selectedTab = .today
        phase = cleanupFailed ? .storageUnavailable : .signedOut
        if cleanupFailed { alertMessage = "La sesión se cerró, pero no se pudieron borrar los datos locales. Intenta borrar nuevamente desde esta pantalla." }
        if !removedPush && !cleanupFailed { alertMessage = "La sesión se cerró. No se pudo desactivar el registro remoto en el servidor; podría llegar un aviso genérico hasta que venza." }
    }

    // MARK: Sincronización

    func syncNow() async {
        guard phase == .signedIn, let sync else { return }
        let generation = sessionGeneration
        isSyncing = true
        let outcome = await sync.sync()
        guard generation == sessionGeneration, phase == .signedIn else { return }
        isSyncing = false
        await handle(outcome)
        await refreshLocal()
        await refreshFamilies(generation: generation)
        await refreshPush()
    }

    /// La familia exige red para cambiar, así que no se guarda en disco. Sin conexión se conserva lo ya leído.
    private func refreshFamilies(generation: Int) async {
        guard let api, let loaded = try? await api.families(), generation == sessionGeneration, phase == .signedIn else { return }
        families = loaded
    }

    private func refreshPush() async {
        guard phase == .signedIn, let uid = await identity?.uid, let push else { return }
        await push.reconcile(owner: uid)
        pushDiagnostic = push.diagnostic
    }

    private func handle(_ outcome: SyncOutcome) async {
        retryTask?.cancel()
        switch outcome {
        case .synced:
            syncProblem = nil
            retryDelay = .seconds(15)
        case let .unavailable(problem):
            syncProblem = problem
            scheduleRetry()
        case .sessionExpired:
            let generation = sessionGeneration
            await sync?.stop()
            guard generation == sessionGeneration, phase == .signedIn else { return }
            syncProblem = .unauthenticated
            phase = .expired
        }
    }

    private func scheduleRetry() {
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, .seconds(300))
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    private func refreshLocal() async {
        guard phase == .signedIn, let store else { return }
        let generation = sessionGeneration
        do {
            let me = try await store.profile()
            let loadedAccesses = try await store.accesses()
            var loaded: [String: LocalSnapshot] = [:]
            for access in loadedAccesses { loaded[access.patientID] = try await store.snapshot(patient: access.patientID) }
            let operations = try await store.operations()
            let storedEmail = await identity?.email ?? ""
            let preference = await identity?.caregiverPreference
            guard generation == sessionGeneration, phase == .signedIn else { return }
            profile = me; accesses = loadedAccesses; allOperations = operations
            snapshot = me.flatMap { loaded.removeValue(forKey: $0.userID) } ?? LocalSnapshot()
            patients = loaded; email = storedEmail; caregiverPreference = preference
            if !tabs.contains(selectedTab) { selectedTab = tabs[0] }
            if let selected = patientPath.first, patients[selected] == nil { patientPath = [] }
        } catch { alertMessage = "No se pudieron leer las agendas guardadas." }
        await reconcileReminders()
    }

    private func reconcileReminders() async {
        guard phase == .signedIn else { return }
        let now = Date.now
        let plan = ReminderPlanner.plan(patient: snapshot.access?.patientID, actor: profile?.userID, doses: snapshot.doses, operations: snapshot.operations, now: now)
        reminders = await scheduler.reconcile(plan: plan, now: now)
    }

    func refreshReminderStatus() async {
        reminders.permission = await scheduler.permission()
    }

    func requestReminderPermission() async {
        _ = await scheduler.requestPermission()
        await reconcileReminders()
        await refreshPush()
    }

    // MARK: Declaraciones

    func declare(_ declaration: Declaration, dose: Dose, occurredAt: Date? = nil, patient: String? = nil) async {
        guard let patient = patient ?? profile?.userID, permits("doses", patient: patient) else { return }
        await enqueue { try OperationFactory.declaration(declaration, dose: dose, occurredAt: occurredAt, now: .now, patient: patient) }
    }

    func correct(dose: Dose, to declaration: Declaration, occurredAt: Date?, reason: String, patient: String? = nil) async {
        guard let patient = patient ?? profile?.userID, permits("doses", patient: patient) else { return }
        guard let event = dose.eventID else { return }
        await enqueue { try OperationFactory.correction(declaration, dose: dose, eventID: event, occurredAt: occurredAt, reason: reason, now: .now, patient: patient) }
    }

    private func enqueue(_ make: () throws -> PendingOperation) async {
        guard phase == .signedIn, let store else { return }
        do {
            try await store.enqueue(make())
        } catch {
            alertMessage = "No se pudo guardar el registro en este dispositivo. Intenta nuevamente."
            return
        }
        await refreshLocal()
        await drainAfterChange()
    }

    private func drainAfterChange() async {
        guard phase == .signedIn, let sync else { return }
        let generation = sessionGeneration
        isSyncing = true
        let outcome = await sync.sync()
        guard generation == sessionGeneration, phase == .signedIn else { return }
        isSyncing = false
        await handle(outcome)
        await refreshLocal()
    }

    // MARK: Conflictos

    func discard(_ operation: PendingOperation) async {
        guard phase == .signedIn, let store else { return }
        try? await store.discardOperation(operation.id)
        await syncNow()
    }

    /// La dosis sigue sin declaración: se registra de nuevo con la versión vigente e identidad nueva.
    func redeclare(_ operation: PendingOperation, dose: Dose, occurredAt: Date?) async {
        await replace(operation) { try OperationFactory.declaration(operation.declaration, dose: dose, occurredAt: occurredAt, now: .now, patient: operation.patientID) }
    }

    /// El servidor ya tiene otra declaración: la de este dispositivo pasa a ser una corrección auditable.
    func convertToCorrection(_ operation: PendingOperation, dose: Dose, reason: String) async {
        guard let event = dose.eventID else { return }
        let occurred = operation.occurredAt.flatMap(Instant.parse)
        await replace(operation) { try OperationFactory.correction(operation.declaration, dose: dose, eventID: event, occurredAt: occurred, reason: reason, now: .now, patient: operation.patientID) }
    }

    private func replace(_ operation: PendingOperation, _ make: () throws -> PendingOperation) async {
        guard phase == .signedIn, let store else { return }
        do {
            try await store.replaceOperation(operation.id, with: make())
        } catch {
            alertMessage = "No se pudo guardar el registro en este dispositivo. Intenta nuevamente."
            return
        }
        await refreshLocal()
        await drainAfterChange()
    }

    // MARK: Historial

    /// Amplía la caché hacia atrás. La API admite 30 días por consulta.
    func loadHistory(from: Date, to: Date, patient: String? = nil) async -> String? {
        guard phase == .signedIn, let sync, let patient = patient ?? profile?.userID else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: patientSnapshot(patient)?.access?.timezone ?? "America/Santiago") ?? .current
        let generation = sessionGeneration
        let outcome = await sync.loadHistory(patient: patient, from: LocalDay.string(from, calendar: calendar), to: LocalDay.string(to, calendar: calendar))
        guard generation == sessionGeneration, phase == .signedIn else { return nil }
        switch outcome {
        case .synced:
            await refreshLocal()
            return nil
        case .sessionExpired:
            await handle(outcome)
            return APIError.unauthenticated.message
        case let .unavailable(error):
            await handle(outcome)
            await refreshLocal()
            return error.message
        }
    }

    // MARK: Consentimiento

    func preview(invitation token: String) async throws -> FamilyInvitationPreview {
        guard phase == .signedIn, let api else { throw APIError.unauthenticated }
        return try await request { try await api.previewInvitation(token: FamilyText.token(token)) }
    }

    func accept(invitation token: String, operationID: String) async throws {
        guard phase == .signedIn, let api else { throw APIError.unauthenticated }
        _ = try await request { try await api.acceptInvitation(token: FamilyText.token(token), operationID: operationID) }
        await syncNow()
    }

    func createFamily(name: String, operation: String) async throws {
        guard let api else { throw APIError.unauthenticated }
        _ = try await request { try await api.createFamily(name: name, operation: operation) }
        await syncNow()
    }

    func invite(family: String, role: FamilyRole, hint: String) async throws -> CreatedInvitation {
        guard let api else { throw APIError.unauthenticated }
        return try await request { try await api.invite(family: family, role: role, hint: hint) }
    }

    /// Salir de la familia o, para quien administra, quitar a otra persona.
    func removeMember(family: String, user: String) async throws {
        guard let api else { throw APIError.unauthenticated }
        try await request { try await api.removeMember(family: family, user: user) }
        await syncNow()
    }

    func patientSnapshot(_ id: String) -> LocalSnapshot? { id == profile?.userID ? snapshot : patients[id] }
    func permits(_ scope: String, patient: String) -> Bool {
        patient == profile?.userID || accesses.first { $0.patientID == patient }?.permits(scope) == true
    }
    func setUse(caregiver: Bool) async {
        do { try await identity?.setUse(caregiver: caregiver); await refreshLocal() }
        catch { alertMessage = "No se pudo guardar la preferencia." }
    }
    func resetPassword(email: String) async throws { try await identity?.resetPassword(email: email) }
    func updateProfile(patient: String, name: String, version: Int, operation: String) async throws {
        guard let api else { throw APIError.unauthenticated }
        try await request(patient: patient) { try await api.updateProfile(patient: patient == profile?.userID ? nil : patient, name: name, version: version, operation: operation) }
        await syncNow()
    }
    func movements(patient: String, account: String) async throws -> [InventoryMovement] {
        guard let api else { throw APIError.unauthenticated }
        return try await request(patient: patient) { try await api.movements(account: account) }
    }
    func inventoryMutation(patient: String, account: String, quantity: String, count: Bool, reason: String, expected: String, operation: String) async throws {
        guard let api else { throw APIError.unauthenticated }
        try await request(patient: patient) { try await api.inventoryMutation(account: account, quantity: quantity, count: count, reason: reason, expected: expected, operation: operation) }
        await syncNow()
    }
    func exportAccount() async throws -> Data {
        guard let api else { throw APIError.unauthenticated }
        return try await request { try await api.exportAccount() }
    }
    /// Con la identidad aún activa conserva la sesión, para que la persona pueda reintentar.
    func deleteAccount(operation: String) async throws -> Bool {
        guard let api else { throw APIError.unauthenticated }
        let removed = try await request { try await api.deleteAccount(operation: operation) }
        if removed { await signOut() }
        return removed
    }
    func poolCandidates(account: String) async throws -> [PoolCandidate] {
        guard let api else { throw APIError.unauthenticated }
        return try await request { try await api.poolCandidates(account: account) }
    }
    /// El saldo común parte de lo contado: sumar dos saldos de una misma caja la contaría dos veces.
    func sharePool(accounts: [String], counted account: String, quantity: String, operation: String) async throws {
        guard let api else { throw APIError.unauthenticated }
        try await request { try await api.createPool(accounts: accounts, counted: account, quantity: quantity, operation: operation) }
        await syncNow()
    }
    func leavePool(id: String, account: String, operation: String) async throws {
        guard let api else { throw APIError.unauthenticated }
        try await request { try await api.leavePool(id: id, account: account, operation: operation) }
        await syncNow()
    }
    private func request<T>(patient: String? = nil, _ body: () async throws -> T) async throws -> T {
        guard phase == .signedIn else { throw APIError.unauthenticated }
        let generation = sessionGeneration
        do {
            let result = try await body()
            guard generation == sessionGeneration, phase == .signedIn else { throw APIError.unauthenticated }
            return result
        } catch {
            guard generation == sessionGeneration else { throw error }
            if error as? APIError == .unauthenticated {
                await sync?.stop()
                guard generation == sessionGeneration else { throw error }
                phase = .expired
            }
            if error as? APIError == .denied, let patient {
                _ = await sync?.deny(patient: patient)
                guard generation == sessionGeneration else { throw error }
                await refreshLocal()
            }
            guard generation == sessionGeneration else { throw error }
            if let problem = error as? APIError { syncProblem = problem }
            throw error
        }
    }

    // MARK: Navegación

    func open(dose: String) {
        guard snapshot.doses.contains(where: { $0.id == dose }) else { return }
        selectedTab = .today
        todayPath = [dose]
    }

    // MARK: Consultas de presentación

    func operation(for dose: Dose) -> PendingOperation? {
        snapshot.operations.first { $0.doseID == dose.id }
    }

    func treatment(for dose: Dose) -> Treatment? {
        snapshot.treatments.first { $0.id == dose.treatmentID }
    }

    func account(for treatmentID: String) -> InventoryProjection? {
        snapshot.inventory.first { $0.treatmentID == treatmentID }
    }

    func dose(id: String) -> Dose? {
        snapshot.doses.first { $0.id == id }
    }

    var waitingOperationsCount: Int {
        allOperations.filter { $0.status == .pending }.count
    }

    var unresolvedOperations: [PendingOperation] {
        allOperations.filter { $0.status != .pending }
    }
}
