import Foundation

protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Clasifica los fallos según lo que la cola debe hacer, sin contenido médico.
enum APIError: Error, Equatable {
    case unauthenticated
    case denied
    case conflict
    case invalid
    case rateLimited
    case server
    case transport
    case decoding

    var message: String {
        switch self {
        case .unauthenticated: "La sesión venció. Vuelve a iniciar sesión."
        case .denied: "No tienes permiso para esta información o ya no existe."
        case .conflict: "La información cambió en el servidor. Revísala antes de continuar."
        case .invalid: "El servidor rechazó los datos. Revisa la fecha y la hora."
        case .rateLimited: "Hay demasiadas solicitudes. Se volverá a intentar en un momento."
        case .server, .decoding: "El servidor no pudo completar la solicitud. Se volverá a intentar."
        case .transport: "No hay conexión con el servidor. Se volverá a intentar."
        }
    }
}

protocol TokenProviding: Sendable {
    var sessionGeneration: Int { get async }
    func token(forceRefresh: Bool) async throws -> String
}

struct APIClient: Sendable {
    let baseURL: URL
    let transport: any HTTPTransport
    let tokens: any TokenProviding

    func registerDevice(_ registration: DeviceRegistration) async throws {
        _ = try await send("/v1/devices", query: [], method: "POST", body: JSONEncoder().encode(registration))
    }

    func unregisterDevice(id: String) async throws {
        _ = try await send("/v1/devices/\(id)", query: [], method: "DELETE", body: nil, timeout: 5)
    }

    func me() async throws -> Me {
        try await request("/v1/me")
    }

    func patients() async throws -> [PatientAccess] { try await all("/v1/patients") }
    func report(patient: String, from: String, to: String) async throws -> DailyReport {
        try await request("/v1/patients/\(patient)/adherence", query: [.init(name: "from", value: from), .init(name: "to", value: to)])
    }
    func updateProfile(patient: String?, name: String, version: Int, operation: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["display_name": name, "expected_version": version, "client_operation_id": operation])
        _ = try await send(patient.map { "/v1/patients/\($0)/profile" } ?? "/v1/me/profile", query: [], method: "PUT", body: body)
    }
    func createInvitation(preset: InvitationPreset, hint: String) async throws -> CreatedInvitation {
        var body: [String: Any] = ["client_operation_id": UUID().uuidString.lowercased(), "scopes": preset.scopes]
        if !hint.isEmpty { body["patient_name_hint"] = hint }
        return try await request("/v1/invitations", method: "POST", body: JSONSerialization.data(withJSONObject: body))
    }
    func movements(account: String) async throws -> [InventoryMovement] { try await all("/v1/inventory/\(account)/movements") }
    func inventoryMutation(account: String, quantity: String, count: Bool, reason: String, expected: String, operation: String) async throws {
        var body = ["client_operation_id": operation, count ? "counted_quantity" : "quantity": quantity]
        if count { body["reason"] = reason; body["expected_balance"] = expected }
        _ = try await send("/v1/inventory/\(account)/" + (count ? "counts" : "movements"), query: [], method: "POST", body: JSONEncoder().encode(body))
    }

    func pendingPools() async throws -> [PendingPool] { try await all("/v1/inventory-pools/pending") }
    func poolCandidates(account: String) async throws -> [PoolCandidate] { try await all("/v1/inventory/\(account)/pool-candidates") }
    func createPool(accounts: [String], operation: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["client_operation_id": operation, "account_ids": accounts])
        _ = try await send("/v1/inventory-pools", query: [], method: "POST", body: body)
    }
    func decidePool(id: String, accept: Bool, operation: String) async throws {
        let body = try JSONEncoder().encode(["client_operation_id": operation, "decision": accept ? "accept" : "decline"])
        _ = try await send("/v1/inventory-pools/\(id)/decision", query: [], method: "POST", body: body)
    }
    func leavePool(id: String, account: String, operation: String) async throws {
        let body = try JSONEncoder().encode(["client_operation_id": operation, "account_id": account])
        _ = try await send("/v1/inventory-pools/\(id)/leave", query: [], method: "POST", body: body)
    }
    func treatments(patient: String) async throws -> [Treatment] {
        try await all("/v1/patients/\(patient)/treatments")
    }

    func doses(patient: String, from: String, to: String) async throws -> [Dose] {
        try await all("/v1/patients/\(patient)/doses", query: [URLQueryItem(name: "from", value: from), URLQueryItem(name: "to", value: to)])
    }

    func inventory(patient: String) async throws -> [InventoryProjection] {
        try await all("/v1/patients/\(patient)/inventory")
    }

    func links() async throws -> [CaregiverLink] {
        try await all("/v1/caregiver-links")
    }

    func previewInvitation(token: String) async throws -> InvitationPreview {
        try await request("/v1/invitations/preview", method: "POST", body: JSONEncoder().encode(["token": token]))
    }

    func acceptInvitation(token: String, operationID: String) async throws -> CaregiverLink {
        try await request("/v1/invitations/accept", method: "POST", body: JSONEncoder().encode(["token": token, "client_operation_id": operationID]))
    }

    func revoke(link: String) async throws {
        _ = try await send("/v1/caregiver-links/\(link)", query: [], method: "DELETE", body: nil)
    }

    /// El cuerpo llega ya serializado: un reintento debe enviar los mismos bytes.
    func submit(_ operation: PendingOperation) async throws -> DoseResult {
        try await request(operation.path, method: "POST", body: operation.body)
    }

    private func all<Item: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = []) async throws -> [Item] {
        var items: [Item] = []
        var cursor = ""
        var seen = Set<String>()
        repeat {
            var pageQuery = query
            if !cursor.isEmpty { pageQuery.append(URLQueryItem(name: "cursor", value: cursor)) }
            let page: Page<Item> = try await request(path, query: pageQuery)
            items += page.items
            cursor = page.nextCursor
            guard cursor.isEmpty || seen.insert(cursor).inserted else { throw APIError.decoding }
        } while !cursor.isEmpty
        return items
    }

    private func request<Output: Decodable>(_ path: String, query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil) async throws -> Output {
        let data = try await send(path, query: query, method: method, body: body)
        do {
            return try JSONDecoder().decode(Output.self, from: data)
        } catch {
            throw APIError.decoding
        }
    }

    private func send(_ path: String, query: [URLQueryItem], method: String, body: Data?, timeout: TimeInterval? = nil) async throws -> Data {
        var url = baseURL.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let timeout { request.timeoutInterval = timeout }
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }

        let session = await tokens.sessionGeneration
        var (data, status) = try await perform(request, forceRefresh: false, session: session)
        if status == 401 {
            (data, status) = try await perform(request, forceRefresh: true, session: session)
        }
        switch status {
        case 200 ..< 300: return data
        case 401: throw APIError.unauthenticated
        case 403, 404: throw APIError.denied
        case 409: throw APIError.conflict
        case 400, 413, 415, 422: throw APIError.invalid
        case 429: throw APIError.rateLimited
        default: throw APIError.server
        }
    }

    private func perform(_ original: URLRequest, forceRefresh: Bool, session: Int) async throws -> (Data, Int) {
        guard await tokens.sessionGeneration == session else { throw APIError.unauthenticated }
        let token = try await tokens.token(forceRefresh: forceRefresh)
        guard await tokens.sessionGeneration == session else { throw APIError.unauthenticated }
        var request = original
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await transport.send(request)
            guard await tokens.sessionGeneration == session else { throw APIError.unauthenticated }
            return (data, response.statusCode)
        } catch let error as APIError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw APIError.transport
        }
    }
}
