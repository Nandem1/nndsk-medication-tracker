import Foundation

enum SyncOutcome: Sendable, Equatable {
    case synced
    /// Sin red o servidor no disponible. Las operaciones siguen en la cola.
    case unavailable(APIError)
    case sessionExpired
}

/// Envía la cola y luego refresca la caché. Las ejecuciones se encadenan para que un refresco
/// nunca se cruce con la aplicación de una operación.
actor SyncEngine {
    private let api: APIClient
    private let store: LocalStore
    private let calendarNow: @Sendable () -> Date
    private var current: Task<SyncOutcome, Never>?
    private var stopped = false

    /// Días que se piden a la API. El contrato admite como máximo 30 por consulta.
    static let daysBack = 7
    static let daysAhead = 21

    init(api: APIClient, store: LocalStore, now: @escaping @Sendable () -> Date = { .now }) {
        self.api = api
        self.store = store
        calendarNow = now
    }

    func sync() async -> SyncOutcome {
        let previous = current
        let task = Task {
            _ = await previous?.value
            guard !stopped else { return SyncOutcome.sessionExpired }
            return await run()
        }
        current = task
        return await task.value
    }

    /// Sólo envía la cola. Sirve para el envío inmediato tras registrar una declaración.
    func drain() async -> SyncOutcome {
        let previous = current
        let task = Task {
            _ = await previous?.value
            guard !stopped else { return SyncOutcome.sessionExpired }
            return await drainQueue()
        }
        current = task
        return await task.value
    }

    func deny(patient: String) async -> SyncOutcome {
        let previous = current
        let task = Task {
            _ = await previous?.value
            guard !stopped else { return SyncOutcome.sessionExpired }
            do { try await store.deny(patient: patient); return .unavailable(.denied) }
            catch { return .unavailable(.server) }
        }
        current = task
        return await task.value
    }

    func resume() { stopped = false }

    func stop() async {
        stopped = true
        _ = await current?.value
    }

    func loadHistory(patient: String, from: String, to: String) async -> SyncOutcome {
        let previous = current
        let task = Task {
            _ = await previous?.value
            guard !stopped else { return SyncOutcome.sessionExpired }
            do {
                let doses = try await api.doses(patient: patient, from: from, to: to)
                try await store.mergeDoses(doses, patient: patient)
                return .synced
            } catch APIError.denied {
                try? await store.deny(patient: patient)
                return .unavailable(.denied)
            } catch { return classify(error) }
        }
        current = task
        return await task.value
    }

    private func run() async -> SyncOutcome {
        let drained = await drainQueue()
        guard drained == .synced || drained == .unavailable(.denied) else { return drained }
        do {
            let me = try await api.me()
            try await store.saveProfile(me)
            let accesses = try await api.patients()
            let allowed = Set(accesses.map(\.patientID))
            var denied = drained == .unavailable(.denied)
            for saved in try await store.accesses() where !allowed.contains(saved.patientID) {
                try await store.deny(patient: saved.patientID)
                denied = true
            }
            let links = try await api.links()
            for access in accesses {
                let patient = access.patientID
                do {
                    let now = calendarNow()
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = TimeZone(identifier: access.timezone) ?? .current
                    let (from, to) = Self.window(now: now, calendar: calendar)
                    let treatments = try await api.treatments(patient: patient)
                    let doses = try await api.doses(patient: patient, from: from, to: to)
                    let inventory = try await api.inventory(patient: patient)
                    let today = calendar.startOfDay(for: now)
                    let report = try await api.report(patient: patient, from: LocalDay.string(today, calendar: calendar), to: LocalDay.string(calendar.date(byAdding: .day, value: 1, to: today)!, calendar: calendar))
                    try await store.replaceTreatments(treatments, patient: patient)
                    try await store.replaceAgenda(doses, from: from, to: to, at: now, patient: patient)
                    try await store.replaceInventory(inventory, patient: patient)
                    try await store.replaceLinks(links.filter { $0.patientID == patient && $0.status == "active" }, patient: patient)
                    try await store.saveAccess(access, report: report)
                } catch APIError.denied { try await store.deny(patient: patient); denied = true }
            }
            return denied ? .unavailable(.denied) : .synced
        } catch {
            return classify(error)
        }
    }

    private func drainQueue() async -> SyncOutcome {
        let operations: [PendingOperation]
        do {
            operations = try await store.operations().filter { $0.status == .pending }
        } catch {
            return .unavailable(.server)
        }
        var outcome = SyncOutcome.synced
        var deniedPatients = Set<String>()
        for operation in operations where !deniedPatients.contains(operation.patientID) {
            do {
                try await store.markAttempt(operation.id)
                let result = try await api.submit(operation)
                try await store.apply(result, for: operation)
            } catch APIError.conflict {
                try? await store.mark(operation.id, status: .conflict)
            } catch APIError.invalid {
                try? await store.mark(operation.id, status: .rejected)
            } catch APIError.denied {
                try? await store.deny(patient: operation.patientID)
                deniedPatients.insert(operation.patientID)
                outcome = .unavailable(.denied)
            } catch APIError.unauthenticated {
                return .sessionExpired
            } catch APIError.transport {
                return .unavailable(.transport)
            } catch {
                // 5xx, 429 o respuesta ilegible: la operación sigue viva y su reintento es idempotente.
                outcome = .unavailable(error as? APIError ?? .server)
            }
        }
        return outcome
    }

    private func classify(_ error: Error) -> SyncOutcome {
        switch error as? APIError {
        case .unauthenticated: .sessionExpired
        case let known?: .unavailable(known)
        case nil: .unavailable(.server)
        }
    }

    /// Ventana de días civiles en la zona del paciente.
    static func window(now: Date, calendar: Calendar = .current) -> (from: String, to: String) {
        let today = calendar.startOfDay(for: now)
        let from = calendar.date(byAdding: .day, value: -daysBack, to: today) ?? today
        let to = calendar.date(byAdding: .day, value: daysAhead, to: today) ?? today
        return (LocalDay.string(from, calendar: calendar), LocalDay.string(to, calendar: calendar))
    }
}

enum LocalDay {
    static func string(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func today(in timezone: String, now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        return string(now, calendar: calendar)
    }
}
