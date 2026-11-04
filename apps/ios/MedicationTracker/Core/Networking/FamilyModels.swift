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
    enum CodingKeys: String, CodingKey {
        case id = "movement_id", quantity = "quantity_delta", reason, createdAt = "created_at"
    }
    var label: String {
        switch reason {
        case "initial": "Stock inicial"
        case "replenishment": "Reposición"
        case "consumption": "Consumo declarado"
        case "reversal": "Reversa de declaración"
        case "manual_adjustment": "Conteo físico"
        default: "Ajuste de inventario"
        }
    }
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
