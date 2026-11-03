import Foundation
@testable import MedicationTracker

/// Doble de red para clasificar respuestas. Estas pruebas no sustituyen el flujo E2E contra la API real.
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    enum Reply {
        case status(Int, String = "{}")
        case failure(URLError.Code)
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private var captured: [URLRequest] = []

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    var requests: [URLRequest] { lock.withLock { captured } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply: Reply = lock.withLock {
            captured.append(request)
            return replies.isEmpty ? .failure(.notConnectedToInternet) : replies.removeFirst()
        }
        switch reply {
        case let .status(code, body):
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
        case let .failure(code):
            throw URLError(code)
        }
    }
}

struct FixedTokens: TokenProviding {
    func token(forceRefresh _: Bool) async throws -> String { "test-token" }
}

final class MemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?

    func read() -> Data? { lock.withLock { value } }
    func write(_ data: Data) throws { lock.withLock { value = data } }
    func delete() { lock.withLock { value = nil } }
}

enum Fixture {
    static let patient = "00000000-0000-4000-8000-000000000001"
    static let treatment = "00000000-0000-4000-8000-000000000002"
    static let account = "00000000-0000-4000-8000-000000000003"

    static func dose(id: String = "00000000-0000-4000-8000-0000000000d1", at: String = "2026-11-02T12:00:00Z", state: DoseState = .pending, version: Int = 1, quantity: String = "0.500", eventID: String? = nil, localDate: String = "2026-11-02") -> Dose {
        Dose(id: id, treatmentID: treatment, revisionID: "00000000-0000-4000-8000-000000000004", scheduledAt: at, localDate: localDate, localTime: "09:00", timezone: "America/Santiago", dstAdjusted: false, quantity: quantity, state: state, version: version, eventID: eventID)
    }

    static func account(balance: String = "10.000") -> InventoryProjection {
        InventoryProjection(accountID: account, treatmentID: treatment, balance: balance, unit: "tablet", firstUncoveredAt: nil, scheduledQuantity: "1.000")
    }

    static func temporaryStore() throws -> (LocalStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "store-\(UUID().uuidString)")
        return (try LocalStore(directory: directory), directory)
    }
}
