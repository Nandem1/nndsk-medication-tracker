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
struct PoolCandidate: Decodable, Sendable, Identifiable {
    let accountID: String
    let name: String?
    let you: Bool
    var id: String { accountID }
    enum CodingKeys: String, CodingKey { case accountID = "account_id", name = "patient_display_name", you }
}
struct FamilyMember: Codable, Sendable, Equatable, Identifiable {
    let userID: String
    let displayName: String?
    let role: FamilyRole
    let joinedAt: String
    var you = false
    var id: String { userID }
    var name: String { displayName ?? "Persona sin nombre" }
    /// Un miembro es nuevo durante su primera semana, para que el paciente sepa quién se unió.
    func isNew(now: Date = .now) -> Bool {
        guard !you, let joined = Instant.parse(joinedAt) else { return false }
        return now.timeIntervalSince(joined) < 7 * 86_400
    }
    enum CodingKeys: String, CodingKey { case userID = "user_id", displayName = "display_name", role, joinedAt = "joined_at", you }
}
struct Family: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let role: FamilyRole
    let members: [FamilyMember]
    enum CodingKeys: String, CodingKey { case id = "family_id", name, role, members }
}
struct FamilyInvitationPreview: Codable, Sendable, Equatable {
    let familyName: String
    let inviterDisplayName: String?
    let role: FamilyRole
    let patientNameHint: String?
    let members: [FamilyMember]
    let expiresAt: String
    enum CodingKeys: String, CodingKey { case familyName = "family_name", inviterDisplayName = "inviter_display_name", role, patientNameHint = "patient_name_hint", members, expiresAt = "expires_at" }
}
enum FamilyRole: String, Codable, Sendable, CaseIterable, Identifiable {
    case patient, caregiver, observer, admin
    var id: String { rawValue }
    var label: String {
        switch self { case .patient: "Paciente"; case .caregiver: "Cuidar"; case .observer: "Sólo mirar"; case .admin: "Administrar" }
    }
    var summary: String {
        switch self {
        case .patient: "Registra sus propias tomas. Quienes cuidan en la familia verán su agenda."
        case .caregiver: "Ve a cada paciente, registra tomas y repone stock."
        case .observer: "Ve agendas, historial e inventario. No cambia nada."
        case .admin: "Todo lo anterior, más tratamientos e invitar o quitar personas."
        }
    }
}
enum FamilyText {
    static let selfReported = "Los registros son declaraciones. No demuestran que el medicamento se haya tomado."
    /// El informe guardado puede ser de otro día: sólo se llama «hoy» si lo es, en la zona del paciente.
    static func period(from: String, timezone: String?, now: Date = .now) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone.flatMap(TimeZone.init(identifier:)) ?? .current
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        let current = String(format: "%04d-%02d-%02d", today.year ?? 0, today.month ?? 0, today.day ?? 0)
        return from == current ? "Hoy hasta ahora" : "Datos del \(DoseText.day(from))"
    }
    static let missedGuidance = "Si la persona olvidó una dosis o la tomó tarde, sigan las instrucciones de su profesional de salud o consulten a un farmacéutico. Esta app no indica cambiar ni reponer dosis."
    static func token(_ text: String) throws -> String {
        guard let range = text.range(of: "(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{43}(?![A-Za-z0-9_-])", options: .regularExpression) else { throw APIError.invalid }
        return String(text[range])
    }
    /// El enlace abre la app. El token va en el fragmento: ningún servidor lo recibe por la URL.
    static func link(_ token: String) -> String { "mistomas://unirse#\(token)" }
    static func invitation(_ token: String, family: String) -> String {
        "Hola, te invito a «\(family)» en Mis tomas. En tu teléfono, toca este enlace:\n\n\(link(token))\n\nSi no se abre, entra en la app, ve a Ajustes › Familia y pega este código: \(token)\n\nVence en 7 días."
    }
    static func initials(_ name: String?) -> String {
        let words = (name ?? "").split(whereSeparator: \.isWhitespace)
        guard let first = words.first?.first else { return "?" }
        let last = words.count > 1 ? words.last?.first.map(String.init) ?? "" : ""
        return (String(first) + last).uppercased()
    }
    static func declaration(_ value: Declaration) -> String {
        switch value { case .taken: "Se lo tomó"; case .takenLate: "Se lo tomó tarde"; case .skipped: "No se lo tomó" }
    }
}
