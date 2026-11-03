import Foundation

enum OperationStatus: String, Codable, Sendable {
    /// Espera envío o confirmación del servidor.
    case pending
    /// El servidor respondió 409. Sólo el usuario puede resolverla.
    case conflict
    /// El servidor respondió 400/422. Sólo el usuario puede resolverla.
    case rejected
    /// El servidor respondió 403/404. Sólo el usuario puede resolverla.
    case denied
}

struct PendingOperation: Sendable, Identifiable, Equatable {
    let id: String
    let doseID: String
    let path: String
    /// Bytes exactos del primer intento: la API compara su huella al repetir la operación.
    let body: Data
    let declaration: Declaration
    let occurredAt: String?
    let isCorrection: Bool
    let correctionReason: String?
    /// Efecto del estado que había cuando se registró. Sirve para estimar el saldo.
    let previousStateConsumes: Bool
    let createdAt: Date
    var status: OperationStatus
    var attempts: Int
}

struct LocalSnapshot: Sendable, Equatable {
    var doses: [Dose] = []
    var treatments: [Treatment] = []
    var inventory: [InventoryProjection] = []
    var links: [CaregiverLink] = []
    var operations: [PendingOperation] = []
    var lastSyncAt: Date?
}

enum OwnerCheck: Sendable, Equatable {
    case ready
    /// Quedan declaraciones sin sincronizar de otra cuenta; descartarlas exige una decisión explícita.
    case otherOwnerHasPending(Int)
}

/// Caché de agenda y cola durable. Una ocurrencia admite una sola operación activa.
actor LocalStore {
    private let database: SQLiteConnection

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var location = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try location.setResourceValues(values)
        database = try SQLiteConnection(path: directory.appending(path: "store.sqlite").path(percentEncoded: false))
        try Self.migrate(database)
    }

    static func defaultDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appending(path: "LocalStore")
    }

    private static func migrate(_ database: SQLiteConnection) throws {
        try database.execute("""
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)
        """)
        try database.execute("""
        CREATE TABLE IF NOT EXISTS doses(id TEXT PRIMARY KEY, local_date TEXT NOT NULL, scheduled_at REAL NOT NULL, version INTEGER NOT NULL, payload BLOB NOT NULL)
        """)
        try database.execute("CREATE TABLE IF NOT EXISTS treatments(id TEXT PRIMARY KEY, payload BLOB NOT NULL)")
        try database.execute("CREATE TABLE IF NOT EXISTS inventory(id TEXT PRIMARY KEY, treatment_id TEXT NOT NULL, payload BLOB NOT NULL)")
        try database.execute("CREATE TABLE IF NOT EXISTS links(id TEXT PRIMARY KEY, payload BLOB NOT NULL)")
        try database.execute("""
        CREATE TABLE IF NOT EXISTS operations(
          id TEXT PRIMARY KEY,
          dose_id TEXT NOT NULL UNIQUE,
          path TEXT NOT NULL,
          body BLOB NOT NULL,
          declaration TEXT NOT NULL,
          occurred_at TEXT,
          is_correction INTEGER NOT NULL,
          correction_reason TEXT,
          previous_consumes INTEGER NOT NULL,
          created_at REAL NOT NULL,
          status TEXT NOT NULL,
          attempts INTEGER NOT NULL DEFAULT 0,
          sequence INTEGER
        )
        """)
    }

    // MARK: Propietario

    func claim(ownerUID: String, discardingOtherOwner: Bool = false) throws -> OwnerCheck {
        try database.transaction {
            let owner = try metaValue("owner_uid")
            if owner != ownerUID {
                let pending = try database.query("SELECT COUNT(*) AS total FROM operations").first?.int("total") ?? 0
                if owner != nil, pending > 0, !discardingOtherOwner { return .otherOwnerHasPending(pending) }
                try wipeTables()
                try setMeta("owner_uid", ownerUID)
            }
            return .ready
        }
    }

    func wipe() throws {
        try database.transaction { try wipeTables() }
    }

    private func wipeTables() throws {
        for table in ["meta", "doses", "treatments", "inventory", "links", "operations"] {
            try database.execute("DELETE FROM \(table)")
        }
    }

    func setPatientID(_ id: String) throws {
        try setMeta("patient_id", id)
    }

    func patientID() throws -> String? {
        try metaValue("patient_id")
    }

    private func metaValue(_ key: String) throws -> String? {
        try database.query("SELECT value FROM meta WHERE key=?", [.text(key)]).first?.text("value")
    }

    private func setMeta(_ key: String, _ value: String) throws {
        try database.execute("INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(key), .text(value)])
    }

    // MARK: Caché

    /// Reemplaza la ventana por lo que dijo el servidor. Una respuesta antigua nunca baja la versión.
    func replaceAgenda(_ doses: [Dose], from: String, to: String, at now: Date) throws {
        try database.transaction {
            try database.execute("CREATE TEMP TABLE IF NOT EXISTS incoming(id TEXT PRIMARY KEY)")
            try database.execute("DELETE FROM incoming")
            for dose in doses {
                try database.execute("INSERT OR IGNORE INTO incoming(id) VALUES(?)", [.text(dose.id)])
                try upsert(dose)
            }
            try database.execute("DELETE FROM doses WHERE local_date>=? AND local_date<? AND id NOT IN (SELECT id FROM incoming)", [.text(from), .text(to)])
            try setMeta("last_sync_at", String(now.timeIntervalSince1970))
        }
    }

    /// Añade dosis históricas sin borrar nada: el historial amplía la ventana bajo demanda.
    func mergeDoses(_ doses: [Dose]) throws {
        try database.transaction {
            for dose in doses { try upsert(dose) }
        }
    }

    private func upsert(_ dose: Dose) throws {
        try database.execute("""
        INSERT INTO doses(id,local_date,scheduled_at,version,payload) VALUES(?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET local_date=excluded.local_date, scheduled_at=excluded.scheduled_at, version=excluded.version, payload=excluded.payload
        WHERE excluded.version>=doses.version
        """, [.text(dose.id), .text(dose.localDate), .double(dose.scheduledInstant.timeIntervalSince1970), .int(Int64(dose.version)), .blob(try JSONEncoder().encode(dose))])
    }

    func replaceTreatments(_ treatments: [Treatment]) throws {
        try database.transaction {
            try database.execute("DELETE FROM treatments")
            for item in treatments {
                try database.execute("INSERT INTO treatments(id,payload) VALUES(?,?)", [.text(item.id), .blob(try JSONEncoder().encode(item))])
            }
        }
    }

    func replaceInventory(_ inventory: [InventoryProjection]) throws {
        try database.transaction {
            try database.execute("DELETE FROM inventory")
            for item in inventory {
                try database.execute("INSERT INTO inventory(id,treatment_id,payload) VALUES(?,?,?)", [.text(item.id), .text(item.treatmentID), .blob(try JSONEncoder().encode(item))])
            }
        }
    }

    func replaceLinks(_ links: [CaregiverLink]) throws {
        try database.transaction {
            try database.execute("DELETE FROM links")
            for item in links {
                try database.execute("INSERT INTO links(id,payload) VALUES(?,?)", [.text(item.id), .blob(try JSONEncoder().encode(item))])
            }
        }
    }

    func snapshot() throws -> LocalSnapshot {
        let decoder = JSONDecoder()
        func decode<Item: Decodable>(_ sql: String) throws -> [Item] {
            try database.query(sql).compactMap { row in try row.blob("payload").map { try decoder.decode(Item.self, from: $0) } }
        }
        return LocalSnapshot(
            doses: try decode("SELECT payload FROM doses ORDER BY scheduled_at, id"),
            treatments: try decode("SELECT payload FROM treatments ORDER BY id"),
            inventory: try decode("SELECT payload FROM inventory ORDER BY id"),
            links: try decode("SELECT payload FROM links ORDER BY id"),
            operations: try operations(),
            lastSyncAt: try metaValue("last_sync_at").flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
        )
    }

    // MARK: Cola

    /// Persiste la declaración antes de cualquier red. Un segundo toque devuelve la operación existente.
    @discardableResult
    func enqueue(_ operation: PendingOperation) throws -> PendingOperation {
        try database.transaction {
            if let existing = try operations().first(where: { $0.doseID == operation.doseID }) { return existing }
            try insert(operation)
            return operation
        }
    }

    /// Sustituye una operación ya resuelta por el usuario por una con identidad nueva.
    func replaceOperation(_ oldID: String, with operation: PendingOperation) throws {
        try database.transaction {
            try database.execute("DELETE FROM operations WHERE id=?", [.text(oldID)])
            try insert(operation)
        }
    }

    private func insert(_ operation: PendingOperation) throws {
        let sequence = try database.query("SELECT COALESCE(MAX(sequence),0)+1 AS next FROM operations").first?.int("next") ?? 1
        try database.execute("""
        INSERT INTO operations(id,dose_id,path,body,declaration,occurred_at,is_correction,correction_reason,previous_consumes,created_at,status,attempts,sequence)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, [
            .text(operation.id), .text(operation.doseID), .text(operation.path), .blob(operation.body), .text(operation.declaration.rawValue),
            operation.occurredAt.map(SQLiteValue.text) ?? .null, .int(operation.isCorrection ? 1 : 0), operation.correctionReason.map(SQLiteValue.text) ?? .null,
            .int(operation.previousStateConsumes ? 1 : 0), .double(operation.createdAt.timeIntervalSince1970), .text(operation.status.rawValue), .int(Int64(operation.attempts)), .int(Int64(sequence)),
        ])
    }

    func operations() throws -> [PendingOperation] {
        try database.query("SELECT * FROM operations ORDER BY sequence").compactMap { row in
            guard let id = row.text("id"), let doseID = row.text("dose_id"), let path = row.text("path"), let body = row.blob("body"),
                  let declaration = row.text("declaration").flatMap(Declaration.init(rawValue:)), let status = row.text("status").flatMap(OperationStatus.init(rawValue:)),
                  let createdAt = row.double("created_at") else { return nil }
            return PendingOperation(
                id: id, doseID: doseID, path: path, body: body, declaration: declaration, occurredAt: row.text("occurred_at"),
                isCorrection: row.int("is_correction") == 1, correctionReason: row.text("correction_reason"),
                previousStateConsumes: row.int("previous_consumes") == 1, createdAt: Date(timeIntervalSince1970: createdAt),
                status: status, attempts: row.int("attempts") ?? 0
            )
        }
    }

    func markAttempt(_ id: String) throws {
        try database.execute("UPDATE operations SET attempts=attempts+1 WHERE id=?", [.text(id)])
    }

    func mark(_ id: String, status: OperationStatus) throws {
        try database.execute("UPDATE operations SET status=? WHERE id=?", [.text(status.rawValue), .text(id)])
    }

    /// Descarta sólo por decisión explícita del usuario.
    func discardOperation(_ id: String) throws {
        try database.execute("DELETE FROM operations WHERE id=?", [.text(id)])
    }

    /// Aplica la respuesta autoritativa y retira la operación en una sola transacción.
    func apply(_ result: DoseResult, for operation: PendingOperation) throws {
        try database.transaction {
            if var dose = try database.query("SELECT payload FROM doses WHERE id=?", [.text(result.doseID)]).first?.blob("payload").flatMap({ try? JSONDecoder().decode(Dose.self, from: $0) }) {
                dose.state = result.state
                dose.version = result.version
                dose.eventID = result.eventID
                try upsert(dose)
                if let payload = try database.query("SELECT payload FROM inventory WHERE treatment_id=?", [.text(dose.treatmentID)]).first?.blob("payload"),
                   var account = try? JSONDecoder().decode(InventoryProjection.self, from: payload) {
                    account.balance = result.balance
                    try database.execute("UPDATE inventory SET payload=? WHERE id=?", [.blob(try JSONEncoder().encode(account)), .text(account.id)])
                }
            }
            try database.execute("DELETE FROM operations WHERE id=?", [.text(operation.id)])
        }
    }
}
