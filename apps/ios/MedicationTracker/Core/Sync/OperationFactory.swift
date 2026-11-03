import Foundation

/// Construye el cuerpo definitivo de la operación en el momento del toque.
/// `occurred_at` se fija aquí: si se dejara al servidor, `taken` tomaría la hora de sincronización.
enum OperationFactory {
    static func declaration(_ declaration: Declaration, dose: Dose, occurredAt: Date?, now: Date, id: String = UUID().uuidString.lowercased()) throws -> PendingOperation {
        let occurred = declaration == .skipped ? nil : Instant.format(occurredAt ?? now)
        let body = DoseEventBody(clientOperationID: id, expectedVersion: dose.version, eventType: declaration, occurredAt: occurred)
        return PendingOperation(
            id: id, doseID: dose.id, path: "/v1/doses/\(dose.id)/events", body: try JSONEncoder().encode(body),
            declaration: declaration, occurredAt: occurred, isCorrection: false, correctionReason: nil,
            previousStateConsumes: dose.state.consumes, createdAt: now, status: .pending, attempts: 0
        )
    }

    static func correction(_ declaration: Declaration, dose: Dose, eventID: String, occurredAt: Date?, reason: String, now: Date, id: String = UUID().uuidString.lowercased()) throws -> PendingOperation {
        let occurred = declaration == .skipped ? nil : Instant.format(occurredAt ?? now)
        let body = CorrectionBody(clientOperationID: id, expectedVersion: dose.version, eventType: declaration, occurredAt: occurred, correctsEventID: eventID, reason: reason)
        return PendingOperation(
            id: id, doseID: dose.id, path: "/v1/doses/\(dose.id)/corrections", body: try JSONEncoder().encode(body),
            declaration: declaration, occurredAt: occurred, isCorrection: true, correctionReason: reason,
            previousStateConsumes: dose.state.consumes, createdAt: now, status: .pending, attempts: 0
        )
    }
}
