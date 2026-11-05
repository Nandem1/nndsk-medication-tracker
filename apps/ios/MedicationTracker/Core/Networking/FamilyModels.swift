import Foundation

struct PatientAccess: Codable, Sendable, Equatable, Identifiable {
    let patientID: String
    let linkID: String?
    let scopes: [String]
    let displayName: String?
    let profileVersion: Int
    let timezone: String
    var id: String { patientID }
    var name: String { displayName ?? "Paciente sin nombre" }
    func permits(_ scope: String) -> Bool { scopes.contains(scope) }
    enum CodingKeys: String, CodingKey {
        case patientID = "patient_id", linkID = "link_id", scopes, timezone
        case displayName = "display_name", profileVersion = "profile_version"
    }
}

struct DailyReport: Codable, Sendable, Equatable {
    struct Counts: Codable, Sendable, Equatable { let confirmed: Int; let evaluable: Int; let unconfirmed: Int }
    let from: String
    let to: String
    let summary: Counts
}
struct CreatedInvitation: Decodable, Sendable {
    let token: String
    let expiresAt: String
    enum CodingKeys: String, CodingKey { case token; case expiresAt = "expires_at" }
}
struct InventoryMovement: Decodable, Sendable, Identifiable {
    let id: String
    let quantity: String
    let reason: String
    let createdAt: String
    var patientName: String? = nil
    enum CodingKeys: String, CodingKey {
        case id = "movement_id", quantity = "quantity_delta", reason, createdAt = "created_at", patientName = "patient_display_name"
    }
    /// El servidor anula la hora de la actividad ajena: se muestra sólo la fecha, sin convertir de zona.
    var sharedDate: String? {
        guard reason == "shared_activity" else { return nil }
        return createdAt.prefix(10).split(separator: "-").reversed().joined(separator: "-")
    }
    var label: String {
        switch reason {
        case "initial": "Stock inicial"
        case "replenishment": "Reposición"
        case "consumption": "Consumo declarado"
        case "reversal": "Reversa de declaración"
        case "manual_adjustment": "Conteo físico"
        case "pool_transfer": "Traspaso por inventario compartido"
        case "shared_activity": "Actividad compartida"
        default: "Ajuste de inventario"
        }
    }
}
struct PoolMember: Codable, Sendable, Equatable {
    let name: String?
    let you: Bool
    let current: Bool
    let status: String
    enum CodingKeys: String, CodingKey { case name = "patient_display_name", you, current, status }
}
struct InventoryPool: Codable, Sendable, Equatable {
    let id: String
    let status: String
    let members: [PoolMember]
    enum CodingKeys: String, CodingKey { case id = "pool_id", status, members }
    var active: Bool { status == "active" }
    /// Los demás miembros del inventario, sin la persona dueña de esta cuenta.
    func others(status: String? = nil) -> String {
        var names: [String] = []
        for member in members where !member.current && (status == nil || member.status == status) {
            let name = member.name ?? "Paciente sin nombre"
            if !names.contains(name) { names.append(name) }
        }
        return names.isEmpty ? "otra persona" : names.joined(separator: ", ")
    }
}
struct PendingPool: Decodable, Sendable, Equatable, Identifiable {
    let id: String
    let proposer: String?
    let medication: String
    let strength: String
    let others: [String]
    enum CodingKeys: String, CodingKey { case id = "pool_id", proposer = "proposer_display_name", medication = "medication_name", strength = "strength_label", others }
    var text: String {
        let label = [medication, strength].filter { !$0.isEmpty }.joined(separator: " ")
        var names: [String] = []
        for name in others where !names.contains(name) { names.append(name) }
        let partner = names.isEmpty ? "entre tus tratamientos" : "con \(names.joined(separator: ", "))"
        return "\(proposer ?? "Alguien") propone compartir \(label) \(partner). Compartirán el mismo saldo y podrán ver cuánto queda."
    }
}
struct PoolCandidate: Decodable, Sendable, Identifiable {
    let accountID: String
    let name: String?
    let you: Bool
    var id: String { accountID }
    enum CodingKeys: String, CodingKey { case accountID = "account_id", name = "patient_display_name", you }
}
enum InvitationPreset: String, CaseIterable, Identifiable {
    case read = "Sólo mirar", record = "Ayudar a registrar", administer = "Administrar todo"
    var id: String { rawValue }
    var scopes: [String] {
        switch self {
        case .read: ["read"]
        case .record: ["read", "doses"]
        case .administer: ["read", "treatments", "doses", "inventory"]
        }
    }
}
enum FamilyText {
    static let missedGuidance = "Si la persona olvidó una dosis o la tomó tarde, sigan las instrucciones de su profesional de salud o consulten a un farmacéutico. Esta app no indica cambiar ni reponer dosis."
    static func token(_ text: String) throws -> String {
        guard let range = text.range(of: "(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{43}(?![A-Za-z0-9_-])", options: .regularExpression) else { throw APIError.invalid }
        return String(text[range])
    }
    static func invitation(_ token: String) -> String {
        "Hola, te invito a Mis tomas. Abre la app, entra en Ajustes › Acceso de cuidadores y pega este código: \(token). Vence en 24 horas."
    }
    static func declaration(_ value: Declaration) -> String {
        switch value { case .taken: "Se lo tomó"; case .takenLate: "Se lo tomó tarde"; case .skipped: "No se lo tomó" }
    }
}
