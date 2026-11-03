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
    case today, history, settings
}

@Observable
@MainActor
final class AppModel {
    private(set) var phase: SessionPhase = .loading
    private(set) var snapshot = LocalSnapshot()
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

    func signIn(email: String, password: String) async -> String? {
        guard phase == .signedOut || phase == .expired, let identity else { return nil }
        let generation = sessionGeneration
        do {
            let uid = try await identity.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
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
        retryTask?.cancel()
        await sync?.stop()
        let removedPush = if let uid = await identity.uid { await push?.signOut(owner: uid) ?? true } else { true }
        await scheduler.removeAll()
        var cleanupFailed = false
        do { try await store.wipe() } catch { cleanupFailed = true }
        if await identity.signOut() == false { cleanupFailed = true }
        snapshot = LocalSnapshot()
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
        handle(outcome)
        await refreshLocal()
        await refreshPush()
    }

    private func refreshPush() async {
        guard phase == .signedIn, let uid = await identity?.uid, let push else { return }
        await push.reconcile(owner: uid)
        pushDiagnostic = push.diagnostic
    }

    private func handle(_ outcome: SyncOutcome) {
        retryTask?.cancel()
        switch outcome {
        case .synced:
            syncProblem = nil
            retryDelay = .seconds(15)
        case let .unavailable(problem):
            syncProblem = problem
            scheduleRetry()
        case .sessionExpired:
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
        let fresh = try? await store.snapshot()
        guard generation == sessionGeneration, phase == .signedIn else { return }
        if let fresh { snapshot = fresh }
        await reconcileReminders()
    }

    private func reconcileReminders() async {
        guard phase == .signedIn else { return }
        let now = Date.now
        let plan = ReminderPlanner.plan(doses: snapshot.doses, operations: snapshot.operations, now: now)
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

    func declare(_ declaration: Declaration, dose: Dose, occurredAt: Date? = nil) async {
        await enqueue { try OperationFactory.declaration(declaration, dose: dose, occurredAt: occurredAt, now: .now) }
    }

    func correct(dose: Dose, to declaration: Declaration, occurredAt: Date?, reason: String) async {
        guard let event = dose.eventID else { return }
        await enqueue { try OperationFactory.correction(declaration, dose: dose, eventID: event, occurredAt: occurredAt, reason: reason, now: .now) }
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
        let outcome = await sync.drain()
        guard generation == sessionGeneration, phase == .signedIn else { return }
        isSyncing = false
        handle(outcome)
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
        await replace(operation) { try OperationFactory.declaration(operation.declaration, dose: dose, occurredAt: occurredAt, now: .now) }
    }

    /// El servidor ya tiene otra declaración: la de este dispositivo pasa a ser una corrección auditable.
    func convertToCorrection(_ operation: PendingOperation, dose: Dose, reason: String) async {
        guard let event = dose.eventID else { return }
        let occurred = operation.occurredAt.flatMap(Instant.parse)
        await replace(operation) { try OperationFactory.correction(operation.declaration, dose: dose, eventID: event, occurredAt: occurred, reason: reason, now: .now) }
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
    func loadHistory(from: Date, to: Date) async -> String? {
        guard phase == .signedIn, let sync else { return nil }
        let generation = sessionGeneration
        let outcome = await sync.loadHistory(from: LocalDay.string(from), to: LocalDay.string(to))
        guard generation == sessionGeneration, phase == .signedIn else { return nil }
        switch outcome {
        case .synced:
            await refreshLocal()
            return nil
        case .sessionExpired:
            handle(outcome)
            return APIError.unauthenticated.message
        case let .unavailable(error): return error.message
        }
    }

    // MARK: Consentimiento

    func preview(invitation token: String) async throws -> InvitationPreview {
        guard phase == .signedIn, let api else { throw APIError.unauthenticated }
        return try await api.previewInvitation(token: token)
    }

    func accept(invitation token: String, operationID: String) async throws {
        guard phase == .signedIn, let api else { throw APIError.unauthenticated }
        _ = try await api.acceptInvitation(token: token, operationID: operationID)
        await syncNow()
    }

    func revoke(_ link: CaregiverLink) async throws {
        guard phase == .signedIn, let api else { throw APIError.unauthenticated }
        try await api.revoke(link: link.id)
        await syncNow()
    }

    // MARK: Navegación

    func open(dose: String) {
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
        snapshot.operations.filter { $0.status == .pending }.count
    }

    var unresolvedOperations: [PendingOperation] {
        snapshot.operations.filter { $0.status != .pending }
    }
}
