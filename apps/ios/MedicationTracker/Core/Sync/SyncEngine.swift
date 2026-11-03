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
            return await drainQueue()
        }
        current = task
        return await task.value
    }

    /// Espera a que termine lo que esté en curso, para que nada escriba tras borrar los datos locales.
    func finishCurrent() async {
        _ = await current?.value
    }

    private func run() async -> SyncOutcome {
        let drained = await drainQueue()
        guard drained == .synced else { return drained }
        do {
            let patient = try await resolvePatient()
            let now = calendarNow()
            let (from, to) = Self.window(now: now)
            async let treatments = api.treatments(patient: patient)
            async let doses = api.doses(patient: patient, from: from, to: to)
            async let inventory = api.inventory(patient: patient)
            async let links = api.links()
            let (loadedTreatments, loadedDoses, loadedInventory, loadedLinks) = try await (treatments, doses, inventory, links)
            try await store.replaceTreatments(loadedTreatments)
            try await store.replaceAgenda(loadedDoses, from: from, to: to, at: now)
            try await store.replaceInventory(loadedInventory)
            // El endpoint también lista vínculos revocados y aquellos donde esta cuenta es cuidadora.
            try await store.replaceLinks(loadedLinks.filter { $0.patientID == patient && $0.status == "active" })
            return .synced
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
        for operation in operations {
            do {
                try await store.markAttempt(operation.id)
                let result = try await api.submit(operation)
                try await store.apply(result, for: operation)
            } catch APIError.conflict {
                try? await store.mark(operation.id, status: .conflict)
            } catch APIError.invalid {
                try? await store.mark(operation.id, status: .rejected)
            } catch APIError.denied {
                try? await store.mark(operation.id, status: .denied)
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

    private func resolvePatient() async throws -> String {
        if let known = try await store.patientID() { return known }
        let me = try await api.me()
        try await store.setPatientID(me.userID)
        return me.userID
    }

    private func classify(_ error: Error) -> SyncOutcome {
        switch error as? APIError {
        case .unauthenticated: .sessionExpired
        case let known?: .unavailable(known)
        case nil: .unavailable(.server)
        }
    }

    /// Fechas locales del dispositivo. Una dosis de otra zona queda cubierta por el margen de la ventana.
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
