import Foundation

enum SyncOutcome: Sendable, Equatable {
    case synced
    /// Sin red o servidor no disponible. Las operaciones siguen en la cola.
    case unavailable(APIError)
    case sessionExpired
}

struct SyncRefresh: Sendable {
    let outcome: SyncOutcome
    var families: [Family]? = nil
    var sequence: UInt64 = 0
}

/// Envía la cola y luego refresca la caché. Las ejecuciones se encadenan para que un refresco
/// nunca se cruce con la aplicación de una operación.
actor SyncEngine {
    private let api: APIClient
    private let store: LocalStore
    private let calendarNow: @Sendable () -> Date
    private var current: Task<SyncOutcome, Never>?
    private var syncSequence: UInt64 = 0
    private var queuedSync: (id: UUID, task: Task<SyncRefresh, Never>)?
    private var stopped = false
    private var ownerUID: String?
    private var inventoryDue = Set<String>()
    private var reportsDue = Set<String>()
    private var snapshotsDue = Set<String>()
    private var conflictDaysDue: [String: Set<String>] = [:]

    /// Días que se piden a la API. El contrato admite como máximo 30 por consulta.
    static let daysBack = 7
    static let daysAhead = 21
    private static let maxConcurrentPatients = 4

    init(api: APIClient, store: LocalStore, now: @escaping @Sendable () -> Date = { .now }) {
        self.api = api
        self.store = store
        calendarNow = now
    }

    func sync() async -> SyncOutcome {
        await syncWithFamilies().outcome
    }

    func syncWithFamilies() async -> SyncRefresh {
        guard !stopped else { return SyncRefresh(outcome: .sessionExpired) }
        if let queuedSync { return await queuedSync.task.value }
        let previous = current
        let id = UUID()
        syncSequence += 1
        let sequence = syncSequence
        let task = Task {
            _ = await previous?.value
            if queuedSync?.id == id { queuedSync = nil }
            guard !stopped else { return SyncRefresh(outcome: .sessionExpired) }
            return await run(sequence: sequence)
        }
        queuedSync = (id, task)
        current = Task { await task.value.outcome }
        return await task.value
    }

    private enum Selection: Sendable {
        case declarations
        case profiles
        case membership
        case inventory(patients: Set<String>, accounts: Set<String>, pools: Set<String>)
    }

    func refreshDeclarations() async -> SyncRefresh { await refreshSelected(.declarations) }
    func refreshProfiles() async -> SyncRefresh { await refreshSelected(.profiles) }
    func refreshMembership() async -> SyncRefresh { await refreshSelected(.membership) }
    func refreshInventory(patient: String? = nil, accounts: [String] = [], pools: [String] = []) async -> SyncRefresh {
        await refreshSelected(.inventory(patients: Set(patient.map { [$0] } ?? []), accounts: Set(accounts), pools: Set(pools)))
    }

    private func refreshSelected(_ selection: Selection) async -> SyncRefresh {
        guard !stopped else { return SyncRefresh(outcome: .sessionExpired) }
        queuedSync = nil
        let previous = current
        syncSequence += 1
        let sequence = syncSequence
        let task = Task {
            _ = await previous?.value
            guard !stopped else { return SyncRefresh(outcome: .sessionExpired) }
            return await runSelected(selection, sequence: sequence)
        }
        current = Task { await task.value.outcome }
        return await task.value
    }

    /// Sólo envía la cola. Sirve para el envío inmediato tras registrar una declaración.
    func drain() async -> SyncOutcome {
        guard !stopped else { return .sessionExpired }
        queuedSync = nil
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
        guard !stopped else { return .sessionExpired }
        queuedSync = nil
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

    func resume(ownerUID: String? = nil) {
        if let ownerUID, self.ownerUID != ownerUID {
            clearRefreshes()
            self.ownerUID = ownerUID
        }
        stopped = false
    }

    private func clearRefreshes() {
        inventoryDue.removeAll()
        reportsDue.removeAll()
        snapshotsDue.removeAll()
        conflictDaysDue.removeAll()
    }

    func stop(discardRefreshes: Bool = false) async {
        stopped = true
        queuedSync = nil
        _ = await current?.value
        if discardRefreshes { clearRefreshes() }
    }

    func loadHistory(patient: String, from: String, to: String) async -> SyncOutcome {
        guard !stopped else { return .sessionExpired }
        queuedSync = nil
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

    private struct PatientRefresh: Sendable {
        let treatments: [Treatment]
        let doses: [Dose]
        let inventory: [InventoryProjection]
        let report: DailyReport?
        let from: String
        let to: String
        let at: Date
    }

    private func run(sequence: UInt64) async -> SyncRefresh {
        let drained = await drainQueue()
        guard drained == .synced || drained == .unavailable(.denied) else {
            let families = drained == .sessionExpired ? nil : try? await api.families()
            return SyncRefresh(outcome: drained, families: families, sequence: sequence)
        }
        var families: [Family]?
        do {
            async let meRequest = api.me()
            async let accessRequest = api.patients()
            async let familyRequest = try? api.families()
            families = await familyRequest
            let (me, accesses) = try await (meRequest, accessRequest)
            try await store.saveProfile(me)
            let allowed = Set(accesses.map(\.patientID))
            inventoryDue = try await inventoryPatients(patients: inventoryDue)
            inventoryDue.formIntersection(allowed)
            reportsDue.formIntersection(allowed)
            snapshotsDue.formIntersection(allowed)
            var denied = drained == .unavailable(.denied)
            for saved in try await store.accesses() where !allowed.contains(saved.patientID) {
                try await store.deny(patient: saved.patientID)
                denied = true
            }
            let results = await readPatients(accesses, owner: me.userID)
            denied = try await applyPatients(results, accesses: accesses) || denied
            denied = try await refreshConflictedDoses() || denied
            return SyncRefresh(outcome: denied ? .unavailable(.denied) : .synced, families: families, sequence: sequence)
        } catch {
            let outcome = classify(error)
            return SyncRefresh(outcome: outcome, families: outcome == .sessionExpired ? nil : families, sequence: sequence)
        }
    }

    private func readPatients(_ accesses: [PatientAccess], owner: String) async -> [String: Result<PatientRefresh, APIError>] {
        let now = calendarNow()
        let api = api
        return await withTaskGroup(of: (String, Result<PatientRefresh, APIError>).self) { group in
            var next = 0
            func addPatient(_ access: PatientAccess) {
                group.addTask { (access.patientID, await Self.readPatient(access, owner: owner, now: now, api: api)) }
            }
            while next < min(Self.maxConcurrentPatients, accesses.count) { addPatient(accesses[next]); next += 1 }
            var results: [String: Result<PatientRefresh, APIError>] = [:]
            for await (patient, result) in group {
                results[patient] = result
                if next < accesses.count { addPatient(accesses[next]); next += 1 }
            }
            return results
        }
    }

    private static func readPatient(_ access: PatientAccess, owner: String, now: Date, api: APIClient) async -> Result<PatientRefresh, APIError> {
        do {
            let patient = access.patientID
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: access.timezone) ?? .current
            let (from, to) = Self.window(now: now, calendar: calendar)
            let today = calendar.startOfDay(for: now)
            let reportFrom = LocalDay.string(today, calendar: calendar)
            let reportTo = LocalDay.string(calendar.date(byAdding: .day, value: 1, to: today)!, calendar: calendar)
            async let treatments = capture { try await api.treatments(patient: patient) }
            async let doses = capture { try await api.doses(patient: patient, from: from, to: to) }
            async let inventory = capture { try await api.inventory(patient: patient) }
            async let report: Result<DailyReport?, APIError> = capture { patient == owner ? nil : try await api.report(patient: patient, from: reportFrom, to: reportTo) }
            let values = await (treatments, doses, inventory, report)
            let errors = [failure(values.0), failure(values.1), failure(values.2), failure(values.3)].compactMap { $0 }
            if let error = preferredError(errors) { return .failure(error) }
            return try .success(PatientRefresh(treatments: values.0.get(), doses: values.1.get(), inventory: values.2.get(), report: values.3.get(), from: from, to: to, at: now))
        } catch { return .failure(error) }
    }

    private static func capture<Value: Sendable>(_ read: @Sendable () async throws -> Value) async -> Result<Value, APIError> {
        do { return .success(try await read()) }
        catch { return .failure(error as? APIError ?? .server) }
    }

    private static func failure<Value>(_ result: Result<Value, APIError>) -> APIError? {
        if case let .failure(error) = result { return error }
        return nil
    }

    private static func preferredError(_ errors: [APIError]) -> APIError? {
        if errors.contains(.unauthenticated) { return .unauthenticated }
        if errors.contains(.denied) { return .denied }
        return errors.first
    }

    private func applyPatients(_ results: [String: Result<PatientRefresh, APIError>], accesses: [PatientAccess]) async throws -> Bool {
        var denied = false
        for access in accesses {
            guard let result = results[access.patientID], Self.failure(result) == .denied else { continue }
            try await store.deny(patient: access.patientID)
            inventoryDue.remove(access.patientID); reportsDue.remove(access.patientID); snapshotsDue.remove(access.patientID)
            conflictDaysDue.removeValue(forKey: access.patientID)
            denied = true
        }
        if results.values.contains(where: { Self.failure($0) == .unauthenticated }) { throw APIError.unauthenticated }
        for access in accesses {
            guard let result = results[access.patientID], Self.failure(result) != .denied else { continue }
            let value = try result.get()
            try await store.replaceTreatments(value.treatments, patient: access.patientID)
            try await store.replaceAgenda(value.doses, from: value.from, to: value.to, at: value.at, patient: access.patientID)
            try await store.replaceInventory(value.inventory, patient: access.patientID)
            try await store.saveAccess(access, report: value.report)
            inventoryDue.remove(access.patientID); reportsDue.remove(access.patientID); snapshotsDue.remove(access.patientID)
        }
        return denied
    }

    private func refreshConflictedDoses() async throws -> Bool {
        var denied = false
        for patient in conflictDaysDue.keys.sorted() {
            let access = try await store.snapshot(patient: patient).access
            guard let access else { conflictDaysDue.removeValue(forKey: patient); continue }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: access.timezone) ?? .current
            for day in conflictDaysDue[patient, default: []].sorted() {
                let parts = day.split(separator: "-").compactMap { Int($0) }
                guard parts.count == 3,
                      let from = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
                      let to = calendar.date(byAdding: .day, value: 1, to: from) else { throw APIError.decoding }
                do {
                    let doses = try await api.doses(patient: patient, from: day, to: LocalDay.string(to, calendar: calendar))
                    try await store.mergeDoses(doses, patient: patient)
                    conflictDaysDue[patient]?.remove(day)
                } catch APIError.denied {
                    try await store.deny(patient: patient)
                    conflictDaysDue.removeValue(forKey: patient)
                    inventoryDue.remove(patient); reportsDue.remove(patient); snapshotsDue.remove(patient)
                    denied = true
                    break
                }
            }
            if conflictDaysDue[patient]?.isEmpty == true { conflictDaysDue.removeValue(forKey: patient) }
        }
        return denied
    }

    private struct Directory: Sendable {
        let me: Me
        let accesses: [PatientAccess]
        let families: [Family]
    }

    private func readDirectory() async throws -> Directory {
        async let me = api.me()
        async let accesses = api.patients()
        async let families = api.families()
        return try await Directory(me: me, accesses: accesses, families: families)
    }

    private func runSelected(_ selection: Selection, sequence: UInt64) async -> SyncRefresh {
        do {
            if case let .inventory(patients, accounts, pools) = selection {
                inventoryDue.formUnion(try await inventoryPatients(patients: patients, accounts: accounts, pools: pools))
            }
        } catch { return SyncRefresh(outcome: classify(error), sequence: sequence) }
        let drained = await drainQueue()
        guard drained == .synced || drained == .unavailable(.denied) else { return SyncRefresh(outcome: drained, sequence: sequence) }
        var families: [Family]?
        do {
            var denied = drained == .unavailable(.denied)
            switch selection {
            case .declarations:
                if !snapshotsDue.isEmpty, let me = try await store.profile() {
                    let changed = try await store.accesses().filter { snapshotsDue.contains($0.patientID) }
                    let affected = try await inventoryPatients(patients: Set(changed.map(\.patientID)))
                    let pending = Set(try await store.operations().filter { $0.status == .pending }.map(\.patientID))
                    guard affected.isDisjoint(with: pending) else { return SyncRefresh(outcome: denied ? .unavailable(.denied) : .synced, sequence: sequence) }
                    let results = await readPatients(changed, owner: me.userID)
                    denied = try await applyPatients(results, accesses: changed) || denied
                }
            case .profiles, .membership:
                let previous = Dictionary(uniqueKeysWithValues: try await store.accesses().map { ($0.patientID, $0) })
                let directory = try await readDirectory()
                families = directory.families
                try await store.saveProfile(directory.me)
                let allowed = Set(directory.accesses.map(\.patientID))
                inventoryDue.formIntersection(allowed)
                reportsDue.formIntersection(allowed)
                snapshotsDue.formIntersection(allowed)
                for patient in previous.keys where !allowed.contains(patient) {
                    try await store.deny(patient: patient)
                    denied = true
                }
                var changed: [PatientAccess] = []
                for access in directory.accesses {
                    let old = previous[access.patientID]
                    if old == nil || old?.linkID != access.linkID || old?.timezone != access.timezone || Set(old?.scopes ?? []) != Set(access.scopes) {
                        snapshotsDue.insert(access.patientID)
                    }
                    if snapshotsDue.contains(access.patientID) { changed.append(access) }
                    try await store.saveAccessMetadata(access)
                }
                let changedPatients = try await inventoryPatients(patients: Set(changed.map(\.patientID)))
                let pending = Set(try await store.operations().filter { $0.status == .pending }.map(\.patientID))
                guard changedPatients.isDisjoint(with: pending) else {
                    return SyncRefresh(outcome: denied ? .unavailable(.denied) : .synced, families: families, sequence: sequence)
                }
                let loaded = await readPatients(changed, owner: directory.me.userID)
                denied = try await applyPatients(loaded, accesses: changed) || denied
            case .inventory: break
            }
            denied = try await refreshConflictedDoses() || denied
            let stockOutcome = try await refreshDueInventory()
            if stockOutcome != .synced { return SyncRefresh(outcome: stockOutcome, families: families, sequence: sequence) }
            return SyncRefresh(outcome: denied ? .unavailable(.denied) : .synced, families: families, sequence: sequence)
        } catch {
            let outcome = classify(error)
            return SyncRefresh(outcome: outcome, families: outcome == .sessionExpired ? nil : families, sequence: sequence)
        }
    }

    private func inventoryPatients(patients: Set<String>, accounts: Set<String> = [], pools: Set<String> = []) async throws -> Set<String> {
        var inventories: [String: [InventoryProjection]] = [:]
        for access in try await store.accesses() { inventories[access.patientID] = try await store.snapshot(patient: access.patientID).inventory }
        let knownAccounts = Set(inventories.values.flatMap { $0.map(\.accountID) })
        let knownPools = Set(inventories.values.flatMap { $0.compactMap { $0.pool?.id } })
        if !accounts.isSubset(of: knownAccounts) || !pools.isSubset(of: knownPools) { return Set(inventories.keys).union(patients) }
        var affected = patients
        var shared = pools
        var changed = true
        while changed {
            let previous = affected
            let previousPools = shared
            for (patient, inventory) in inventories {
                if inventory.contains(where: { accounts.contains($0.accountID) || $0.pool.map { shared.contains($0.id) } == true }) { affected.insert(patient) }
                if affected.contains(patient) { shared.formUnion(inventory.compactMap { $0.pool?.id }) }
            }
            changed = affected != previous || shared != previousPools
        }
        return affected
    }

    private func refreshDueInventory() async throws -> SyncOutcome {
        guard !inventoryDue.isEmpty else { return .synced }
        inventoryDue = try await inventoryPatients(patients: inventoryDue)
        let pending = Set(try await store.operations().filter { $0.status == .pending }.map(\.patientID))
        guard inventoryDue.isDisjoint(with: pending) else { return .synced }
        guard let me = try await store.profile() else { return .unavailable(.server) }
        let accesses = Dictionary(uniqueKeysWithValues: try await store.accesses().map { ($0.patientID, $0) })
        var denied = false
        for patient in inventoryDue.sorted() {
            guard let access = accesses[patient] else {
                inventoryDue.remove(patient); reportsDue.remove(patient)
                continue
            }
            do {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: access.timezone) ?? .current
                let today = calendar.startOfDay(for: calendarNow())
                let from = LocalDay.string(today, calendar: calendar)
                let to = LocalDay.string(calendar.date(byAdding: .day, value: 1, to: today)!, calendar: calendar)
                let needsReport = patient != me.userID && reportsDue.contains(patient)
                let api = api
                async let inventory = Self.capture { try await api.inventory(patient: patient) }
                async let report: Result<DailyReport?, APIError> = Self.capture { needsReport ? try await api.report(patient: patient, from: from, to: to) : nil }
                let values = await (inventory, report)
                if let error = Self.preferredError([Self.failure(values.0), Self.failure(values.1)].compactMap { $0 }) { throw error }
                let (stock, summary) = try (values.0.get(), values.1.get())
                try await store.replaceInventory(stock, patient: patient)
                if let summary { try await store.saveAccess(access, report: summary) }
                inventoryDue.remove(patient)
                reportsDue.remove(patient)
            } catch APIError.denied {
                try await store.deny(patient: patient)
                inventoryDue.remove(patient); reportsDue.remove(patient)
                denied = true
            }
        }
        return denied ? .unavailable(.denied) : .synced
    }

    private func drainQueue() async -> SyncOutcome {
        let operations: [PendingOperation]
        do {
            let saved = try await store.operations()
            operations = saved.filter { $0.status == .pending }
            for conflict in saved where conflict.status == .conflict {
                let expected: Int
                if conflict.isCorrection { expected = try JSONDecoder().decode(CorrectionBody.self, from: conflict.body).expectedVersion }
                else { expected = try JSONDecoder().decode(DoseEventBody.self, from: conflict.body).expectedVersion }
                if let dose = try await store.snapshot(patient: conflict.patientID).doses.first(where: { $0.id == conflict.doseID }), dose.version <= expected {
                    conflictDaysDue[conflict.patientID, default: []].insert(dose.localDate)
                    inventoryDue.insert(conflict.patientID); reportsDue.insert(conflict.patientID)
                }
            }
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
                inventoryDue.insert(operation.patientID)
                reportsDue.insert(operation.patientID)
            } catch APIError.conflict {
                try? await store.mark(operation.id, status: .conflict)
                if let dose = try? await store.snapshot(patient: operation.patientID).doses.first(where: { $0.id == operation.doseID }) {
                    conflictDaysDue[operation.patientID, default: []].insert(dose.localDate)
                } else { snapshotsDue.insert(operation.patientID) }
                inventoryDue.insert(operation.patientID)
                reportsDue.insert(operation.patientID)
            } catch APIError.invalid {
                try? await store.mark(operation.id, status: .rejected)
            } catch APIError.denied {
                try? await store.deny(patient: operation.patientID)
                deniedPatients.insert(operation.patientID)
                if outcome == .synced { outcome = .unavailable(.denied) }
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
