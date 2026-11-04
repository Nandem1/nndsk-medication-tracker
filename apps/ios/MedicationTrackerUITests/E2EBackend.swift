import Foundation
import XCTest

/// Actúa como cuidador contra la API real y controla el proxy de fallos.
/// La app bajo prueba no conoce este código ni tiene rutas especiales para pruebas.
struct E2EBackend {
    // TEST_RUNNER_E2E_PORT_OFFSET permite correr junto a otros servidores locales, como en la web.
    private static let offset = Int(ProcessInfo.processInfo.environment["E2E_PORT_OFFSET"] ?? "") ?? 0
    static let proxy = URL(string: "http://127.0.0.1:\(18084 + offset)")!
    static let api = URL(string: "http://127.0.0.1:\(18083 + offset)")!
    static let emulator = URL(string: "http://127.0.0.1:\(9099 + offset)")!
    static let password = "synthetic-password-1"

    struct Account {
        let email: String
        let token: String
    }

    struct DoseView: Decodable {
        let dose_id: String
        let state: String
        let version: Int
        let scheduled_at: String
        let treatment_id: String
    }

    struct InventoryView: Decodable {
        let account_id: String
        let treatment_id: String
        let balance: String
    }

    struct Movement: Decodable {
        let quantity_delta: String
        let reason: String
    }

    private struct Page<Item: Decodable>: Decodable {
        let items: [Item]
    }

    static func signUp(_ prefix: String) async throws -> Account {
        let email = "\(prefix)-\(UUID().uuidString.lowercased().prefix(8))@example.test"
        var request = URLRequest(url: emulator.appending(path: "identitytoolkit.googleapis.com/v1/accounts:signUp").appending(queryItems: [URLQueryItem(name: "key", value: "e2e-public-placeholder")]))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "password": password, "returnSecureToken": true])
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return Account(email: email, token: try XCTUnwrap(body?["idToken"] as? String))
    }

    static func setFault(_ mode: String) async throws {
        var request = URLRequest(url: proxy.appending(path: "__fault/\(mode)"))
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
    }

    private static func call(_ token: String, _ method: String, _ path: String, body: Any? = nil) async throws -> (Data, Int) {
        var request = URLRequest(url: api.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func userID(_ account: Account) async throws -> String {
        let (data, status) = try await call(account.token, "GET", "/v1/me")
        XCTAssertEqual(status, 200)
        let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(body?["user_id"] as? String)
    }

    static func invite(caregiver: Account) async throws -> String {
        let (data, status) = try await call(caregiver.token, "POST", "/v1/invitations", body: [
            "client_operation_id": UUID().uuidString.lowercased(),
            "scopes": ["read", "treatments", "doses", "inventory"],
        ])
        XCTAssertEqual(status, 201)
        let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(body?["token"] as? String)
    }

    /// Pauta de un solo día con un horario vencido y otro futuro. Usa una zona donde ambos caen en
    /// el mismo día local, para no depender de la hora a la que corre la prueba.
    static func createTreatment(caregiver: Account, patient: String, name: String, futureMinutes: Int = 180) async throws {
        let now = Date.now
        let past = now.addingTimeInterval(-120)
        let future = now.addingTimeInterval(TimeInterval(futureMinutes * 60))
        var calendar = Calendar(identifier: .gregorian)
        let candidates = ["America/Santiago", "UTC", "Asia/Tokyo", "Pacific/Auckland"].compactMap(TimeZone.init(identifier:))
        let zone = try XCTUnwrap(candidates.first { candidate in
            calendar.timeZone = candidate
            return calendar.isDate(past, inSameDayAs: now) && calendar.isDate(future, inSameDayAs: now)
        })
        calendar.timeZone = zone
        func hhmm(_ date: Date) -> String {
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        }
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        let today = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let (_, status) = try await call(caregiver.token, "POST", "/v1/patients/\(patient)/treatments", body: [
            "client_operation_id": UUID().uuidString.lowercased(),
            "name": name,
            "strength_label": "500 mg",
            "form": "comprimido",
            "instructions": "Texto sintético de instrucción registrada.",
            "unit": "tablet",
            "initial_stock": "10.000",
            "starts_on": today,
            "ends_on": today,
            "schedule": [
                "timezone": zone.identifier,
                "dst_policy": "next_valid_earliest",
                "weekdays": [0, 1, 2, 3, 4, 5, 6],
                "slots": [["time": hhmm(past), "quantity": "0.500"], ["time": hhmm(future), "quantity": "0.500"]],
            ],
        ])
        XCTAssertEqual(status, 201)
    }

    static func doses(_ account: Account, patient: String) async throws -> [DoseView] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        func day(_ date: Date) -> String {
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }
        // La pauta puede estar en otra zona: el margen cubre su día local.
        let from = calendar.date(byAdding: .day, value: -1, to: .now) ?? .now
        let to = calendar.date(byAdding: .day, value: 2, to: .now) ?? .now
        var request = URLRequest(url: api.appending(path: "/v1/patients/\(patient)/doses").appending(queryItems: [URLQueryItem(name: "from", value: day(from)), URLQueryItem(name: "to", value: day(to))]))
        request.setValue("Bearer \(account.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.userAuthenticationRequired) }
        return try JSONDecoder().decode(Page<DoseView>.self, from: data).items
    }

    static func inventory(_ account: Account, patient: String) async throws -> [InventoryView] {
        let (data, status) = try await call(account.token, "GET", "/v1/patients/\(patient)/inventory")
        XCTAssertEqual(status, 200)
        return try JSONDecoder().decode(Page<InventoryView>.self, from: data).items
    }

    static func movements(_ account: Account, inventory id: String) async throws -> [Movement] {
        let (data, status) = try await call(account.token, "GET", "/v1/inventory/\(id)/movements")
        XCTAssertEqual(status, 200)
        return try JSONDecoder().decode(Page<Movement>.self, from: data).items
    }

    static func declare(_ account: Account, dose: DoseView, type: String) async throws {
        let (_, status) = try await call(account.token, "POST", "/v1/doses/\(dose.dose_id)/events", body: [
            "client_operation_id": UUID().uuidString.lowercased(),
            "expected_version": dose.version,
            "event_type": type,
        ])
        XCTAssertEqual(status, 200)
    }
}
