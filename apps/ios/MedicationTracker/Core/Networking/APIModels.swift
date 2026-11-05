import Foundation

enum DoseState: String, Codable, Sendable, CaseIterable {
    case pending, unconfirmed, taken
    case takenLate = "taken_late"
    case skipped

    var isDeclared: Bool { self == .taken || self == .takenLate || self == .skipped }
    var consumes: Bool { self == .taken || self == .takenLate }
}

enum Declaration: String, Codable, Sendable, CaseIterable, Identifiable {
    case taken
    case takenLate = "taken_late"
    case skipped

    var id: String { rawValue }
    var consumes: Bool { self != .skipped }
    var asState: DoseState { DoseState(rawValue: rawValue) ?? .pending }
}

struct Dose: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let treatmentID: String
    let revisionID: String
    let scheduledAt: String
    let localDate: String
    let localTime: String
    let timezone: String
    let dstAdjusted: Bool
    let quantity: String
    var state: DoseState
    var version: Int
    var eventID: String?

    enum CodingKeys: String, CodingKey {
        case id = "dose_id"
        case treatmentID = "treatment_id"
        case revisionID = "revision_id"
        case scheduledAt = "scheduled_at"
        case localDate = "local_date"
        case localTime = "local_time"
        case timezone
        case dstAdjusted = "dst_adjusted"
        case quantity, state, version
        case eventID = "event_id"
    }

    var scheduledInstant: Date { Instant.parse(scheduledAt) ?? .distantPast }
}

struct Treatment: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let accountID: String
    let name: String
    let strengthLabel: String
    let form: String
    let instructions: String
    let unit: String
    let archivedAt: String?

    enum CodingKeys: String, CodingKey {
        case id = "treatment_id"
        case accountID = "account_id"
        case name
        case strengthLabel = "strength_label"
        case form, instructions, unit
        case archivedAt = "archived_at"
    }
}

struct InventoryProjection: Codable, Sendable, Identifiable, Equatable {
    let accountID: String
    let treatmentID: String
    var balance: String
    let unit: String
    let firstUncoveredAt: String?
    let scheduledQuantity: String

    var from: String? = nil
    var through: String? = nil
    var timezone: String? = nil
    var replenishOn: String? = nil
    var lowStock: Bool? = nil
    var pool: InventoryPool? = nil

    var id: String { accountID }

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case treatmentID = "treatment_id"
        case balance, unit
        case firstUncoveredAt = "first_uncovered_at"
        case scheduledQuantity = "scheduled_quantity"
        case from, through, timezone
        case replenishOn = "replenish_on"
        case lowStock = "low_stock"
        case pool
    }
}

struct DoseResult: Codable, Sendable, Equatable {
    let doseID: String
    let eventID: String
    let version: Int
    let state: DoseState
    let balance: String

    enum CodingKeys: String, CodingKey {
        case doseID = "dose_id"
        case eventID = "event_id"
        case version, state, balance
    }
}

struct Me: Codable, Sendable, Equatable {
    let userID: String
    var displayName: String? = nil
    var profileVersion: Int? = nil
    var profileComplete: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case displayName = "display_name"
        case profileVersion = "profile_version"
        case profileComplete = "profile_complete"
    }
}

struct CaregiverLink: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let patientID: String
    let caregiverID: String
    let scopes: [String]
    let status: String
    var patientDisplayName: String? = nil
    var caregiverDisplayName: String? = nil

    enum CodingKeys: String, CodingKey {
        case id = "link_id"
        case patientID = "patient_id"
        case caregiverID = "caregiver_id"
        case scopes, status
        case patientDisplayName = "patient_display_name"
        case caregiverDisplayName = "caregiver_display_name"
    }
}

struct InvitationPreview: Codable, Sendable, Equatable {
    let caregiverID: String
    let scopes: [String]
    let expiresAt: String
    var caregiverDisplayName: String? = nil
    var patientNameHint: String? = nil

    enum CodingKeys: String, CodingKey {
        case caregiverID = "caregiver_id"
        case scopes
        case expiresAt = "expires_at"
        case caregiverDisplayName = "caregiver_display_name"
        case patientNameHint = "patient_name_hint"
    }
}

struct Page<Item: Decodable & Sendable>: Decodable, Sendable {
    let items: [Item]
    let nextCursor: String

    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
    }
}

struct DoseEventBody: Codable, Sendable, Equatable {
    let clientOperationID: String
    let expectedVersion: Int
    let eventType: Declaration
    let occurredAt: String?

    enum CodingKeys: String, CodingKey {
        case clientOperationID = "client_operation_id"
        case expectedVersion = "expected_version"
        case eventType = "event_type"
        case occurredAt = "occurred_at"
    }
}

struct CorrectionBody: Codable, Sendable, Equatable {
    let clientOperationID: String
    let expectedVersion: Int
    let eventType: Declaration
    let occurredAt: String?
    let correctsEventID: String
    let reason: String

    enum CodingKeys: String, CodingKey {
        case clientOperationID = "client_operation_id"
        case expectedVersion = "expected_version"
        case eventType = "event_type"
        case occurredAt = "occurred_at"
        case correctsEventID = "corrects_event_id"
        case reason
    }
}

enum Instant {
    // Apple documenta ISO8601DateFormatter como seguro entre hilos; aquí no se modifica tras crearlo.
    private nonisolated(unsafe) static let formatter = ISO8601DateFormatter()

    /// Go emite RFC 3339 con hasta nueve decimales; la app sólo necesita segundos.
    static func parse(_ text: String) -> Date? {
        formatter.date(from: text.replacing(/\.\d+/, with: ""))
    }

    static func format(_ date: Date) -> String {
        formatter.string(from: date)
    }
}
